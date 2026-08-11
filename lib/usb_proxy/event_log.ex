defmodule UsbProxy.EventLog do
  @moduledoc """
  Persistent, append-only log of operationally significant events:
  boots, binds, attaches, flash operations, recovery actions.

  One JSON object per line. Lives on the data partition so it survives
  reboots and power cuts; every append is followed by `datasync` so an
  entry that was acknowledged is on flash. Size-capped: when the file
  exceeds `max_bytes` it is rotated to `<path>.1` (one previous
  generation is kept).

  Appends go through a GenServer so lines never interleave. Logging
  must never take the box down: failures degrade to a Logger warning.
  """

  use GenServer
  require Logger

  @doc "Append an event. `kind` names the event; `fields` add detail."
  @spec append(String.t() | atom(), map()) :: :ok
  def append(kind, fields \\ %{}) do
    GenServer.cast(__MODULE__, {:append, to_string(kind), fields})
  end

  @doc "Read the most recent `n` events, newest last. For debugging/API."
  @spec tail(pos_integer()) :: [map()]
  def tail(n \\ 50) do
    GenServer.call(__MODULE__, {:tail, n})
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:usb_proxy, __MODULE__)
    path = Keyword.fetch!(config, :path)
    max_bytes = Keyword.get(config, :max_bytes, 1_000_000)

    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = :file.open(path, [:append, :raw, :binary])
    size = with {:ok, %{size: size}} <- File.stat(path), do: size

    state = %{path: path, io: io, size: size, max_bytes: max_bytes}
    {:ok, state, {:continue, :log_boot}}
  end

  @impl true
  def handle_continue(:log_boot, state) do
    version = Application.spec(:usb_proxy, :vsn) |> to_string()
    {:noreply, write(state, "boot", %{version: version})}
  end

  @impl true
  def handle_cast({:append, kind, fields}, state) do
    {:noreply, write(state, kind, fields)}
  end

  @impl true
  def handle_call({:tail, n}, _from, state) do
    events =
      [state.path <> ".1", state.path]
      |> Enum.flat_map(fn path ->
        case File.read(path) do
          {:ok, data} -> String.split(data, "\n", trim: true)
          _ -> []
        end
      end)
      |> Enum.take(-n)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, event} -> [event]
          _ -> []
        end
      end)

    {:reply, events, state}
  end

  defp write(state, kind, fields) do
    event =
      fields
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("event", kind)
      |> Map.put("at", DateTime.utc_now() |> DateTime.to_iso8601())

    line = [Jason.encode_to_iodata!(event), ?\n]

    with :ok <- :file.write(state.io, line),
         :ok <- :file.datasync(state.io) do
      maybe_rotate(%{state | size: state.size + IO.iodata_length(line)})
    else
      error ->
        Logger.warning("event log write failed: #{inspect(error)}")
        state
    end
  end

  defp maybe_rotate(%{size: size, max_bytes: max} = state) when size < max, do: state

  defp maybe_rotate(state) do
    :file.close(state.io)
    File.rename(state.path, state.path <> ".1")
    {:ok, io} = :file.open(state.path, [:append, :raw, :binary])
    %{state | io: io, size: 0}
  end
end
