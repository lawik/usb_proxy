import Config

# Add configuration that is only needed when running on the host here.

# Dev/test endpoint on localhost only.
config :usb_proxy, UsbProxyWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  # Host-only secret; the device generates its own at runtime.
  secret_key_base: String.duplicate("host-dev-secret", 5)

# Event log goes to a temp dir on the host.
config :usb_proxy, UsbProxy.EventLog, path: "/tmp/usb_proxy_dev/events.log"

# TFTP is not started on the host (port 69 is privileged and the dev
# machine has its own network); tests start isolated instances on a
# high port with a temp root. Defaults are here so they can.
config :usb_proxy, UsbProxy.Tftp,
  root: "/tmp/usb_proxy_dev/tftp",
  port: 6969,
  data_ports: 6900..6999,
  max_file_bytes: 96_000_000,
  max_total_bytes: 1_000_000_000

config :nerves_runtime,
  kv_backend:
    {Nerves.Runtime.KVBackend.InMemory,
     contents: %{
       # The KV store on Nerves systems is typically read from UBoot-env, but
       # this allows us to use a pre-populated InMemory store when running on
       # host for development and testing.
       #
       # https://hexdocs.pm/nerves_runtime/readme.html#using-nerves_runtime-in-tests
       # https://hexdocs.pm/nerves_runtime/readme.html#nerves-system-and-firmware-metadata

       "nerves_fw_active" => "a",
       "a.nerves_fw_architecture" => "generic",
       "a.nerves_fw_description" => "N/A",
       "a.nerves_fw_platform" => "host",
       "a.nerves_fw_version" => "0.0.0"
     }}
