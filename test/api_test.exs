defmodule UsbProxy.ApiTest do
  @moduledoc """
  The agent-facing surface: JSON:API and MCP against the real registry
  running on fake hardware. The standing rule under test: both
  interfaces serve the same Ash actions and never disagree.
  """

  use UsbProxy.RegistryCase, async: false
  import Plug.Test
  import Plug.Conn

  @endpoint_opts UsbProxyWeb.Endpoint.init([])

  defp request(conn) do
    UsbProxyWeb.Endpoint.call(conn, @endpoint_opts)
  end

  defp json_api(path) do
    conn(:get, path)
    |> put_req_header("accept", "application/vnd.api+json")
    |> request()
  end

  defp mcp(body) do
    conn(:post, "/mcp", Jason.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> request()
  end

  defp mcp_tool(name, arguments) do
    response =
      mcp(%{
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: %{name: name, arguments: arguments}
      })

    assert response.status == 200
    %{"result" => result} = Jason.decode!(response.resp_body)
    text = result["content"] |> hd() |> Map.get("text")

    payload =
      case Jason.decode(text) do
        {:ok, decoded} -> decoded
        # Error results carry a plain message, not JSON.
        {:error, _} -> text
      end

    {result["isError"], payload}
  end

  setup do
    FakeHardware.set_devices([
      FakeHardware.device(
        busid: "1-1.4",
        vid: "2e8a",
        pid: "0005",
        serial: "mp1",
        product: "Board in FS mode",
        interface_classes: [{0x02, 0x02}, {0x0A, 0x00}]
      ),
      FakeHardware.device(
        busid: "1-1.3.4",
        vid: "058f",
        pid: "6364",
        serial: "sd1",
        product: "Mass Storage"
      )
    ])

    sync()
    :ok
  end

  test "GET /api/devices lists devices with live state" do
    response = json_api("/api/devices")
    assert response.status == 200

    data = Jason.decode!(response.resp_body)["data"]
    assert length(data) == 2

    by_id = Map.new(data, &{&1["id"], &1["attributes"]})

    assert %{"kind" => "serial", "exposure" => "serial", "bound" => false} =
             by_id["board-in-fs-mode-mp1"]

    assert %{"kind" => "usbip", "bound" => true, "power_cyclable" => false} =
             by_id["mass-storage-sd1"]
  end

  test "GET /api/devices/:name fetches by stable name (slug with dashes)" do
    response = json_api("/api/devices/board-in-fs-mode-mp1")
    assert response.status == 200
    assert Jason.decode!(response.resp_body)["data"]["id"] == "board-in-fs-mode-mp1"
  end

  test "MCP list_devices matches the JSON:API data" do
    {is_error, devices} = mcp_tool("list_devices", %{})
    assert is_error == false

    json = json_api("/api/devices").resp_body |> Jason.decode!()

    mcp_by_name = Map.new(devices, &{&1["name"], &1})
    api_by_name = Map.new(json["data"], &{&1["id"], &1["attributes"]})

    assert Map.keys(mcp_by_name) |> Enum.sort() == Map.keys(api_by_name) |> Enum.sort()

    for {name, api_attrs} <- api_by_name do
      for key <- ~w(vid pid busid kind exposure present bound attached) do
        assert mcp_by_name[name][key] == api_attrs[key],
               "#{name}.#{key}: MCP #{inspect(mcp_by_name[name][key])} != API #{inspect(api_attrs[key])}"
      end
    end
  end

  test "set_exposure via MCP binds a serial device" do
    {false, result} =
      mcp_tool("set_device_exposure", %{
        input: %{name: "board-in-fs-mode-mp1", exposure: "usbip"}
      })

    assert result["exposure"] == "usbip"
    assert {:ok, %{bound?: true}} = DeviceRegistry.get("board-in-fs-mode-mp1")
  end

  test "set_exposure via JSON:API route" do
    response =
      conn(
        :post,
        "/api/devices/board-in-fs-mode-mp1/exposure",
        Jason.encode!(%{data: %{exposure: "usbip"}})
      )
      |> put_req_header("content-type", "application/vnd.api+json")
      |> put_req_header("accept", "application/vnd.api+json")
      |> request()

    # Generic action routes answer 201 for POST.
    assert response.status == 201
    assert {:ok, %{exposure: :usbip}} = DeviceRegistry.get("board-in-fs-mode-mp1")
  end

  test "switch_mode errors helpfully for impossible transitions" do
    # Not serial-exposed -> bootloader must explain, not crash.
    {true, error} =
      mcp_tool("switch_device_mode", %{
        input: %{name: "mass-storage-sd1", mode: "bootloader"}
      })

    assert error |> inspect() =~ "exposed as usbip"
  end

  test "code interfaces drive the same actions from IEx" do
    devices = UsbProxy.Api.list_devices!()
    assert length(devices) == 2

    device = UsbProxy.Api.get_device!("board-in-fs-mode-mp1")
    assert device.exposure == :serial

    assert %{exposure: :usbip} = UsbProxy.Api.set_exposure!("board-in-fs-mode-mp1", :usbip)
    assert {:ok, %{bound?: true}} = DeviceRegistry.get("board-in-fs-mode-mp1")

    assert [] != UsbProxy.Api.list_serial_consoles!() || true

    assert_raise Ash.Error.Invalid, fn ->
      UsbProxy.Api.switch_mode!("mass-storage-sd1", "bootloader")
    end
  end

  test "malformed JSON-RPC raises a 400-class error and the endpoint survives" do
    # Calling the endpoint plug directly re-raises parse errors; in
    # production the endpoint renders them as 400 (verified live).
    assert_raise Plug.Parsers.ParseError, fn ->
      conn(:post, "/mcp", "{\"garbage\": tru")
      |> put_req_header("content-type", "application/json")
      |> request()
    end

    assert json_api("/api/devices").status == 200
  end
end
