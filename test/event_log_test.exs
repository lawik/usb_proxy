defmodule UsbProxy.EventLogTest do
  use ExUnit.Case, async: false

  alias UsbProxy.EventLog

  setup do
    dir = Path.join(System.tmp_dir!(), "event_log_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    %{path: Path.join(dir, "events.log")}
  end

  defp start_log(id, path, opts \\ []) do
    name = :"log_#{id}_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: id,
      start: {EventLog, :start_link, [[name: name, path: path] ++ opts]}
    })
  end

  defp append(pid, kind, fields), do: GenServer.cast(pid, {:append, to_string(kind), fields})
  defp tail(pid, n), do: GenServer.call(pid, {:tail, n})

  test "logs a boot event on start and appends in order", %{path: path} do
    pid = start_log(:order, path)
    append(pid, :first, %{n: 1})
    append(pid, :second, %{n: 2})

    events = tail(pid, 10)
    assert Enum.map(events, & &1["event"]) == ["boot", "first", "second"]
    assert List.last(events)["n"] == 2
    assert Enum.all?(events, &is_binary(&1["at"]))
  end

  test "entries survive a restart (file appended, never truncated)", %{path: path} do
    pid = start_log(:first_run, path)
    append(pid, :before_restart, %{})
    _ = tail(pid, 1)
    :ok = stop_supervised(:first_run)

    pid2 = start_log(:second_run, path)
    events = tail(pid2, 10)
    assert Enum.map(events, & &1["event"]) == ["boot", "before_restart", "boot"]
  end

  test "rotates when max_bytes is exceeded, keeping one previous generation", %{path: path} do
    pid = start_log(:rotation, path, max_bytes: 300)

    for n <- 1..20 do
      append(pid, :filler, %{n: n, padding: String.duplicate("x", 40)})
    end

    # Synchronize on the cast queue.
    _ = tail(pid, 1)

    assert File.exists?(path <> ".1")
    # Tail spans the rotation boundary: latest entry still visible.
    events = tail(pid, 50)
    assert %{"event" => "filler", "n" => 20} = List.last(events)
  end
end
