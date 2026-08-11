defmodule UsbProxy.DeviceRegistry.Hardware do
  @moduledoc """
  Hardware access used by the DeviceRegistry, as a behaviour so tests
  can drive the registry's full state machine against fake hardware.
  The real implementation is `UsbProxy.DeviceRegistry.Sysfs`; override
  with `config :usb_proxy, UsbProxy.DeviceRegistry, hardware: MyFake`.
  """

  @typedoc "One enumerated USB device as seen on the bus."
  @type seen :: %{
          busid: String.t(),
          vid: String.t(),
          pid: String.t() | nil,
          serial: String.t() | nil,
          product: String.t() | nil,
          manufacturer: String.t() | nil,
          class: String.t() | nil,
          interface_classes: [{byte(), byte()}]
        }

  @callback scan() :: [seen()]
  @callback current_driver(busid :: String.t()) :: String.t() | nil
  @callback usbip(:bind | :unbind, busid :: String.t()) :: {String.t(), non_neg_integer()}
  @callback disable_autosuspend(busid :: String.t()) :: :ok | {:error, term()}
  @callback usbip_status(busid :: String.t()) :: integer() | nil
end
