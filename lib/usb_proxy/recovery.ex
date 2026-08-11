defmodule UsbProxy.Recovery do
  @moduledoc """
  The recovery ladder, below the human rung: `:vbus` power-cycles every
  power-cyclable hub (all-or-nothing per hub on this hardware); `:reboot`
  reboots the whole usbproxy. Wall power stays a human job.

  No quiesce step is needed before `:vbus`: the registry's reconcile
  treats mass disappearance/reappearance as routine and re-binds, and
  console workers re-open their UARTs — verified behavior, not hope.

  Both levels are rate-limited so a confused agent cannot loop the box,
  and every request is written to the persistent event log — datasync'd
  BEFORE a reboot fires — with the requester's source address. The
  reboot itself is delayed slightly so the API response reaches the
  requester.

  Hardware effects go through `UsbProxy.Recovery.Impl` so tests can run
  the full policy machine.
  """

  use GenServer
  require Logger

  @default_intervals %{vbus: 30_000, reboot: 120_000}
  @default_reboot_delay_ms 1_000
  @history_cap 50

  defmodule Impl do
    @moduledoc "Hardware effects behind the recovery actions."
    @callback vbus_cycle(hubs :: [String.t()]) :: :ok | {:error, String.t()}
    @callback reboot() :: :ok | {:error, String.t()}
  end

  defmodule Real do
    @moduledoc false
    @behaviour UsbProxy.Recovery.Impl

    @impl true
    def vbus_cycle(hubs) do
      Enum.reduce_while(hubs, :ok, fn hub, :ok ->
        case System.cmd("uhubctl", ["-l", hub, "-a", "cycle", "-d", "3"], stderr_to_stdout: true) do
          {_out, 0} -> {:cont, :ok}
          {out, code} -> {:halt, {:error, "uhubctl #{hub} failed (#{code}): #{String.trim(out)}"}}
        end
      end)
    end

    @impl true
    def reboot() do
      if Application.get_env(:usb_proxy, :target, :host) == :host do
        {:error, "reboot is only available on the device"}
      else
        Nerves.Runtime.reboot()
        :ok
      end
    end
  end

  ## API

  @doc "Run a recovery action. Returns the history entry or a clear error."
  @spec request(:vbus | :reboot, String.t()) :: {:ok, map()} | {:error, String.t()}
  def request(level, requester) when level in [:vbus, :reboot] do
    GenServer.call(__MODULE__, {:request, level, requester}, 30_000)
  end

  @doc "Past recovery actions, newest first (this boot only)."
  @spec history() :: [map()]
  def history(), do: GenServer.call(__MODULE__, :history)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # The limiter must survive the reboot it just caused — otherwise an
    # agent polling /up and retrying can reboot-loop the box, which is
    # exactly what the rate limit exists to prevent. The pre-reboot
    # audit entries in the persistent event log are the durable record;
    # seed last-run times from them. (Wall clock, not monotonic: it's
    # the only time that crosses a reboot.)
    {:ok, %{last: seed_from_event_log(), history: []}}
  end

  @impl true
  def handle_call({:request, level, requester}, _from, state) do
    now = DateTime.utc_now()
    interval = interval_for(level)

    elapsed =
      case state.last[level] do
        %DateTime{} = last -> DateTime.diff(now, last, :millisecond)
        _ -> nil
      end

    if is_integer(elapsed) and elapsed < interval do
      retry_in = div(interval - elapsed + 999, 1000)

      {:reply,
       {:error, "rate limited: #{level} ran #{div(elapsed, 1000)}s ago; retry in ~#{retry_in}s"},
       state}
    else
      execute(level, requester, now, state)
    end
  end

  def handle_call(:history, _from, state), do: {:reply, state.history, state}

  defp execute(:vbus, requester, now, state) do
    hubs = UsbProxy.DeviceRegistry.power_cyclable_hubs()
    entry = entry(:vbus, requester, %{hubs: hubs})

    # Log before acting so the record exists even if the cycle wedges us.
    UsbProxy.EventLog.append_sync(:recovery_action, entry_fields(entry))

    case impl().vbus_cycle(hubs) do
      :ok ->
        Logger.info("recovery: vbus cycle of #{inspect(hubs)} for #{requester}")
        entry = %{entry | status: :done}
        {:reply, {:ok, entry}, remember(state, :vbus, now, entry)}

      {:error, message} ->
        {:reply, {:error, message}, remember(state, :vbus, now, %{entry | status: :failed})}
    end
  end

  defp execute(:reboot, requester, now, state) do
    entry = %{entry(:reboot, requester, %{}) | status: :scheduled}

    # Datasync'd before the reboot fires — the confirm is that this
    # entry is present in the log after the box comes back.
    UsbProxy.EventLog.append_sync(:recovery_action, entry_fields(entry))
    Logger.info("recovery: reboot scheduled for #{requester}")

    delay = config(:reboot_delay_ms) || @default_reboot_delay_ms
    implementation = impl()

    spawn(fn ->
      Process.sleep(delay)

      case implementation.reboot() do
        :ok -> :ok
        {:error, message} -> Logger.warning("recovery reboot failed: #{message}")
      end
    end)

    {:reply, {:ok, entry}, remember(state, :reboot, now, entry)}
  end

  defp entry(level, requester, extra) do
    Map.merge(
      %{
        id: Ash.UUID.generate(),
        level: level,
        status: :done,
        requested_by: requester,
        at: DateTime.utc_now()
      },
      extra
    )
  end

  defp entry_fields(entry) do
    %{
      id: entry.id,
      level: entry.level,
      status: entry.status,
      requester: entry.requested_by
    }
  end

  defp remember(state, level, now, entry) do
    %{
      state
      | last: Map.put(state.last, level, now),
        history: Enum.take([entry | state.history], @history_cap)
    }
  end

  defp interval_for(level) do
    (config(:min_intervals) || %{})
    |> Map.get(level, @default_intervals[level])
  end

  defp seed_from_event_log() do
    if config(:seed_from_event_log?) == false do
      %{}
    else
      UsbProxy.EventLog.tail(100)
      |> Enum.filter(&(&1["event"] == "recovery_action"))
      |> Enum.reduce(%{}, fn entry, acc ->
        with level when level in ["vbus", "reboot"] <- entry["level"],
             {:ok, at, _offset} <- DateTime.from_iso8601(entry["at"] || "") do
          # tail is oldest-first; later entries overwrite.
          Map.put(acc, String.to_existing_atom(level), at)
        else
          _ -> acc
        end
      end)
    end
  end

  defp impl(), do: config(:impl) || Real

  defp config(key) do
    Application.get_env(:usb_proxy, __MODULE__, []) |> Keyword.get(key)
  end
end
