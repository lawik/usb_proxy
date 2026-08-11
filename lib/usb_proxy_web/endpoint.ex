defmodule UsbProxyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :usb_proxy

  # JSON API + MCP only: no static files, no sessions, no code reloading.

  plug(Plug.RequestId)

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(UsbProxyWeb.Router)
end
