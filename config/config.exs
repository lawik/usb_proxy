# This file is responsible for configuring your application and its
# dependencies.
#
# This configuration file is loaded before any dependency and is restricted to
# this project.
import Config

# Enable the Nerves integration with Mix
Application.start(:nerves_bootstrap)

config :usb_proxy, target: Mix.target()

################################################################
## Phoenix / API
################################################################

# One endpoint serves everything agent-facing: JSON API under /api,
# MCP under /mcp, health at /up. Port 4000 per the tailnet ACL.
config :usb_proxy, UsbProxyWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "usbproxy"],
  render_errors: [formats: [json: UsbProxyWeb.ErrorJSON], layout: false],
  pubsub_server: UsbProxy.PubSub

config :phoenix, :json_library, Jason

################################################################
## Ash
################################################################

config :usb_proxy, ash_domains: [UsbProxy.Api]

# No database on this box; resources use manual/ETS-style data layers.
config :ash, :disable_async?, true

################################################################
## Nerves
################################################################

# Customize non-Elixir parts of the firmware. See
# https://hexdocs.pm/nerves/advanced-configuration.html for details.

config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"

# Set the SOURCE_DATE_EPOCH date for reproducible builds.
# See https://reproducible-builds.org/docs/source-date-epoch/ for more information

config :nerves, source_date_epoch: "1786374425"

if Mix.target() == :host do
  import_config "host.exs"
else
  import_config "target.exs"
end
