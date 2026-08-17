defmodule UsbProxy.SerialConsoles do
  @moduledoc """
  Serial console service: one TCP listener per serial adapter, raw byte
  pipe to the adapter's UART, no protocol.

  Semantics (documented for agents in the SerialConsole resource):

    * Single client per console. A NEW connection REPLACES the current
      one — a crashed agent can always reconnect instead of being locked
      out by its own zombie connection.
    * Adapter unplugged mid-session: the TCP side stays up and the
      console reports :adapter_missing; bytes written meanwhile are
      dropped. When the adapter returns, the pipe resumes.
    * Ports are allocated from the ACL'd range (7000-7099) per stable
      device name, first come first served, held for the lifetime of
      this boot. Agents must discover the port via the API, never
      hardcode it.
    * A console is started with an explicit baud rate (the configured
      default); `set_speed/2` reopens the UART at another one. Nothing
      remembers it: a console that restarts is back at the default, so
      agents re-read the speed rather than assuming it.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {DynamicSupervisor, name: UsbProxy.SerialConsoles.WorkerSupervisor, strategy: :one_for_one},
      UsbProxy.SerialConsoles.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "Live console list: name, tcp_port, status, client_count, speed."
  @spec list() :: [map()]
  def list(), do: UsbProxy.SerialConsoles.Manager.list()

  @doc "Set a console's baud rate, reopening its UART."
  @spec set_speed(String.t(), pos_integer()) :: {:ok, map()} | {:error, :no_console}
  def set_speed(name, speed) do
    with {:ok, pid} <- UsbProxy.SerialConsoles.Manager.worker_pid(name) do
      {:ok, UsbProxy.SerialConsoles.Worker.set_speed(pid, speed)}
    end
  end
end

defmodule UsbProxy.SerialConsoles.Manager do
  @moduledoc false
  use GenServer
  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def list(), do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(UsbProxy.PubSub, "device_registry")
    {:ok, %{consoles: %{}}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_info(:devices_changed, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_call(:list, _from, state) do
    consoles =
      Enum.map(state.consoles, fn {name, %{port: port, pid: pid}} ->
        worker_status =
          if Process.alive?(pid) do
            UsbProxy.SerialConsoles.Worker.status(pid)
          else
            %{
              status: :adapter_missing,
              client_count: 0,
              speed: UsbProxy.SerialConsoles.Worker.default_speed()
            }
          end

        Map.merge(%{name: name, tcp_port: port}, worker_status)
      end)

    {:reply, consoles, state}
  end

  def handle_call({:worker_pid, name}, _from, state) do
    case state.consoles[name] do
      %{pid: pid} -> {:reply, {:ok, pid}, state}
      nil -> {:reply, {:error, :no_console}, state}
    end
  end

  @doc false
  def worker_pid(name), do: GenServer.call(__MODULE__, {:worker_pid, name})

  # A console worker is started the first time a serial-exposed device
  # is seen and lives for the rest of the boot: the port mapping must
  # survive the adapter being replugged (any port, any time) and
  # exposure round-trips through :usbip.
  defp reconcile(state) do
    serial_devices =
      UsbProxy.DeviceRegistry.list()
      |> Enum.filter(&(&1.exposure == :serial))

    Enum.reduce(serial_devices, state, fn device, state ->
      case state.consoles[device.name] do
        nil -> start_console(state, device.name)
        _existing -> state
      end
    end)
  end

  defp start_console(state, name) do
    case free_port(state) do
      nil ->
        Logger.warning("no free console ports for #{name}")
        state

      port ->
        speed = UsbProxy.SerialConsoles.Worker.default_speed()

        {:ok, pid} =
          DynamicSupervisor.start_child(
            UsbProxy.SerialConsoles.WorkerSupervisor,
            {UsbProxy.SerialConsoles.Worker, name: name, port: port, speed: speed}
          )

        Logger.info("serial console for #{name} on port #{port} at #{speed}")
        UsbProxy.EventLog.append(:console_started, %{name: name, port: port, speed: speed})
        put_in(state.consoles[name], %{port: port, pid: pid})
    end
  end

  defp free_port(state) do
    used = state.consoles |> Map.values() |> MapSet.new(& &1.port)

    port_range()
    |> Enum.find(&(not MapSet.member?(used, &1)))
  end

  defp port_range() do
    Application.get_env(:usb_proxy, UsbProxy.SerialConsoles, [])
    |> Keyword.get(:port_range, 7000..7099)
  end
end

defmodule UsbProxy.SerialConsoles.Worker do
  @moduledoc false
  use GenServer
  require Logger

  @uart_retry_ms 2_000
  @default_speed 115_200

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def status(pid), do: GenServer.call(pid, :status)

  @doc "Write bytes to the UART (used by ModeSwitch for REPL sequences)."
  def inject(pid, data), do: GenServer.call(pid, {:inject, data})

  @doc "Change the baud rate; an open UART is reopened at the new speed."
  def set_speed(pid, speed), do: GenServer.call(pid, {:set_speed, speed})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)
    port = Keyword.fetch!(opts, :port)

    {:ok, listen_socket} =
      :gen_tcp.listen(port, [
        :binary,
        active: true,
        reuseaddr: true,
        ip: {0, 0, 0, 0}
      ])

    state = %{
      name: name,
      port: port,
      listen_socket: listen_socket,
      client: nil,
      uart: nil,
      tty: nil,
      speed: Keyword.fetch!(opts, :speed)
    }

    # Re-check the UART when the registry sees changes: a mode switch
    # re-enumerates the device and can leave a stale open handle behind.
    Phoenix.PubSub.subscribe(UsbProxy.PubSub, "device_registry")

    start_acceptor(state)
    {:ok, state, {:continue, :open_uart}}
  end

  @impl true
  def handle_continue(:open_uart, state), do: {:noreply, try_open_uart(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_map(state), state}

  def handle_call({:set_speed, speed}, _from, %{speed: speed} = state) do
    {:reply, status_map(state), state}
  end

  def handle_call({:set_speed, speed}, _from, state) do
    Logger.info("console #{state.name}: speed #{state.speed} -> #{speed}")
    UsbProxy.EventLog.append(:console_speed, %{name: state.name, speed: speed})

    state = reopen_uart(%{state | speed: speed})
    {:reply, status_map(state), state}
  end

  def handle_call({:inject, data}, _from, state) do
    if state.uart do
      {:reply, Circuits.UART.write(state.uart, data), state}
    else
      {:reply, {:error, :no_uart}, state}
    end
  end

  @impl true
  def handle_info(:open_uart, state), do: {:noreply, try_open_uart(state)}

  def handle_info(:devices_changed, state) do
    cond do
      state.uart == nil ->
        {:noreply, state}

      # Device gone, re-enumerated elsewhere, mode-changed (different
      # tty), or released to usbip: drop the handle and let the retry
      # loop reopen against reality.
      stale_uart?(state) ->
        Logger.info("console #{state.name}: device changed; reopening UART")
        {:noreply, close_uart(state)}

      true ->
        {:noreply, state}
    end
  end

  # New TCP client (handed over by the acceptor). Single-client:
  # a new connection replaces the current one.
  def handle_info({:client, socket}, state) do
    peer =
      case :inet.peername(socket) do
        {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
        _ -> "unknown"
      end

    if state.client do
      Logger.info("console #{state.name}: replacing client")
      :gen_tcp.close(state.client)
    end

    :inet.setopts(socket, active: true)
    Logger.info("console #{state.name}: client connected from #{peer}")
    UsbProxy.EventLog.append(:console_connected, %{name: state.name, peer: peer})
    {:noreply, %{state | client: socket}}
  end

  def handle_info({:tcp, socket, data}, %{client: socket} = state) do
    if state.uart, do: Circuits.UART.write(state.uart, data)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, socket}, %{client: socket} = state) do
    Logger.info("console #{state.name}: client disconnected")
    UsbProxy.EventLog.append(:console_disconnected, %{name: state.name})
    {:noreply, %{state | client: nil}}
  end

  def handle_info({:tcp_error, socket, _reason}, %{client: socket} = state) do
    :gen_tcp.close(socket)
    {:noreply, %{state | client: nil}}
  end

  # Late messages from an already-replaced client socket.
  def handle_info({:tcp, _old, _data}, state), do: {:noreply, state}
  def handle_info({:tcp_closed, _old}, state), do: {:noreply, state}
  def handle_info({:tcp_error, _old, _}, state), do: {:noreply, state}

  def handle_info({:circuits_uart, _tty, {:error, reason}}, state) do
    Logger.info("console #{state.name}: adapter error #{inspect(reason)}; waiting for return")
    {:noreply, close_uart(state)}
  end

  def handle_info({:circuits_uart, _tty, data}, state) when is_binary(data) do
    if state.client, do: :gen_tcp.send(state.client, data)
    {:noreply, state}
  end

  # UART GenServer died (adapter yanked hard). Keep the TCP side alive.
  def handle_info({:EXIT, pid, _reason}, %{uart: pid} = state) do
    {:noreply, close_uart(%{state | uart: nil})}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  defp status_map(state) do
    status =
      cond do
        state.uart -> :up
        exposure(state.name) != :serial -> :released
        true -> :adapter_missing
      end

    %{
      status: status,
      client_count: if(state.client, do: 1, else: 0),
      speed: state.speed
    }
  end

  defp close_uart(state) do
    Process.send_after(self(), :open_uart, @uart_retry_ms)
    stop_uart(state)
  end

  # Speed change on a live UART: no reason to make the client wait out
  # the retry interval.
  defp reopen_uart(%{uart: nil} = state), do: state
  defp reopen_uart(state), do: state |> stop_uart() |> try_open_uart()

  defp stop_uart(state) do
    if state.uart do
      Circuits.UART.close(state.uart)
      Circuits.UART.stop(state.uart)
    end

    %{state | uart: nil, tty: nil}
  end

  defp stale_uart?(state) do
    case UsbProxy.DeviceRegistry.get(state.name) do
      {:ok, %{present?: true, exposure: :serial} = device} ->
        find_tty(device.busid) != state.tty

      _ ->
        true
    end
  end

  # Already open: never stack a second UART (stale-close paths can
  # schedule multiple retries).
  defp try_open_uart(%{uart: uart} = state) when uart != nil, do: state

  defp try_open_uart(state) do
    with {:ok, device} <- UsbProxy.DeviceRegistry.get(state.name),
         # Released to usbip? Stand down; keep polling for exposure flips.
         :serial <- device.exposure,
         true <- device.present? || :absent,
         tty when is_binary(tty) <- find_tty(device.busid) do
      {:ok, uart} = Circuits.UART.start_link()

      case Circuits.UART.open(uart, tty, speed: state.speed, active: true) do
        :ok ->
          Logger.info("console #{state.name}: opened #{tty} at #{state.speed}")
          %{state | uart: uart, tty: tty}

        {:error, reason} ->
          Logger.debug("console #{state.name}: open #{tty} failed: #{inspect(reason)}")
          Circuits.UART.stop(uart)
          retry_uart(state)
      end
    else
      _ -> retry_uart(state)
    end
  end

  defp retry_uart(state) do
    Process.send_after(self(), :open_uart, @uart_retry_ms)
    state
  end

  # The tty for a USB serial function lives under the device's interface
  # in sysfs: <busid>:1.0/ttyUSB0 (ftdi/cp210x/...) or <busid>:1.0/tty/ttyACM0.
  defp find_tty(busid) do
    [
      "/sys/bus/usb/devices/#{busid}/#{busid}*/tty*",
      "/sys/bus/usb/devices/#{busid}/#{busid}*/tty/tty*"
    ]
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.map(&Path.basename/1)
    # "tty" alone is the ACM subdirectory, not a device node
    |> Enum.find(&(String.starts_with?(&1, "tty") and &1 != "tty"))
  end

  @doc "Baud rate a console is started with, from config."
  def default_speed() do
    Application.get_env(:usb_proxy, UsbProxy.SerialConsoles, [])
    |> Keyword.get(:speed, @default_speed)
  end

  defp exposure(name) do
    case UsbProxy.DeviceRegistry.get(name) do
      {:ok, device} -> device.exposure
      _ -> :serial
    end
  end

  defp start_acceptor(state) do
    worker = self()
    listen_socket = state.listen_socket

    Task.start_link(fn -> accept_loop(listen_socket, worker) end)
  end

  defp accept_loop(listen_socket, worker) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:client, socket})
        accept_loop(listen_socket, worker)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Process.sleep(500)
        accept_loop(listen_socket, worker)
    end
  end
end
