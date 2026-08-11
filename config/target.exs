import Config

# Use Ringlogger as the logger backend and remove :console.
# See https://hexdocs.pm/ring_logger/readme.html for more information on
# configuring ring_logger.

config :logger, backends: [RingLogger]

# Use shoehorn to start the main application. See the shoehorn
# library documentation for more control in ordering how OTP
# applications are started and handling failures.

config :shoehorn, init: [:nerves_runtime, :nerves_pack]

# Enable the system startup guard to check that all OTP applications
# started. If they didn't and you're on a Nerves system that supports
# test runs of new firmware, the firmware will automatically roll
# back to the previous version. Delete this if implementing your own
# way of validating that firmware is good.
config :nerves_runtime, startup_guard_enabled: true

# Erlinit can be configured without a rootfs_overlay. See
# https://github.com/nerves-project/erlinit/ for more information on
# configuring erlinit.

# Advance the system clock on devices without a real-time clock.
config :nerves, :erlinit,
  update_clock: true,
  hostname_pattern: "usbproxy-%s"

################################################################
## usbproxy services
################################################################

# Phoenix endpoint: JSON API, MCP, and /up on the API port from the
# tailnet ACL. Listener on 0.0.0.0 for Phase 3; reachability is
# enforced by the tailnet ACL (agents can only reach 3240/4000/7000-7099).
# secret_key_base is generated at boot (no sessions/cookies on this API).
config :usb_proxy, UsbProxyWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  server: true

# Hubs whose VBUS switching genuinely cuts power (verified with
# uhubctl + a bus-powered device). Devices elsewhere are reported
# power_cyclable: false and can only be logically re-enumerated.
config :usb_proxy, UsbProxy.DeviceRegistry, power_cyclable_hubs: ["1-1"]

# Persistent, size-capped, append-only event log on the data partition.
# Survives reboots and power cuts; records operationally significant
# events (boots, binds, attaches, flash operations, recovery actions).
config :usb_proxy, UsbProxy.EventLog,
  path: "/data/usb_proxy/events.log",
  max_bytes: 1_000_000

# tailscaled state lives on the data partition so the node identity
# survives reboots, power cuts, and firmware updates.
config :usb_proxy, UsbProxy.Tailscale,
  state_dir: "/data/tailscale",
  hostname: "usbproxy",
  # First boot: `tailscale up` uses an auth key read from (first match wins)
  #   1. Nerves.Runtime.KV "tailscale_authkey"
  #   2. the file below (drop it in place over ssh/console once)
  # After the first join, the state dir carries the identity and no key
  # is needed again.
  authkey_file: "/data/tailscale/authkey"

# Configure the device for SSH IEx prompt access and firmware updates
#
# * See https://hexdocs.pm/nerves_ssh/readme.html for general SSH configuration
# * See https://hexdocs.pm/ssh_subsystem_fwup/readme.html for firmware updates

keys =
  System.user_home!()
  |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
  |> Path.wildcard()

if keys == [],
  do:
    Mix.raise("""
    No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
    log into the Nerves device and update firmware on it using ssh.
    See your project's config.exs for this error message.
    """)

config :nerves_ssh,
  authorized_keys: Enum.map(keys, &File.read!/1)

# Configure the network using vintage_net
#
# Update regulatory_domain to your 2-letter country code E.g., "US"
#
# See https://github.com/nerves-networking/vintage_net for more information
config :vintage_net,
  regulatory_domain: "00",
  config: [
    {"usb0", %{type: VintageNetDirect}},
    {"eth0",
     %{
       type: VintageNetEthernet,
       ipv4: %{method: :dhcp}
     }},
    {"wlan0", %{type: VintageNetWiFi}}
  ]

config :mdns_lite,
  # The `hosts` key specifies what hostnames mdns_lite advertises.  `:hostname`
  # advertises the device's hostname.local.
  hosts: [:hostname, "usbproxy"],
  ttl: 120,

  # Advertise the following services over mDNS.
  services: [
    %{
      protocol: "ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "sftp-ssh",
      transport: "tcp",
      port: 22
    },
    %{
      protocol: "epmd",
      transport: "tcp",
      port: 4369
    }
  ]
