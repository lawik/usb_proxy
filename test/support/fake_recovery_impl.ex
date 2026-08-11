defmodule UsbProxy.FakeRecoveryImpl do
  @moduledoc """
  Recovery impl that reports calls to the test process registered under
  `:recovery_test_listener` instead of touching hardware.
  """

  @behaviour UsbProxy.Recovery.Impl

  @impl true
  def vbus_cycle(hubs) do
    notify({:vbus_cycle, hubs})
    :ok
  end

  @impl true
  def reboot() do
    notify(:reboot)
    :ok
  end

  defp notify(message) do
    case Process.whereis(:recovery_test_listener) do
      nil -> :ok
      pid -> send(pid, message)
    end
  end
end
