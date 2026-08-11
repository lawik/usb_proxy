defmodule UsbProxy.Api do
  @moduledoc """
  The Ash domain for everything agent-facing.

  Standing rule: every agent-facing operation is an action on a
  resource in this domain, exposed BOTH via AshJsonApi (/api) and as
  ash_ai MCP tools (/mcp). Internal code calls the same actions.
  No service reaches around Ash.

  Tool descriptions are agent-facing documentation: written for an
  agent that has never seen this hardware.
  """

  use Ash.Domain, extensions: [AshJsonApi.Domain, AshAi]

  tools do
    tool :list_devices, UsbProxy.Api.Device, :read do
      description("""
      List every USB device on this usbproxy with live state. Each entry
      has a stable `name` (survives replugging and mode changes — use it
      to refer to the device), the current `busid` (needed for
      `usbip attach`; changes on replug, always re-resolve it here
      first), `present`/`bound`/`attached` booleans, and `kind`. A
      device is free to attach over USB/IP when present=true,
      bound=true, attached=false. `power_cyclable` tells you whether a
      :vbus recovery can truly power-cycle it (false = it sits behind an
      externally powered hub and can only be re-enumerated).
      """)
    end

    tool :get_device, UsbProxy.Api.Device, :get do
      description("""
      Fetch one USB device by its stable name, with live state. Use
      after list_devices to re-check a device right before attaching:
      the `busid` can change when hardware is replugged, and
      `attached=true` means someone else currently holds it.
      """)
    end

    tool(:set_device_exposure, UsbProxy.Api.Device, :set_exposure)

    tool(:switch_device_mode, UsbProxy.Api.Device, :switch_mode)

    tool :recover, UsbProxy.Api.RecoveryAction, :create do
      description("""
      Recovery ladder when hardware misbehaves, least to most disruptive.
      level=vbus: power-cycle the usbproxy's switchable USB hubs — ALL
      devices on them drop and return within ~10 seconds, re-bound
      automatically, consoles resume; devices behind non-switchable hubs
      only re-enumerate (see each device's power_cyclable). level=reboot:
      reboot the whole usbproxy — expect ~half a minute of downtime,
      poll /up until it answers, then re-resolve busids before
      re-attaching. Both levels are rate-limited: a rejected call errors
      with a retry time — wait, don't loop. If neither level helps, a
      human has to touch the hardware.
      """)
    end

    tool :list_serial_consoles, UsbProxy.Api.SerialConsole, :read do
      description("""
      List serial consoles this usbproxy exports. Each console maps a
      serial adapter (by stable device name) to a TCP port on the
      usbproxy: connect with plain TCP (`nc <usbproxy> <port>`) for a
      raw byte pipe to the target's UART — no protocol, no
      authentication (network reachability is the access control).
      """)
    end
  end

  resources do
    resource(UsbProxy.Api.Device)
    resource(UsbProxy.Api.SerialConsole)
    resource(UsbProxy.Api.FlashJob)
    resource(UsbProxy.Api.RecoveryAction)
  end
end
