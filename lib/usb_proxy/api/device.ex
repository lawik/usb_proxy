defmodule UsbProxy.Api.Device do
  @moduledoc """
  A USB device attached to this usbproxy, as seen by agents.

  Read-only: the DeviceRegistry (Phase 4) owns the data; every read
  snapshots it via the Simple data layer so Ash filtering (and the
  JSON:API get route) work on live state.
  """

  use Ash.Resource,
    domain: UsbProxy.Api,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("device")

    primary_key do
      keys([:name])
      delimiter("|")
    end

    routes do
      base("/devices")
      index(:read)
      get(:read, path_param_is_composite_key: :id)
      route(:post, "/:name/exposure", :set_exposure)
      route(:post, "/:name/mode", :switch_mode)
    end
  end

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List every USB device known to this usbproxy.")
    end

    read :get do
      description("Fetch one device by its stable name.")
      get_by(:name)
    end

    action :set_exposure, :map do
      description("""
      Override how a device is exposed. exposure=usbip: force USB/IP
      export even if it presents a serial interface (its console is
      released). exposure=serial: hand it to the serial console service.
      exposure=auto: follow automatic classification. Takes effect
      within a second. Best-effort: a device with no UART set to serial
      yields a console stuck at adapter_missing.
      """)

      argument(:name, :string, allow_nil?: false)

      argument(:exposure, :atom,
        allow_nil?: false,
        constraints: [one_of: [:usbip, :serial, :auto]]
      )

      run(fn input, _context ->
        case UsbProxy.DeviceRegistry.set_exposure(
               input.arguments.name,
               input.arguments.exposure
             ) do
          {:ok, device} ->
            {:ok, %{name: device.name, kind: device.kind, exposure: device.exposure}}

          {:error, :not_found} ->
            {:error,
             Ash.Error.Action.InvalidArgument.exception(
               field: :name,
               message: "no device named #{input.arguments.name}"
             )}
        end
      end)
    end

    action :switch_mode, :map do
      description("""
      Ask a device to switch modes, best-effort. mode=bootloader: for a
      serial-exposed MicroPython-style device, inject
      machine.bootloader() into its REPL — it re-enumerates (keeping its
      stable name) as its bootloader, typically USB/IP-attachable mass
      storage for flashing. mode=app: power-cycle the device's port so
      it boots whatever is on flash (only where power_cyclable; all
      ports on that hub cycle together). Errors explain what to try
      instead. Re-query the device afterwards: vid:pid, kind, exposure
      and busid may all change.
      """)

      argument(:name, :string, allow_nil?: false)
      argument(:mode, :string, allow_nil?: false)

      run(fn input, _context ->
        case UsbProxy.ModeSwitch.request(input.arguments.name, input.arguments.mode) do
          {:ok, result} ->
            {:ok, result}

          # A plain-string error would be masked as "unexpected error";
          # the explain-what-to-try-instead messages must reach agents.
          {:error, message} when is_binary(message) ->
            {:error, Ash.Error.Action.InvalidArgument.exception(field: :mode, message: message)}

          {:error, other} ->
            {:error, other}
        end
      end)
    end
  end

  preparations do
    prepare(UsbProxy.Api.Device.SetData)
  end

  attributes do
    attribute :name, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)

      description("""
      Stable identifier for the physical device. Survives replugging,
      reboots, and mode changes (e.g. a board re-enumerating into its
      DFU/BOOTSEL loader keeps its name). Use this in all API calls.
      """)
    end

    attribute(:vid, :string, public?: true, description: "USB vendor id (hex, e.g. 2e8a)")
    attribute(:pid, :string, public?: true, description: "USB product id (hex)")

    attribute(:serial, :string,
      public?: true,
      description: "USB serial number, if the device has one"
    )

    attribute(:product, :string, public?: true, description: "Product string from the device")

    attribute(:manufacturer, :string,
      public?: true,
      description: "Manufacturer string from the device"
    )

    attribute :busid, :string do
      public?(true)

      description("""
      Current usbip bus id (e.g. 1-1.4). Changes when the device is
      replugged into a different port — always resolve it fresh via this
      API right before `usbip attach -r <usbproxy> -b <busid>`.
      """)
    end

    attribute :hub, :string do
      public?(true)
      description("Bus id of the hub this device hangs off (topology info).")
    end

    attribute :power_cyclable, :boolean do
      public?(true)

      description("""
      Whether a :vbus recovery action can truly cut this device's power.
      true: on a hub with working VBUS switching (all ports cycle
      together). false: behind an externally powered hub — recovery can
      only re-enumerate it, not power-cycle it; a hard-wedged device
      there needs a human.
      """)
    end

    attribute :present, :boolean do
      public?(true)
      description("Whether the device is currently enumerated on the USB bus.")
    end

    attribute :bound, :boolean do
      public?(true)
      description("Whether the device is exported over USB/IP (bound to usbip-host).")
    end

    attribute :attached, :boolean do
      public?(true)

      description(
        "Whether a USB/IP client currently has the device attached. Attached devices cannot be attached by anyone else until released."
      )
    end

    attribute :kind, :atom do
      public?(true)
      constraints(one_of: [:usbip, :serial, :flash_target])

      description("""
      What the device IS in its current mode: :serial (presents a serial
      interface — UART bridge or pure-CDC board), :usbip (everything
      else, incl. composites). Re-classified live when a device changes
      modes.
      """)
    end

    attribute :exposure, :atom do
      public?(true)
      constraints(one_of: [:usbip, :serial])

      description("""
      How the device is exposed right now. :serial — NOT attachable over
      USB/IP; use its serial console TCP port (see list_serial_consoles).
      :usbip — attachable via `usbip attach`. Follows `kind` unless
      overridden via set_exposure.
      """)
    end
  end

  @doc false
  def records() do
    if Process.whereis(UsbProxy.DeviceRegistry) do
      Enum.map(UsbProxy.DeviceRegistry.list(), fn d ->
        struct!(__MODULE__, %{
          name: d.name,
          vid: d.vid,
          pid: d.pid,
          serial: d.serial,
          product: d.product,
          manufacturer: d.manufacturer,
          busid: d.busid,
          hub: d.hub,
          power_cyclable: d.power_cyclable?,
          present: d.present?,
          bound: d.bound?,
          attached: d.attached?,
          kind: d.kind,
          exposure: d.exposure
        })
      end)
    else
      []
    end
  end
end

defmodule UsbProxy.Api.Device.SetData do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      Ash.DataLayer.Simple.set_data(query, UsbProxy.Api.Device.records())
    end)
  end
end
