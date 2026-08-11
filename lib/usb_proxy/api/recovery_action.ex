defmodule UsbProxy.Api.RecoveryAction do
  @moduledoc """
  A recovery step on the usbproxy: VBUS power-cycle of the USB ports, or
  a reboot of the whole box.

  Placeholder: the recovery service arrives in Phase 9. The resource
  exists now so the API shape is stable; `create` errors with
  not_implemented.
  """

  use Ash.Resource,
    domain: UsbProxy.Api,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("recovery_action")

    routes do
      base("/recovery_actions")
      index(:read)
      post(:create)
    end
  end

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List past recovery actions.")
    end

    create :create do
      description("""
      Run a recovery step. Escalation ladder: :vbus power-cycles ALL USB
      ports on the usbproxy (all-or-nothing on this hardware) — attached
      devices drop and re-bind automatically. :reboot reboots the whole
      usbproxy; it returns to service unattended, typically within a
      minute. Both are rate-limited.
      """)

      accept([:level])
      change(UsbProxy.Api.NotImplemented)
    end
  end

  preparations do
    prepare(UsbProxy.Api.RecoveryAction.SetData)
  end

  attributes do
    uuid_primary_key(:id, writable?: false)

    attribute :level, :atom do
      public?(true)
      allow_nil?(false)
      constraints(one_of: [:vbus, :reboot])
      description("Recovery level: :vbus (USB power cycle) or :reboot (full usbproxy reboot).")
    end

    attribute :status, :atom do
      public?(true)
      constraints(one_of: [:done, :rejected, :rate_limited])
      description("Outcome of the action.")
    end

    attribute :requested_by, :string do
      public?(true)
      description("Requester identity (source tailnet address).")
    end
  end

  @doc false
  def records(), do: []
end

defmodule UsbProxy.Api.RecoveryAction.SetData do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      Ash.DataLayer.Simple.set_data(query, UsbProxy.Api.RecoveryAction.records())
    end)
  end
end
