defmodule UsbProxy.DaemonKeeper do
  @moduledoc """
  Keeps an external daemon running with retry-forever semantics.

  A plain supervised MuonTrap.Daemon that insta-fails (bad flag, corrupt
  state, missing binary) blows the restart budget and takes the whole
  application down — Phoenix, ssh consoles, everything. This box must
  degrade instead: if a daemon won't run, the rest keeps serving and the
  event log records the flapping.

  Options: `:id` (required, names the instance), `:command` (required),
  `:args`, `:retry_ms`.
  """

  use GenServer
  require Logger

  @default_retry_ms 5_000

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)
    %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: :"#{__MODULE__}_#{id}")
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      id: Keyword.fetch!(opts, :id),
      command: Keyword.fetch!(opts, :command),
      args: Keyword.get(opts, :args, []),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      daemon: nil
    }

    {:ok, state, {:continue, :start_daemon}}
  end

  @impl true
  def handle_continue(:start_daemon, state), do: {:noreply, start_daemon(state)}

  @impl true
  def handle_info(:start_daemon, state), do: {:noreply, start_daemon(state)}

  def handle_info({:EXIT, pid, reason}, %{daemon: pid} = state) do
    Logger.warning("#{state.id} exited (#{inspect(reason)}); retrying in #{state.retry_ms}ms")
    UsbProxy.EventLog.append(:daemon_exit, %{daemon: state.id, reason: inspect(reason)})
    Process.send_after(self(), :start_daemon, state.retry_ms)
    {:noreply, %{state | daemon: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp start_daemon(state) do
    case MuonTrap.Daemon.start_link(state.command, state.args,
           log_output: :debug,
           log_prefix: "#{state.id}: ",
           stderr_to_stdout: true
         ) do
      {:ok, pid} ->
        %{state | daemon: pid}

      {:error, reason} ->
        Logger.warning("#{state.id} failed to start (#{inspect(reason)}); retrying")
        Process.send_after(self(), :start_daemon, state.retry_ms)
        state
    end
  end
end
