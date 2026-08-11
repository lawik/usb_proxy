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
      How this device is meant to be used: :usbip (attach over USB/IP),
      :serial (a serial console, connect via its TCP port instead),
      :flash_target (flash via the flash service).
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
          present: d.present?,
          bound: d.bound?,
          attached: d.attached?,
          kind: d.kind
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
