defmodule UsbProxy.Application do
  @moduledoc """
  usbproxy supervision tree.

  Boot-reconciliation rule: startup code assumes nothing about prior
  state. The box can lose power at any moment; there is no shutdown
  handler that matters. Every service must reconcile reality (what
  hardware is present, what is exported, what tailscaled remembers)
  from scratch on start.
  """

  use Application

  @impl true
  def start(_type, _args) do
    ensure_endpoint_secret()

    children =
      [
        # First, so every later child can log operational events.
        UsbProxy.EventLog,
        {Phoenix.PubSub, name: UsbProxy.PubSub},
        UsbProxyWeb.Endpoint
      ] ++ target_children()

    opts = [strategy: :one_for_one, name: UsbProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The API serves no sessions or cookies, so a per-boot random secret
  # is fine on the device. Host config sets a static one.
  defp ensure_endpoint_secret() do
    config = Application.get_env(:usb_proxy, UsbProxyWeb.Endpoint, [])

    unless config[:secret_key_base] do
      secret = Base.encode64(:crypto.strong_rand_bytes(48))

      Application.put_env(
        :usb_proxy,
        UsbProxyWeb.Endpoint,
        Keyword.put(config, :secret_key_base, secret)
      )
    end
  end

  # List all child processes to be supervised
  if Mix.target() == :host do
    defp target_children() do
      [
        # Children that only run on the host during development or test.
        # In general, prefer using `config/host.exs` for differences.
      ]
    end
  else
    defp target_children() do
      [
        # Joins/rejoins the tailnet; state on the data partition.
        UsbProxy.Tailscale,
        # Serves bound devices to USB/IP clients on 3240.
        {UsbProxy.DaemonKeeper, id: :usbipd, command: "/usr/sbin/usbipd", args: []},
        # Enumerates, names, and binds USB devices; reconciles on
        # boot, hotplug, and a periodic timer.
        UsbProxy.DeviceRegistry
        # Phase 6: UsbProxy.SerialConsoles
      ]
    end
  end
end
