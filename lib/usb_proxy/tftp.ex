defmodule UsbProxy.Tftp do
  @moduledoc """
  TFTP server (RFC 1350 plus the RFC 2347-2349 options), read and write,
  over one flat directory on the data partition.

  Two client populations share it, deliberately undiscriminated: target
  boards on the lab network netbooting from their bootloader, and
  agents on the tailnet moving files. No authentication, no per-client
  namespace, same-name uploads clobber — TFTP offers none of that, and
  network reachability is the access control. See `UsbProxy.Tftp.Store`
  for the guarantees that *are* made.

  Retry-forever, like `UsbProxy.DaemonKeeper`: a UDP port that will not
  open must not blow a restart budget and take USB/IP, consoles and the
  API down with it.

  Port 69 takes the request; each transfer then runs on its own port
  from `:data_ports`. Both need to be open in the tailnet ACL.
  """

  use GenServer
  require Logger

  @default_port 69
  @default_data_ports 6900..6999
  @default_max_conn 16
  @default_retry_ms 5_000

  ## API

  @doc "Files currently in the TFTP directory, newest first."
  @spec list() :: [%{name: String.t(), size: non_neg_integer(), modified_at: DateTime.t()}]
  def list(), do: GenServer.call(__MODULE__, :list)

  @doc "Delete one file by name. The flat namespace is the whole namespace."
  @spec delete(String.t()) :: :ok | {:error, String.t()}
  def delete(name), do: GenServer.call(__MODULE__, {:delete, name})

  @doc "Server state: root, ports, caps, bytes used, whether the daemon is up."
  @spec info() :: map()
  def info(), do: GenServer.call(__MODULE__, :info)

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  ## Server

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    # Options override app config so tests can run isolated instances.
    config = Application.get_env(:usb_proxy, __MODULE__, []) |> Keyword.merge(opts)
    root = Keyword.fetch!(config, :root)
    File.mkdir_p!(root)

    state = %{
      root: root,
      port: Keyword.get(config, :port, @default_port),
      data_ports: Keyword.get(config, :data_ports, @default_data_ports),
      max_conn: Keyword.get(config, :max_conn, @default_max_conn),
      max_file_bytes: Keyword.fetch!(config, :max_file_bytes),
      max_total_bytes: Keyword.fetch!(config, :max_total_bytes),
      retry_ms: Keyword.get(config, :retry_ms, @default_retry_ms),
      debug: Keyword.get(config, :debug, :brief),
      daemon: nil
    }

    # Power cuts leave temp files behind, and a `.part` is never
    # resumable.
    sweep_partials(root)

    {:ok, state, {:continue, :start_daemon}}
  end

  @impl true
  def handle_continue(:start_daemon, state), do: {:noreply, start_daemon(state)}

  @impl true
  def handle_info(:start_daemon, state), do: {:noreply, start_daemon(state)}

  def handle_info({:EXIT, pid, reason}, %{daemon: pid} = state) do
    Logger.warning("tftpd exited (#{inspect(reason)}); retrying in #{state.retry_ms}ms")
    UsbProxy.EventLog.append(:daemon_exit, %{daemon: :tftpd, reason: inspect(reason)})
    Process.send_after(self(), :start_daemon, state.retry_ms)
    {:noreply, %{state | daemon: nil}}
  end

  def handle_info({:EXIT, _other, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_call(:list, _from, state), do: {:reply, do_list(state.root), state}

  def handle_call(:info, _from, state) do
    files = do_list(state.root)

    info = %{
      root: state.root,
      port: state.port,
      data_ports: state.data_ports,
      running: is_pid(state.daemon),
      file_count: length(files),
      bytes_used: Enum.reduce(files, 0, &(&1.size + &2)),
      max_file_bytes: state.max_file_bytes,
      max_total_bytes: state.max_total_bytes
    }

    {:reply, info, state}
  end

  def handle_call({:delete, name}, _from, state) do
    reply =
      case Path.basename(name) do
        ^name ->
          case File.rm(Path.join(state.root, name)) do
            :ok ->
              UsbProxy.EventLog.append(:tftp_deleted, %{name: name})
              :ok

            {:error, :enoent} ->
              {:error, "no TFTP file named #{name}"}

            {:error, reason} ->
              {:error, "could not delete #{name}: #{:file.format_error(reason)}"}
          end

        _ ->
          {:error, "#{name} is not a name in the flat TFTP namespace"}
      end

    {:reply, reply, state}
  end

  ## Internals

  defp start_daemon(state) do
    options = [
      {:port, state.port},
      {:port_policy, {:range, Enum.min(state.data_ports), Enum.max(state.data_ports)}},
      {:max_conn, state.max_conn},
      # The engine sizes its sockets for 512-byte blocks; a larger
      # negotiated blksize then truncates on receive, and a truncated
      # block reads as the last one — a short file, reported as success.
      {:udp, [{:recbuf, 65_536}, {:sndbuf, 65_536}, {:buffer, 65_536}]},
      {:callback,
       {~c".*", UsbProxy.Tftp.Store,
        %{
          root: state.root,
          max_file_bytes: state.max_file_bytes,
          max_total_bytes: state.max_total_bytes
        }}},
      {:logger, UsbProxy.Tftp.Logger},
      # :brief logs an open/close line per transfer at debug level.
      {:debug, state.debug}
    ]

    case :tftp.start(options) do
      {:ok, pid} ->
        Logger.info("tftpd on port #{state.port}, serving #{state.root}")
        UsbProxy.EventLog.append(:tftp_started, %{port: state.port, root: state.root})
        %{state | daemon: pid}

      {:error, reason} ->
        Logger.warning("tftpd failed to start (#{inspect(reason)}); retrying")
        Process.send_after(self(), :start_daemon, state.retry_ms)
        state
    end
  end

  defp do_list(root) do
    root
    |> File.ls!()
    |> Enum.flat_map(fn name ->
      case File.stat(Path.join(root, name), time: :posix) do
        {:ok, %{type: :regular, size: size, mtime: mtime}} ->
          [%{name: name, size: size, modified_at: DateTime.from_unix!(mtime)}]

        _ ->
          []
      end
    end)
    |> Enum.reject(&String.starts_with?(&1.name, "."))
    |> Enum.sort_by(& &1.modified_at, {:desc, DateTime})
  end

  defp sweep_partials(root) do
    for name <- File.ls!(root),
        String.starts_with?(name, ".") and String.contains?(name, ".part.") do
      File.rm(Path.join(root, name))
    end
  end
end

defmodule UsbProxy.Tftp.Logger do
  @moduledoc false
  # OTP's tftp logs through a callback module; default is error_logger,
  # which on this box means every aborted boot attempt is an SASL
  # report. Route it to Logger at sane levels instead.
  @behaviour :tftp_logger

  require Logger

  @impl true
  def error_msg(format, data), do: Logger.error(fmt(format, data))

  @impl true
  def warning_msg(format, data), do: Logger.warning(fmt(format, data))

  @impl true
  def info_msg(format, data), do: Logger.debug(fmt(format, data))

  defp fmt(format, data), do: "tftpd: " <> to_string(:io_lib.format(format, data))
end
