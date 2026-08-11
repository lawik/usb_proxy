defmodule UsbProxy.FakeHardware do
  @moduledoc """
  Agent-backed `UsbProxy.DeviceRegistry.Hardware` for tests: set what
  the "bus" shows with `set_devices/1`, and bind state is tracked the
  way the real kernel behaves (bind sets the driver to usbip-host,
  unbind clears it).
  """

  @behaviour UsbProxy.DeviceRegistry.Hardware

  def start_link() do
    Agent.start_link(fn -> %{devices: [], drivers: %{}, status: %{}} end, name: __MODULE__)
  end

  def set_devices(devices) do
    Agent.update(__MODULE__, fn state ->
      # Drivers for busids that vanished are forgotten, like the kernel would.
      busids = MapSet.new(devices, & &1.busid)
      drivers = Map.filter(state.drivers, fn {busid, _} -> MapSet.member?(busids, busid) end)
      %{state | devices: devices, drivers: drivers}
    end)
  end

  def set_usbip_status(busid, status) do
    Agent.update(__MODULE__, fn state -> put_in(state.status[busid], status) end)
  end

  def device(attrs) do
    Map.merge(
      %{
        busid: "1-1.1",
        vid: "1234",
        pid: "5678",
        serial: nil,
        product: "Test Device",
        manufacturer: "Test",
        class: "00",
        interface_classes: [{0xFF, 0x00}]
      },
      Map.new(attrs)
    )
  end

  @impl true
  def scan(), do: Agent.get(__MODULE__, & &1.devices)

  @impl true
  def current_driver(busid), do: Agent.get(__MODULE__, & &1.drivers[busid])

  @impl true
  def usbip(:bind, busid) do
    Agent.update(__MODULE__, fn state -> put_in(state.drivers[busid], "usbip-host") end)
    {"", 0}
  end

  def usbip(:unbind, busid) do
    Agent.update(__MODULE__, fn state -> put_in(state.drivers[busid], nil) end)
    {"", 0}
  end

  @impl true
  def disable_autosuspend(_busid), do: :ok

  @impl true
  def usbip_status(busid) do
    Agent.get(__MODULE__, fn state ->
      state.status[busid] || if state.drivers[busid] == "usbip-host", do: 1
    end)
  end
end
