defmodule UsbProxy.DeviceRegistry.Sysfs do
  @moduledoc """
  The real `UsbProxy.DeviceRegistry.Hardware`: sysfs enumeration and the
  usbip userspace tools.
  """

  @behaviour UsbProxy.DeviceRegistry.Hardware

  require Logger

  @sysfs "/sys/bus/usb/devices"
  @usbip "/usr/sbin/usbip"

  @impl true
  def scan() do
    case File.ls(@sysfs) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^\d+-[\d.]+$/, &1))
        |> Enum.map(&read_device/1)
        |> Enum.reject(&(&1 == nil or hub?(&1)))

      {:error, _} ->
        []
    end
  end

  @impl true
  def current_driver(busid) do
    case File.read_link(Path.join([@sysfs, busid, "driver"])) do
      {:ok, path} -> Path.basename(path)
      _ -> nil
    end
  end

  @impl true
  def usbip(action, busid) when action in [:bind, :unbind] do
    System.cmd(@usbip, [to_string(action), "-b", busid], stderr_to_stdout: true)
  end

  # Exported devices must not autosuspend under an idle client.
  @impl true
  def disable_autosuspend(busid) do
    File.write(Path.join([@sysfs, busid, "power/control"]), "on")
  end

  # usbip-host exposes usbip_status: 1 available, 2 attached by a client,
  # 3 error.
  @impl true
  def usbip_status(busid) do
    case File.read(Path.join([@sysfs, busid, "usbip_status"])) do
      {:ok, contents} -> contents |> String.trim() |> String.to_integer()
      _ -> nil
    end
  end

  defp read_device(busid) do
    case sysfs_attr(busid, "idVendor") do
      nil ->
        nil

      vid ->
        %{
          busid: busid,
          vid: vid,
          pid: sysfs_attr(busid, "idProduct"),
          serial: sysfs_attr(busid, "serial"),
          product: sysfs_attr(busid, "product"),
          manufacturer: sysfs_attr(busid, "manufacturer"),
          class: sysfs_attr(busid, "bDeviceClass"),
          interface_classes: interface_classes(busid)
        }
    end
  end

  # Interface classes parsed from the raw descriptors file — the sysfs
  # interface subdirectories vanish once usbip-host owns the device, so
  # this is the only driver-independent source.
  defp interface_classes(busid) do
    case File.read(Path.join([@sysfs, busid, "descriptors"])) do
      {:ok, binary} -> parse_interface_classes(binary, [])
      _ -> []
    end
  end

  @doc """
  Parse `{class, subclass}` pairs of the interface descriptors out of a
  raw USB descriptors blob (as read from sysfs `descriptors`).
  """
  @spec parse_interface_classes(binary()) :: [{byte(), byte()}]
  def parse_interface_classes(binary), do: parse_interface_classes(binary, [])

  defp parse_interface_classes(<<len, _type, _::binary>> = binary, acc)
       when len > 0 and byte_size(binary) >= len do
    <<descriptor::binary-size(^len), rest::binary>> = binary

    acc =
      case descriptor do
        # bDescriptorType 4 = interface; class at offset 5, subclass at 6
        <<_len, 4, _num, _alt, _num_endpoints, class, subclass, _::binary>> ->
          [{class, subclass} | acc]

        _ ->
          acc
      end

    parse_interface_classes(rest, acc)
  end

  defp parse_interface_classes(_rest, acc), do: acc |> Enum.reverse() |> Enum.uniq()

  defp hub?(%{class: "09"}), do: true
  defp hub?(_), do: false

  defp sysfs_attr(busid, attr) do
    case File.read(Path.join([@sysfs, busid, attr])) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> nil
          value -> value
        end

      _ ->
        nil
    end
  end
end
