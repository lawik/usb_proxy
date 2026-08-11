defmodule UsbProxyWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json", "json_api"])
  end

  # NOTE: no auth pipelines anywhere. Reachability over the tailnet IS
  # the auth: the ACL only lets tag:project-vm reach this port. Do not add
  # auth plugs; do not weaken the ACL. (PLAN.md standing rules)

  scope "/", UsbProxyWeb do
    pipe_through(:api)

    get("/up", HealthController, :up)
  end

  # JSON:API — same Ash actions as the MCP tools below.
  scope "/api" do
    pipe_through(:api)

    forward("/", UsbProxyWeb.AshJsonApiRouter)
  end

  # MCP — no auth plug in this pipeline, per the standing rule above.
  # protocol_version_statement pinned for stateless-HTTP client compat.
  forward("/mcp", AshAi.Mcp.Router,
    tools: [
      :list_devices,
      :get_device,
      :set_device_exposure,
      :switch_device_mode,
      :list_serial_consoles,
      :recover
    ],
    protocol_version_statement: "2024-11-05",
    otp_app: :usb_proxy
  )
end
