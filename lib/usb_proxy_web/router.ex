defmodule UsbProxyWeb.Router do
  use Phoenix.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # NOTE: no auth pipelines anywhere. Reachability over the tailnet IS
  # the auth: the ACL only lets tag:agent reach this port. Do not add
  # auth plugs; do not weaken the ACL. (PLAN.md standing rules)

  scope "/", UsbProxyWeb do
    pipe_through(:api)

    get("/up", HealthController, :up)
  end

  # Phase 5 adds:
  #   /api — AshJsonApi routes
  #   /mcp — AshAi.Mcp.Router (no auth plug in the :mcp pipeline)
end
