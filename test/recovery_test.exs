defmodule UsbProxy.RecoveryTest do
  @moduledoc """
  The recovery policy machine (rate limits, history, audit) over a fake
  impl, plus the JSON:API and MCP surfaces — including the plan's
  "ten rapid reboots blocked cleanly" confirm.
  """

  use UsbProxy.RegistryCase, async: false
  import Plug.Test
  import Plug.Conn

  @endpoint_opts UsbProxyWeb.Endpoint.init([])

  setup do
    previous = Application.get_env(:usb_proxy, UsbProxy.Recovery, [])

    Application.put_env(:usb_proxy, UsbProxy.Recovery,
      impl: UsbProxy.FakeRecoveryImpl,
      min_intervals: %{vbus: 300, reboot: 300},
      reboot_delay_ms: 20,
      # The global event log carries entries from other tests; seeding
      # is exercised by its own dedicated test below.
      seed_from_event_log?: false
    )

    on_exit(fn -> Application.put_env(:usb_proxy, UsbProxy.Recovery, previous) end)

    Process.register(self(), :recovery_test_listener)

    on_exit(fn ->
      Process.whereis(:recovery_test_listener) && Process.unregister(:recovery_test_listener)
    end)

    # The app-started Recovery may hold rate-limit state from other
    # tests; restart it fresh.
    :ok = Supervisor.terminate_child(UsbProxy.Supervisor, UsbProxy.Recovery)
    {:ok, _} = Supervisor.restart_child(UsbProxy.Supervisor, UsbProxy.Recovery)

    :ok
  end

  describe "policy" do
    test "vbus cycles the power-cyclable hubs and records history" do
      assert {:ok, entry} = UsbProxy.Recovery.request(:vbus, "100.1.2.3")
      assert entry.status == :done
      assert entry.requested_by == "100.1.2.3"
      assert_receive {:vbus_cycle, ["1-1"]}

      assert [%{level: :vbus, status: :done}] = UsbProxy.Recovery.history()
    end

    test "reboot is scheduled, fires after the delay, and is logged first" do
      assert {:ok, %{status: :scheduled}} = UsbProxy.Recovery.request(:reboot, "100.1.2.3")
      assert_receive :reboot, 1_000

      # The audit entry was written synchronously before the reboot.
      events = UsbProxy.EventLog.tail(5)

      assert Enum.any?(events, fn e ->
               e["event"] == "recovery_action" and e["level"] == "reboot" and
                 e["requester"] == "100.1.2.3"
             end)
    end

    test "rapid repeats are rate limited with a retry hint, then allowed again" do
      assert {:ok, _} = UsbProxy.Recovery.request(:vbus, "a")
      assert {:error, message} = UsbProxy.Recovery.request(:vbus, "a")
      assert message =~ "rate limited"
      assert message =~ "retry in"

      Process.sleep(350)
      assert {:ok, _} = UsbProxy.Recovery.request(:vbus, "a")
    end

    test "levels are rate limited independently" do
      assert {:ok, _} = UsbProxy.Recovery.request(:vbus, "a")
      assert {:ok, _} = UsbProxy.Recovery.request(:reboot, "a")
    end

    test "the limiter survives its own reboot — seeded from the event log" do
      # A reboot wipes the in-memory limiter; without seeding, an agent
      # polling /up and retrying reboot-loops the box (found live).
      assert {:ok, _} = UsbProxy.Recovery.request(:reboot, "100.9.9.9")

      config = Application.get_env(:usb_proxy, UsbProxy.Recovery, [])

      Application.put_env(
        :usb_proxy,
        UsbProxy.Recovery,
        Keyword.put(config, :seed_from_event_log?, true)
      )

      # Simulate the post-reboot fresh start.
      :ok = Supervisor.terminate_child(UsbProxy.Supervisor, UsbProxy.Recovery)
      {:ok, _} = Supervisor.restart_child(UsbProxy.Supervisor, UsbProxy.Recovery)

      assert {:error, message} = UsbProxy.Recovery.request(:reboot, "100.9.9.9")
      assert message =~ "rate limited"
    end
  end

  describe "API surfaces" do
    defp request(conn), do: UsbProxyWeb.Endpoint.call(conn, @endpoint_opts)

    defp recover_json(level) do
      conn(:post, "/api/recovery_actions", Jason.encode!(%{data: %{attributes: %{level: level}}}))
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> request()
    end

    defp recover_mcp(level) do
      body = %{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: "recover", arguments: %{input: %{level: level}}}
      }

      response =
        conn(:post, "/mcp", Jason.encode!(body))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "application/json, text/event-stream")
        |> request()

      assert response.status == 200
      result = Jason.decode!(response.resp_body)["result"]
      {result["isError"], result["content"] |> hd() |> Map.get("text")}
    end

    test "vbus via JSON:API records requester from the connection" do
      response = recover_json("vbus")
      assert response.status == 201

      attrs = Jason.decode!(response.resp_body)["data"]["attributes"]
      assert attrs["status"] == "done"
      assert attrs["requested_by"] == "127.0.0.1"
      assert_receive {:vbus_cycle, _}

      # And it shows in the list.
      index =
        conn(:get, "/api/recovery_actions")
        |> put_req_header("accept", "application/vnd.api+json")
        |> request()

      assert [entry | _] = Jason.decode!(index.resp_body)["data"]
      assert entry["attributes"]["requested_by"] == "127.0.0.1"
    end

    test "recover via MCP works and matches" do
      {false, text} = recover_mcp("vbus")
      assert text =~ "done"
      assert_receive {:vbus_cycle, _}
    end

    test "ten rapid reboots: first succeeds, the rest error cleanly on both surfaces" do
      {false, _} = recover_mcp("reboot")

      for _ <- 1..5 do
        {true, text} = recover_mcp("reboot")
        assert text =~ "rate limited"
      end

      for _ <- 1..4 do
        response = recover_json("reboot")
        assert response.status == 400
        assert response.resp_body =~ "rate limited"
      end

      # Exactly one reboot ever fired.
      assert_receive :reboot, 1_000
      refute_receive :reboot, 300
    end
  end
end
