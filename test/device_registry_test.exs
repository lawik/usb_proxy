defmodule UsbProxy.DeviceRegistryTest do
  use UsbProxy.RegistryCase, async: false

  defp get!(name) do
    {:ok, device} = DeviceRegistry.get(name)
    device
  end

  describe "discovery, naming and binding" do
    test "devices are named from product and serial, and usbip-bound" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.4", product: "RP2 Boot", serial: "E0C9125B0D9B")
      ])

      sync()

      assert [device] = DeviceRegistry.list()
      assert device.name == "rp2-boot-e0c9125b0d9b"
      assert device.present?
      assert device.bound?
      assert device.kind == :usbip
      assert device.exposure == :usbip
    end

    test "serial-less devices are named by vid:pid and port" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.2", product: "Widget", serial: nil)
      ])

      sync()

      assert [%{name: "widget-12345678-1-1-2"}] = DeviceRegistry.list()
    end

    test "name collisions get a port suffix" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.1", product: "Twin", serial: "0001"),
        FakeHardware.device(busid: "1-1.2", product: "Twin", serial: "0001")
      ])

      sync()

      names = DeviceRegistry.list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["twin-0001", "twin-0001-1-1-2"]
    end

    test "hub topology and power_cyclable derive from the busid" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.4", serial: "a"),
        FakeHardware.device(busid: "1-1.3.2.3", serial: "b")
      ])

      sync()

      direct = get!("test-device-a")
      nested = get!("test-device-b")
      assert %{hub: "1-1", power_cyclable?: true} = direct
      assert %{hub: "1-1.3.2", power_cyclable?: false} = nested
    end
  end

  describe "classification" do
    test "UART bridge vids are serial and stay unbound" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.1", vid: "0403", pid: "6001", serial: "FT1")
      ])

      sync()

      assert [%{kind: :serial, exposure: :serial, bound?: false}] = DeviceRegistry.list()
    end

    test "pure CDC-ACM devices are serial" do
      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.4",
          serial: "mp1",
          interface_classes: [{0x02, 0x02}, {0x0A, 0x00}]
        )
      ])

      sync()

      assert [%{kind: :serial}] = DeviceRegistry.list()
    end

    test "CDC composites (gadget networking) stay usbip — the waffle regression" do
      # CDC-ECM (02/06) shares class 02 with ACM; a net+acm gadget must
      # be exposed whole over USB/IP.
      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.3.2.3",
          serial: "gadget",
          interface_classes: [{0x02, 0x06}, {0x0A, 0x00}, {0x02, 0x02}]
        )
      ])

      sync()

      assert [%{kind: :usbip, bound?: true}] = DeviceRegistry.list()
    end
  end

  describe "removal and replug" do
    test "unplugged devices go absent; replug into another port keeps the name" do
      pico = FakeHardware.device(busid: "1-1.1", product: "Pico", serial: "abc")
      FakeHardware.set_devices([pico])
      sync()

      FakeHardware.set_devices([])
      sync()
      assert %{present?: false, bound?: false} = get!("pico-abc")

      FakeHardware.set_devices([%{pico | busid: "1-1.4"}])
      sync()

      assert %{present?: true, bound?: true, busid: "1-1.4"} = get!("pico-abc")
      assert [_only_one] = DeviceRegistry.list()
    end

    test "same-port replacement by different hardware is a removal — the phantom regression" do
      # A flash reboots the device out of BOOTSEL; the new mode
      # re-enumerates at the SAME busid between two reconciles. The old
      # record must not survive as a present phantom.
      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.4",
          vid: "2e8a",
          pid: "0003",
          serial: "BOOT1",
          product: "RP2 Boot"
        )
      ])

      sync()

      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.4",
          vid: "2e8a",
          pid: "0005",
          serial: "app1",
          product: "Board in FS mode"
        )
      ])

      sync()

      # Same-port re-match within the window: one record, same stable
      # name, carrying the new identity.
      assert [device] = DeviceRegistry.list()
      assert device.name == "rp2-boot-boot1"
      assert device.vid == "2e8a"
      assert device.pid == "0005"
      assert device.present?
    end

    test "same-port arrival after the re-match window is a new device" do
      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.4", vid: "2e8a", pid: "0003", serial: "BOOT1")
      ])

      sync()

      FakeHardware.set_devices([])
      sync()

      # rematch_window_ms is 200 in tests
      Process.sleep(250)

      FakeHardware.set_devices([
        FakeHardware.device(busid: "1-1.4", vid: "2e8a", pid: "0005", serial: "app1")
      ])

      sync()

      names = DeviceRegistry.list() |> Enum.map(& &1.name) |> Enum.sort()
      assert length(names) == 2
    end

    test "identical adapters cannot both claim one record — the CP2102 twins" do
      # Two identical adapters share vid, pid AND serial ("0001").
      # Each must keep its own record instead of hijacking the other's.
      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.1",
          vid: "10c4",
          pid: "ea60",
          serial: "0001",
          product: "CP2102"
        ),
        FakeHardware.device(
          busid: "1-1.2",
          vid: "10c4",
          pid: "ea60",
          serial: "0001",
          product: "CP2102"
        )
      ])

      sync()
      sync()

      devices = DeviceRegistry.list()
      assert length(devices) == 2
      assert devices |> Enum.map(& &1.busid) |> Enum.sort() == ["1-1.1", "1-1.2"]
      # Stable across repeated reconciles: no busid flapping.
      by_name = Map.new(devices, &{&1.name, &1.busid})
      sync()
      assert Map.new(DeviceRegistry.list(), &{&1.name, &1.busid}) == by_name
    end
  end

  describe "exposure" do
    test "set_exposure usbip binds a serial device; auto releases it again" do
      FakeHardware.set_devices([
        FakeHardware.device(
          busid: "1-1.1",
          vid: "0403",
          pid: "6001",
          serial: "FT1",
          product: "TTL232R"
        )
      ])

      sync()
      assert %{exposure: :serial, bound?: false} = get!("ttl232r-ft1")

      assert {:ok, %{exposure: :usbip}} = DeviceRegistry.set_exposure("ttl232r-ft1", :usbip)
      assert %{bound?: true} = get!("ttl232r-ft1")

      assert {:ok, %{exposure: :serial}} = DeviceRegistry.set_exposure("ttl232r-ft1", :auto)
      assert %{bound?: false} = get!("ttl232r-ft1")
    end

    test "set_exposure on an unknown device errors" do
      assert {:error, :not_found} = DeviceRegistry.set_exposure("nope", :usbip)
    end
  end

  describe "attach state" do
    test "attached? reflects usbip_status" do
      FakeHardware.set_devices([FakeHardware.device(busid: "1-1.1", serial: "x")])
      sync()

      assert %{attached?: false} = get!("test-device-x")

      FakeHardware.set_usbip_status("1-1.1", 2)
      assert %{attached?: true} = get!("test-device-x")

      FakeHardware.set_usbip_status("1-1.1", 1)
      assert %{attached?: false} = get!("test-device-x")
    end
  end
end
