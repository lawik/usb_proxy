defmodule UsbProxy.RegistryCase do
  @moduledoc """
  Test case running the real DeviceRegistry against FakeHardware.
  `plug/1`-style state changes go through `FakeHardware.set_devices/1`
  followed by `sync/0`, which forces a reconcile and waits for it.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import UsbProxy.RegistryCase
      alias UsbProxy.{DeviceRegistry, FakeHardware}
    end
  end

  setup do
    previous = Application.get_env(:usb_proxy, UsbProxy.DeviceRegistry, [])

    Application.put_env(:usb_proxy, UsbProxy.DeviceRegistry,
      hardware: UsbProxy.FakeHardware,
      subscribe_uevents?: false,
      rematch_window_ms: 200,
      power_cyclable_hubs: ["1-1"]
    )

    on_exit(fn -> Application.put_env(:usb_proxy, UsbProxy.DeviceRegistry, previous) end)

    start_supervised!(%{
      id: UsbProxy.FakeHardware,
      start: {UsbProxy.FakeHardware, :start_link, []}
    })

    start_supervised!(UsbProxy.DeviceRegistry)
    :ok
  end

  @doc "Force a reconcile and block until it has run."
  def sync() do
    UsbProxy.DeviceRegistry.reconcile_now()
    # Any call serializes behind the :reconcile message in the mailbox.
    UsbProxy.DeviceRegistry.list()
    :ok
  end
end
