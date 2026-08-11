defmodule UsbProxy.ModeSwitch do
  @moduledoc """
  Best-effort device mode transitions, requested by agents through the
  `switch_mode` action. Strategies are device-state-specific and can
  fail for many reasons; each failure names what to try instead.

  Known transitions:

    * `"bootloader"` — a serial-exposed MicroPython-style device: inject
      an interrupt + `machine.bootloader()` into its REPL via the
      console UART. The device re-enumerates (e.g. RP2 BOOTSEL mass
      storage) and keeps its stable name.
    * `"app"` — power-cycle the device's port so it boots whatever is on
      flash. Only possible where VBUS switching works (power_cyclable);
      note all ports on that hub cycle together.
  """

  require Logger

  @spec request(String.t(), String.t()) :: {:ok, map()} | {:error, String.t()}
  def request(name, mode) do
    with {:ok, device} <- fetch(name) do
      UsbProxy.EventLog.append(:mode_switch_requested, %{name: name, mode: mode})

      case {mode, device} do
        {"bootloader", %{exposure: :serial}} ->
          repl_bootloader(device)

        {"bootloader", %{exposure: exposure}} ->
          {:error,
           "device is exposed as #{exposure}, not serial — its REPL isn't reachable from " <>
             "here. Attach it over USB/IP and switch modes yourself, or set_exposure to " <>
             "serial first."}

        {"app", %{power_cyclable?: true, busid: busid}} ->
          power_cycle(device, busid)

        {"app", _} ->
          {:error,
           "device is not power-cyclable (behind an externally powered hub) — " <>
             "boot-to-app needs a power cycle or device-specific command."}

        {other, _} ->
          {:error, "unknown mode #{inspect(other)}; known modes: bootloader, app"}
      end
    end
  end

  defp fetch(name) do
    case UsbProxy.DeviceRegistry.get(name) do
      {:ok, %{present?: false}} -> {:error, "device #{name} is not present"}
      {:ok, device} -> {:ok, device}
      :error -> {:error, "no device named #{name}"}
    end
  end

  # Interrupt whatever runs, then ask MicroPython for the bootloader.
  defp repl_bootloader(device) do
    with {:ok, pid} <- UsbProxy.SerialConsoles.Manager.worker_pid(device.name),
         :ok <-
           inject_paced(pid, ["\r\x03", "\x03", "import machine\r", "machine.bootloader()\r"]) do
      Logger.info("bootloader requested for #{device.name} via REPL")
      {:ok, %{name: device.name, requested: "bootloader", via: "repl"}}
    else
      {:error, :no_console} ->
        {:error, "no console exists for this device"}

      {:error, :no_uart} ->
        {:error, "console has no open UART (adapter missing?)"}

      {:error, reason} ->
        {:error, "REPL injection failed: #{inspect(reason)}"}
    end
  end

  defp inject_paced(pid, chunks) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      case UsbProxy.SerialConsoles.Worker.inject(pid, chunk) do
        :ok ->
          Process.sleep(150)
          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  # Whole hub, not per-port: the Pi 4's VL817 accepts per-port commands
  # but its VBUS switch is ganged — a single-port "cycle" re-enumerates
  # without cutting power (verified: a Pico in BOOTSEL stays in BOOTSEL).
  # Only cycling all ports together genuinely cuts power, with the
  # documented collateral: everything on that hub re-enumerates.
  defp power_cycle(device, busid) do
    hub = busid |> String.split(".") |> Enum.drop(-1) |> Enum.join(".")

    case System.cmd("uhubctl", ["-l", hub, "-a", "cycle", "-d", "3"], stderr_to_stdout: true) do
      {_out, 0} ->
        Logger.info("power-cycled hub #{hub} for #{device.name}")
        {:ok, %{name: device.name, requested: "app", via: "power_cycle"}}

      {out, code} ->
        {:error, "uhubctl failed (#{code}): #{String.trim(out)}"}
    end
  end
end
