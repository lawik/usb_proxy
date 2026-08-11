defmodule UsbProxy.Tailscale do
  @moduledoc """
  Runs tailscaled (static binary from the rootfs overlay) under
  supervision and brings the node up on the tailnet.

  State lives in `state_dir` on the data partition, so the node identity
  survives reboots, power cuts, and firmware updates — the device keeps
  its name and IP instead of piling up duplicate nodes.

  First boot needs an auth key (reusable, tagged `tag:usbproxy`, minted
  with scripts/mint-usbproxy-key.sh) from either the Nerves KV store
  (key `tailscale_authkey`) or the configured `authkey_file`. Once
  joined, the state dir carries the identity and no key is needed.
  """

  use Supervisor
  require Logger

  @tailscaled "/usr/bin/tailscaled"
  @tailscale "/usr/bin/tailscale"

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.fetch_env!(:usb_proxy, __MODULE__)
    state_dir = Keyword.fetch!(config, :state_dir)
    File.mkdir_p!(state_dir)

    children = [
      {UsbProxy.DaemonKeeper,
       id: :tailscaled,
       command: @tailscaled,
       args: [
         # No netfilter flags: without iptables binaries tailscaled
         # falls back to nftables over netlink, which the kernel has.
         "--statedir=#{state_dir}",
         "--socket=#{socket_path()}"
       ]},
      {UsbProxy.Tailscale.Up, config}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def socket_path(), do: "/tmp/tailscaled.sock"
  def tailscaled_bin(), do: @tailscaled
  def tailscale_bin(), do: @tailscale

  @doc "Current backend state, e.g. \"Running\" or \"NeedsLogin\"."
  def status() do
    case cli(["status", "--json"]) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"BackendState" => state}} -> {:ok, state}
          other -> {:error, other}
        end

      error ->
        error
    end
  end

  @doc "Run the tailscale CLI against our tailscaled socket."
  def cli(args) do
    case System.cmd(@tailscale, ["--socket=#{socket_path()}" | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {code, out}}
    end
  end
end

defmodule UsbProxy.Tailscale.Up do
  @moduledoc """
  Reconciles tailnet membership after tailscaled starts: polls backend
  state and, when tailscaled reports NeedsLogin, runs `tailscale up`
  with the provisioned auth key. Retries forever — the box must join
  unattended whenever a key or the network shows up.
  """

  use GenServer
  require Logger

  alias UsbProxy.Tailscale

  @poll_ms 5_000

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    {:ok, %{config: config, up: false}, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: poll(state)

  @impl true
  def handle_info(:poll, state), do: poll(state)

  defp poll(state) do
    state =
      case Tailscale.status() do
        {:ok, "Running"} ->
          unless state.up do
            ip =
              case Tailscale.cli(["ip", "-4"]) do
                {:ok, out} -> String.trim(out)
                _ -> nil
              end

            Logger.info("tailnet up, ip: #{ip}")
            UsbProxy.EventLog.append(:tailnet_up, %{ip: ip})
          end

          %{state | up: true}

        {:ok, "NeedsLogin"} ->
          try_up(state.config)
          %{state | up: false}

        other ->
          Logger.debug("tailscale not ready: #{inspect(other)}")
          %{state | up: false}
      end

    Process.send_after(self(), :poll, @poll_ms)
    {:noreply, state}
  end

  defp try_up(config) do
    case authkey(config) do
      nil ->
        Logger.warning(
          "tailscale needs login but no auth key found " <>
            "(KV tailscale_authkey or #{config[:authkey_file]})"
        )

      key ->
        args = [
          "up",
          "--auth-key=#{key}",
          "--hostname=#{config[:hostname] || "usbproxy"}",
          # vintage_net owns resolv.conf; don't fight over it.
          "--accept-dns=false"
        ]

        case Tailscale.cli(args) do
          {:ok, _} ->
            Logger.info("tailscale up succeeded")
            UsbProxy.EventLog.append(:tailnet_join, %{})

          {:error, {code, out}} ->
            Logger.warning("tailscale up failed (#{code}): #{String.trim(out)}")
        end
    end
  end

  defp authkey(config) do
    from_kv = Nerves.Runtime.KV.get("tailscale_authkey")

    from_file =
      case config[:authkey_file] && File.read(config[:authkey_file]) do
        {:ok, contents} -> String.trim(contents)
        _ -> nil
      end

    case {from_kv, from_file} do
      {key, _} when is_binary(key) and key != "" -> key
      {_, key} when is_binary(key) and key != "" -> key
      _ -> nil
    end
  end
end
