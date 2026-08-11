defmodule UsbProxy.DescriptorParsingTest do
  use ExUnit.Case, async: true

  alias UsbProxy.DeviceRegistry.Sysfs

  # Build a minimal interface descriptor (9 bytes, type 4).
  defp interface(class, subclass) do
    <<9, 4, 0, 0, 1, class, subclass, 0, 0>>
  end

  # An 18-byte device descriptor (type 1) that must be skipped.
  defp device_descriptor() do
    <<18, 1>> <> :binary.copy(<<0>>, 16)
  end

  test "extracts class/subclass pairs from interface descriptors" do
    blob = device_descriptor() <> interface(0x02, 0x02) <> interface(0x0A, 0x00)
    assert Sysfs.parse_interface_classes(blob) == [{0x02, 0x02}, {0x0A, 0x00}]
  end

  test "deduplicates repeated interfaces" do
    blob = interface(0x08, 0x06) <> interface(0x08, 0x06)
    assert Sysfs.parse_interface_classes(blob) == [{0x08, 0x06}]
  end

  test "tolerates truncated trailing data" do
    blob = interface(0x02, 0x02) <> <<9, 4, 0>>
    assert Sysfs.parse_interface_classes(blob) == [{0x02, 0x02}]
  end

  test "tolerates zero-length descriptor without looping forever" do
    blob = <<0, 0>> <> interface(0x02, 0x02)
    assert Sysfs.parse_interface_classes(blob) == []
  end

  test "empty blob yields no interfaces" do
    assert Sysfs.parse_interface_classes(<<>>) == []
  end
end
