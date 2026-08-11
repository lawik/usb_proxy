defmodule UsbProxy.RequesterIP do
  @moduledoc """
  Captures the requester's source IP (their tailnet address) for audit
  logging. A plug stores the connection's remote IP in the process
  dictionary; Ash actions run synchronously in the same request process,
  so `get/0` reads it from anywhere down the call chain.
  """

  @behaviour Plug

  @key :usb_proxy_requester_ip

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Process.put(@key, conn.remote_ip |> :inet.ntoa() |> to_string())
    conn
  end

  @spec get() :: String.t()
  def get(), do: Process.get(@key) || "unknown"
end
