defmodule UsbProxy.DeviceRegistry do
  @moduledoc """
  Owns "what hardware exists and what's exported over USB/IP".

  One code path: `reconcile` scans sysfs and diffs against known state.
  Boot, hotplug uevents, and a periodic safety-net timer all funnel into
  it — uevents only make it run sooner. Startup assumes nothing about
  prior state.

  Stable naming: devices with a serial number are named
  `<product-slug>-<serial>` and matched by serial wherever they appear.
  Devices without a serial are matched by vid:pid at a specific port.
  When a device vanishes and something reappears at the same port with a
  different vid:pid within a short window, it is treated as the same
  hardware in a new mode (a board rebooting into its DFU/BOOTSEL loader):
  it keeps its stable name and is re-bound automatically.

  Every present device is bound to usbip-host and has USB autosuspend
  disabled (`power/control` = `on`). Serial-console carve-outs arrive in
  Phase 6.

  Hubs are transparent: devices behind (nested) hubs are enumerated,
  named, and bound like any other, and a hub disconnect just looks like
  all its children vanishing (they re-match on return). What topology
  DOES change is recovery semantics: only devices on a hub whose VBUS
  can really be switched (`:power_cyclable_hubs`, default the Pi's
  built-in `"1-1"`) can be power-cycled remotely. Devices behind an
  externally powered hub without per-port switching only ever get a
  logical re-enumeration. Each record carries `hub` and
  `power_cyclable?` so agents and the recovery service can tell the
  difference. Known gap: a serial-less device that moves along with its
  hub to a different upstream port is treated as new (its identity is
  port-based).

  This module is the data layer behind the Ash `Device` resource
  (Phase 5) — keep the query interface clean.
  """

  use GenServer
  require Logger

  @sysfs "/sys/bus/usb/devices"
  @usbip "/usr/sbin/usbip"
  @debounce_ms 750
  @periodic_ms 30_000
  # A vanished device re-appearing on the same port within this window
  # with a different vid:pid is the same hardware in a new mode.
  @rematch_window_ms 15_000

  ## Query API (backs the Ash Device resource — keep it clean)

  @doc "All known devices, present and absent, with live bind/attach state."
  @spec list() :: [map()]
  def list(), do: GenServer.call(__MODULE__, :list)

  @doc "One device by stable name."
  @spec get(String.t()) :: {:ok, map()} | :error
  def get(name), do: GenServer.call(__MODULE__, {:get, name})

  @doc "Trigger reconciliation outside the normal triggers (tests, recovery)."
  @spec reconcile_now() :: :ok
  def reconcile_now() do
    send(__MODULE__, :reconcile)
    :ok
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Any USB uevent just hurries up the next reconcile.
    NervesUEvent.subscribe([])
    {:ok, %{devices: %{}, timer: nil}, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_info(:reconcile, state), do: {:noreply, reconcile(state)}

  def handle_info(%PropertyTable.Event{} = event, state) do
    if usb_event?(event) do
      {:noreply, schedule(state, @debounce_ms)}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    {:reply, state.devices |> Map.values() |> Enum.map(&with_live_status/1), state}
  end

  def handle_call({:get, name}, _from, state) do
    case Map.fetch(state.devices, name) do
      {:ok, device} -> {:reply, {:ok, with_live_status(device)}, state}
      :error -> {:reply, :error, state}
    end
  end

  ## Reconciliation

  defp reconcile(state) do
    scanned = scan_sysfs()

    devices =
      state.devices
      |> mark_removed(scanned)
      |> then(&Enum.reduce(scanned, &1, fn seen, acc -> upsert(acc, seen) end))
      |> Map.new(fn {name, device} -> {name, ensure_bound(device)} end)

    %{state | devices: devices} |> schedule(@periodic_ms)
  end

  # A device is removed when its busid is gone from sysfs OR when the
  # node at its busid is different hardware — a device can disconnect
  # and something else (typically itself in a new mode, e.g. after a
  # flash reboots it out of BOOTSEL) can re-enumerate at the same port
  # entirely between two reconciles, so port occupancy alone proves
  # nothing. Marked-removed devices may be resurrected right after by
  # upsert's port re-match, keeping their stable name.
  defp mark_removed(devices, scanned) do
    by_busid = Map.new(scanned, &{&1.busid, &1})

    Map.new(devices, fn {name, device} ->
      if device.present? and not same_hardware?(device, by_busid[device.busid]) do
        Logger.info("device removed: #{name} (#{device.busid})")
        UsbProxy.EventLog.append(:device_removed, %{name: name, busid: device.busid})
        {name, %{device | present?: false, bound?: false, removed_at: now_ms()}}
      else
        {name, device}
      end
    end)
  end

  defp same_hardware?(_device, nil), do: false

  defp same_hardware?(%{serial: serial}, seen) when is_binary(serial),
    do: seen.serial == serial

  defp same_hardware?(device, seen),
    do: seen.serial == nil and device.vid == seen.vid and device.pid == seen.pid

  defp upsert(devices, seen) do
    case match_known(devices, seen) do
      {:serial, name} ->
        update_matched(devices, name, seen)

      {:port_identity, name} ->
        update_matched(devices, name, seen)

      {:mode_change, name} ->
        old = devices[name]

        Logger.info(
          "device mode change: #{name} #{old.vid}:#{old.pid} -> #{seen.vid}:#{seen.pid}"
        )

        UsbProxy.EventLog.append(:device_mode_changed, %{
          name: name,
          busid: seen.busid,
          from: "#{old.vid}:#{old.pid}",
          to: "#{seen.vid}:#{seen.pid}"
        })

        update_matched(devices, name, seen)

      :new ->
        name = unique_name(devices, seen)
        Logger.info("device added: #{name} (#{seen.busid} #{seen.vid}:#{seen.pid})")

        UsbProxy.EventLog.append(:device_added, %{
          name: name,
          busid: seen.busid,
          vidpid: "#{seen.vid}:#{seen.pid}",
          serial: seen.serial
        })

        Map.put(devices, name, %{
          name: name,
          vid: seen.vid,
          pid: seen.pid,
          serial: seen.serial,
          product: seen.product,
          manufacturer: seen.manufacturer,
          busid: seen.busid,
          hub: parent_busid(seen.busid),
          power_cyclable?: power_cyclable?(seen.busid),
          kind: :usbip,
          present?: true,
          bound?: false,
          removed_at: nil,
          inserted_at: DateTime.utc_now()
        })
    end
  end

  defp match_known(devices, seen) do
    known = Map.values(devices)

    find_by_serial(known, seen) ||
      find_by_port_identity(known, seen) ||
      find_mode_change(known, seen) ||
      :new
  end

  # vid:pid is part of the identity: serials are only unique per model
  # (every CP2102 ships as "0001"). Cross-mode continuity (which changes
  # vid:pid AND often serial) is port re-match's job, not this one's.
  defp find_by_serial(known, %{serial: serial} = seen) when is_binary(serial) do
    case Enum.find(known, &(&1.serial == serial and &1.vid == seen.vid and &1.pid == seen.pid)) do
      nil -> nil
      match -> {:serial, match.name}
    end
  end

  defp find_by_serial(_known, _seen), do: nil

  defp find_by_port_identity(known, %{serial: nil} = seen) do
    case Enum.find(known, fn d ->
           d.serial == nil and d.vid == seen.vid and d.pid == seen.pid and
             d.busid == seen.busid
         end) do
      nil -> nil
      match -> {:port_identity, match.name}
    end
  end

  defp find_by_port_identity(_known, _seen), do: nil

  # Same port, different identity, vanished moments ago: the same
  # hardware re-enumerated in a new mode (DFU/BOOTSEL/etc).
  defp find_mode_change(known, seen) do
    case Enum.find(known, fn d ->
           not d.present? and d.busid == seen.busid and d.removed_at != nil and
             now_ms() - d.removed_at <= @rematch_window_ms
         end) do
      nil -> nil
      match -> {:mode_change, match.name}
    end
  end

  defp update_matched(devices, name, seen) do
    Map.update!(devices, name, fn device ->
      %{
        device
        | vid: seen.vid,
          pid: seen.pid,
          serial: seen.serial,
          product: seen.product,
          manufacturer: seen.manufacturer,
          busid: seen.busid,
          hub: parent_busid(seen.busid),
          power_cyclable?: power_cyclable?(seen.busid),
          present?: true,
          removed_at: nil
      }
    end)
  end

  # "1-1.3.2.3" hangs off hub "1-1.3.2"; "1-1.4" off the built-in "1-1".
  defp parent_busid(busid) do
    case busid |> String.split(".") |> Enum.drop(-1) do
      [] -> "root"
      parts -> Enum.join(parts, ".")
    end
  end

  # Whether a :vbus recovery can truly cut this device's power: only on
  # hubs with verified working VBUS switching. All-or-nothing per hub.
  # The config default covers the platform (the Pi 4's built-in hub);
  # bench-specific additions (e.g. a PPPS-capable external hub, whose
  # busid depends on where it's plugged in) go in the KV store per
  # device: `Nerves.Runtime.KV.put("power_cyclable_hubs", "1-1,1-1.3")`.
  defp power_cyclable?(busid) do
    parent_busid(busid) in power_cyclable_hubs()
  end

  defp power_cyclable_hubs() do
    case Nerves.Runtime.KV.get("power_cyclable_hubs") do
      kv when is_binary(kv) and kv != "" ->
        kv |> String.split(",") |> Enum.map(&String.trim/1)

      _ ->
        Application.get_env(:usb_proxy, __MODULE__, [])
        |> Keyword.get(:power_cyclable_hubs, ["1-1"])
    end
  end

  ## Binding

  defp ensure_bound(%{present?: false} = device), do: device

  defp ensure_bound(device) do
    if current_driver(device.busid) == "usbip-host" do
      %{device | bound?: true}
    else
      bind(device)
    end
  end

  defp bind(device) do
    case System.cmd(@usbip, ["bind", "-b", device.busid], stderr_to_stdout: true) do
      {_out, 0} ->
        disable_autosuspend(device.busid)
        Logger.info("bound #{device.name} (#{device.busid})")
        UsbProxy.EventLog.append(:device_bound, %{name: device.name, busid: device.busid})
        %{device | bound?: true}

      {out, _code} ->
        if String.contains?(out, "already bound") do
          disable_autosuspend(device.busid)
          %{device | bound?: true}
        else
          Logger.warning("bind failed for #{device.name} (#{device.busid}): #{String.trim(out)}")

          UsbProxy.EventLog.append(:device_bind_failed, %{
            name: device.name,
            busid: device.busid,
            error: String.trim(out)
          })

          %{device | bound?: false}
        end
    end
  end

  # Exported devices must not autosuspend under an idle client.
  defp disable_autosuspend(busid) do
    case File.write(Path.join([@sysfs, busid, "power/control"]), "on") do
      :ok -> :ok
      {:error, reason} -> Logger.warning("power/control write failed for #{busid}: #{reason}")
    end
  end

  ## Live status (read fresh at query time so attach state is current)

  defp with_live_status(%{present?: false} = device),
    do: Map.merge(device, %{bound?: false, attached?: false})

  defp with_live_status(device) do
    bound? = current_driver(device.busid) == "usbip-host"
    Map.merge(device, %{bound?: bound?, attached?: bound? and usbip_status(device.busid) == 2})
  end

  defp current_driver(busid) do
    case File.read_link(Path.join([@sysfs, busid, "driver"])) do
      {:ok, path} -> Path.basename(path)
      _ -> nil
    end
  end

  # usbip-host exposes usbip_status: 1 available, 2 attached by a client,
  # 3 error.
  defp usbip_status(busid) do
    case File.read(Path.join([@sysfs, busid, "usbip_status"])) do
      {:ok, contents} -> contents |> String.trim() |> String.to_integer()
      _ -> nil
    end
  end

  ## Sysfs scanning

  defp scan_sysfs() do
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
          class: sysfs_attr(busid, "bDeviceClass")
        }
    end
  end

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

  ## Naming

  defp unique_name(devices, seen) do
    base = base_name(seen)

    if Map.has_key?(devices, base) do
      "#{base}-#{port_slug(seen.busid)}"
    else
      base
    end
  end

  defp base_name(%{serial: serial} = seen) when is_binary(serial) do
    "#{product_slug(seen)}-#{slug(serial)}"
  end

  defp base_name(seen) do
    "#{product_slug(seen)}-#{seen.vid}#{seen.pid}-#{port_slug(seen.busid)}"
  end

  defp product_slug(%{product: product}) when is_binary(product), do: slug(product)
  defp product_slug(_), do: "usb"

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp port_slug(busid), do: String.replace(busid, ".", "-")

  ## Scheduling

  defp schedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :reconcile, delay_ms)}
  end

  defp usb_event?(%PropertyTable.Event{value: value, previous_value: previous}) do
    subsystem = fn
      %{"subsystem" => subsystem} -> subsystem
      _ -> nil
    end

    subsystem.(value) == "usb" or subsystem.(previous) == "usb"
  end

  defp now_ms(), do: System.monotonic_time(:millisecond)
end
