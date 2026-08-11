defmodule UsbProxy.Api.FlashJob do
  @moduledoc """
  A firmware flash of a device, performed locally on the usbproxy
  (dramatically faster than flashing over USB/IP).

  Placeholder: the flash service arrives in Phase 8. The resource
  exists now so the API shape is stable; `create` errors with
  not_implemented.
  """

  use Ash.Resource,
    domain: UsbProxy.Api,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("flash_job")

    routes do
      base("/flash_jobs")
      index(:read)
      get(:read)
      post(:create)
    end
  end

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List flash jobs and their status.")
    end

    create :create do
      description("""
      Flash a device with a previously uploaded image. Upload the image
      via HTTP first (POST /api/images, arrives in Phase 8), then pass
      the returned image ref here together with the device's stable name.
      """)

      accept([:device_name, :image_ref])
      change(UsbProxy.Api.NotImplemented)
    end
  end

  preparations do
    prepare(UsbProxy.Api.FlashJob.SetData)
  end

  attributes do
    uuid_primary_key(:id, writable?: false)

    attribute :device_name, :string do
      public?(true)
      allow_nil?(false)
      description("Stable name of the device to flash.")
    end

    attribute :image_ref, :string do
      public?(true)
      allow_nil?(false)
      description("Reference to an uploaded image (from the HTTP upload endpoint).")
    end

    attribute :status, :atom do
      public?(true)
      constraints(one_of: [:queued, :running, :succeeded, :failed])
      description("Job state.")
    end

    attribute :output_tail, :string do
      public?(true)
      description("Tail of the flashing tool's output, for progress/diagnostics.")
    end
  end

  @doc false
  def records(), do: []
end

defmodule UsbProxy.Api.FlashJob.SetData do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      Ash.DataLayer.Simple.set_data(query, UsbProxy.Api.FlashJob.records())
    end)
  end
end
