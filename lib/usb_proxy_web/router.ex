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
  # The instructions are the agent-facing operating manual: everything a
  # fresh agent needs beyond the tool list lives here, in-band.
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
    otp_app: :usb_proxy,
    instructions: """
    This server fronts a usbproxy: a box with physical USB devices (dev
    boards, serial adapters, card readers) that you can use remotely.
    Everything is discovered live — never cache busids or port numbers.

    Devices are exposed one of two ways (see each device's `exposure`):

    - serial: connect to its TCP console port (from list_serial_consoles)
      with plain TCP, e.g. `nc <this-host> <port>`. Raw byte pipe at
      115200. One client at a time; connecting replaces the previous
      client. For MicroPython boards, press Ctrl-C then Enter to get the
      >>> REPL prompt.
    - usbip: attach it into YOUR kernel over USB/IP (needs vhci_hcd and
      usbip tools on your side):
        sudo modprobe vhci_hcd                     # once per boot
        sudo usbip attach -r <this-host> -b <busid>  # busid from get_device, freshly resolved
      The device then appears as local USB (lsusb, /dev/...). Detach
      when your task is done — never hold an attachment across long
      idle periods, others may need the device:
        usbip port                    # find your local port N
        sudo usbip detach -p <N>
      If your usbip side wedges (dead ttys, attach hangs, device
      re-enumerated remotely): sudo modprobe -r vhci_hcd && sudo
      modprobe vhci_hcd, then re-resolve the busid and re-attach.

    Devices keep a stable `name` across replugs and mode changes, but
    `busid`, vid:pid, `kind`, and `exposure` all change when a device
    switches modes (e.g. a Pico flipping between MicroPython and its
    BOOTSEL bootloader) — re-run get_device after anything that
    re-enumerates a device, including flashing it.

    If a device misbehaves: try switch_device_mode first, then recover
    level=vbus (all devices on the box drop and return within ~10s,
    re-exported automatically), then recover level=reboot (the whole box
    is back in ~30s — poll /up on port 4000, then re-resolve busids and
    re-attach). Recovery is rate-limited: a rejected call tells you how
    long to wait. Do not retry in a loop.
    """
  )
end
