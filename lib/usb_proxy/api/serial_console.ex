defmodule UsbProxy.Api.SerialConsole do
  @moduledoc """
  A serial console exported as a raw TCP port.

  Read-only. The backing service arrives in Phase 6; until then the
  list is empty.
  """

  use Ash.Resource,
    domain: UsbProxy.Api,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("serial_console")

    primary_key do
      keys([:name])
      delimiter("|")
    end

    routes do
      base("/serial_consoles")
      index(:read)
      get(:read, path_param_is_composite_key: :id)
    end
  end

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List every serial console this usbproxy exports.")
    end
  end

  preparations do
    prepare(UsbProxy.Api.SerialConsole.SetData)
  end

  attributes do
    attribute :name, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
      description("Stable name of the serial adapter this console belongs to.")
    end

    attribute :tcp_port, :integer do
      public?(true)

      description("""
      TCP port on the usbproxy serving this console. Connect with plain
      TCP (e.g. `nc <usbproxy> <port>`) — raw byte pipe, no protocol.
      """)
    end

    attribute :status, :atom do
      public?(true)
      constraints(one_of: [:up, :adapter_missing])
      description("Console state: :up (adapter present, port serving) or :adapter_missing.")
    end

    attribute :client_count, :integer do
      public?(true)
      description("Number of currently connected TCP clients.")
    end
  end

  @doc false
  def records() do
    if Process.whereis(UsbProxy.SerialConsoles.Manager) do
      Enum.map(UsbProxy.SerialConsoles.list(), &struct!(__MODULE__, &1))
    else
      []
    end
  end
end

defmodule UsbProxy.Api.SerialConsole.SetData do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      Ash.DataLayer.Simple.set_data(query, UsbProxy.Api.SerialConsole.records())
    end)
  end
end
