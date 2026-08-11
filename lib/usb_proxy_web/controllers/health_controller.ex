defmodule UsbProxyWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  def up(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
