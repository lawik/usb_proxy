defmodule UsbProxy.Api.RecoveryAction do
  @moduledoc """
  A recovery step on the usbproxy: VBUS power-cycle of the USB hubs, or
  a reboot of the whole box. Backed by `UsbProxy.Recovery` (rate
  limiting, audit logging, hardware effects).
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
      description("List recovery actions performed since the last boot, newest first.")
    end

    create :create do
      description("""
      Run a recovery step. Escalation ladder: :vbus power-cycles ALL USB
      ports on the usbproxy's power-switchable hubs (all-or-nothing —
      every device drops, re-enumerates, and is re-bound automatically;
      consoles resume; devices behind non-switchable hubs only
      re-enumerate). :reboot reboots the whole usbproxy: expect roughly
      half a minute of downtime, then everything returns unattended —
      poll /up. Both levels are rate-limited; a rate-limited or failed
      request errors with an explanation and a retry time. Requester
      address is recorded in the audit log.
      """)

      accept([:level])
      change(UsbProxy.Api.RecoveryAction.Execute)
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
      constraints(one_of: [:done, :scheduled, :failed])

      description("""
      :done — completed. :scheduled — a reboot is about to happen (the
      response beats the reboot out the door). :failed — the hardware
      action errored; see the error detail.
      """)
    end

    attribute :requested_by, :string do
      public?(true)
      description("Requester identity (source tailnet address).")
    end
  end

  @doc false
  def records() do
    if Process.whereis(UsbProxy.Recovery) do
      Enum.map(UsbProxy.Recovery.history(), fn entry ->
        struct!(__MODULE__, Map.take(entry, [:id, :level, :status, :requested_by]))
      end)
    else
      []
    end
  end
end

defmodule UsbProxy.Api.RecoveryAction.Execute do
  @moduledoc false
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      level = Ash.Changeset.get_attribute(changeset, :level)
      requester = UsbProxy.RequesterIP.get()

      case UsbProxy.Recovery.request(level, requester) do
        {:ok, entry} ->
          changeset
          |> Ash.Changeset.force_change_attribute(:id, entry.id)
          |> Ash.Changeset.force_change_attribute(:status, entry.status)
          |> Ash.Changeset.force_change_attribute(:requested_by, entry.requested_by)

        {:error, message} ->
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Action.InvalidArgument.exception(field: :level, message: message)
          )
      end
    end)
  end
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
