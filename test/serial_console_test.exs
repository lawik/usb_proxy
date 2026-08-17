defmodule UsbProxy.SerialConsoleTest do
  @moduledoc """
  TCP semantics of a console worker, without a UART: single client,
  newest connection wins, adapter-missing status, port survives client
  churn. (Byte-pipe behavior is verified on hardware — the MicroPython
  REPL over TCP.)
  """

  use UsbProxy.RegistryCase, async: false

  alias UsbProxy.SerialConsoles.Worker

  @port 7097

  setup do
    pid = start_supervised!({Worker, name: "no-such-device", port: @port})
    %{worker: pid}
  end

  defp connect() do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, active: true], 2_000)
    socket
  end

  test "reports adapter_missing with no matching device", %{worker: worker} do
    assert %{status: :adapter_missing, client_count: 0} = Worker.status(worker)
  end

  test "counts a connected client; disconnect is instant and clean", %{worker: worker} do
    socket = connect()
    # The accept -> handover is async; poll briefly.
    wait_until(fn -> Worker.status(worker).client_count == 1 end)

    :gen_tcp.close(socket)
    wait_until(fn -> Worker.status(worker).client_count == 0 end)
  end

  test "a new connection replaces the old one", %{worker: worker} do
    first = connect()
    wait_until(fn -> Worker.status(worker).client_count == 1 end)

    _second = connect()
    # The first client gets closed by the worker.
    assert_receive {:tcp_closed, ^first}, 2_000
    assert %{client_count: 1} = Worker.status(worker)
  end

  test "starts at the default speed and takes a new one", %{worker: worker} do
    assert %{speed: 115_200} = Worker.status(worker)

    assert %{speed: 9600} = Worker.set_speed(worker, 9600)
    assert %{speed: 9600} = Worker.status(worker)

    # Setting the speed it already has is a no-op, not a reopen.
    assert %{speed: 9600} = Worker.set_speed(worker, 9600)
  end

  test "a speed change keeps the client connected", %{worker: worker} do
    socket = connect()
    wait_until(fn -> Worker.status(worker).client_count == 1 end)

    assert %{speed: 57_600, client_count: 1} = Worker.set_speed(worker, 57_600)
    refute_receive {:tcp_closed, ^socket}, 200
  end

  describe "set_speed action" do
    setup do
      start_supervised!(UsbProxy.SerialConsoles)
      :ok
    end

    test "rejects a speed no adapter would take" do
      assert {:error, error} = UsbProxy.Api.set_serial_console_speed("no-such-device", 12_345)
      assert Exception.message(error) =~ "unsupported speed"
    end

    test "rejects an unknown console" do
      assert {:error, error} = UsbProxy.Api.set_serial_console_speed("no-such-device", 9600)
      assert Exception.message(error) =~ "no serial console named"
    end
  end

  test "reconnect loop works: many sequential clients", %{worker: worker} do
    for _ <- 1..5 do
      socket = connect()
      wait_until(fn -> Worker.status(worker).client_count == 1 end)
      :gen_tcp.close(socket)
      wait_until(fn -> Worker.status(worker).client_count == 0 end)
    end
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(50)
        wait_until(fun, tries - 1)
    end
  end
end
