defmodule UsbProxy.Api.TftpFile do
  @moduledoc """
  A file in the usbproxy's TFTP directory.

  The transfers themselves happen over TFTP (UDP 69) — this resource is
  the discovery and housekeeping surface for them, so agents can see
  what is there and clean up after themselves without a second control
  channel.
  """

  use Ash.Resource,
    domain: UsbProxy.Api,
    data_layer: Ash.DataLayer.Simple,
    extensions: [AshJsonApi.Resource]

  json_api do
    type("tftp_file")

    primary_key do
      keys([:name])
      delimiter("|")
    end

    routes do
      base("/tftp_files")
      index(:read)
      get(:read, path_param_is_composite_key: :id)
    end
  end

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List the files currently in the usbproxy's TFTP directory, newest first.")
    end

    action :delete, :map do
      description("""
      Delete one file from the TFTP directory by name. The namespace is
      flat and shared: this deletes the file for every client, including
      any board about to boot it. Uploads in flight are unaffected —
      they only become visible once complete.
      """)

      argument(:name, :string, allow_nil?: false)

      run(fn input, _context ->
        case UsbProxy.Tftp.delete(input.arguments.name) do
          :ok ->
            {:ok, %{name: input.arguments.name, deleted: true}}

          {:error, message} ->
            {:error, Ash.Error.Action.InvalidArgument.exception(field: :name, message: message)}
        end
      end)
    end
  end

  preparations do
    prepare(UsbProxy.Api.TftpFile.SetData)
  end

  attributes do
    attribute :name, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)

      description("""
      Filename, and the whole path a client needs: the namespace is
      flat, so a bootloader asking for `boot/zImage` gets `zImage`.
      """)
    end

    attribute :size, :integer do
      public?(true)
      description("Size in bytes. Only complete files are listed.")
    end

    attribute :modified_at, :utc_datetime do
      public?(true)
      description("When the file last finished being written.")
    end
  end

  @doc false
  def records() do
    if Process.whereis(UsbProxy.Tftp) do
      Enum.map(UsbProxy.Tftp.list(), &struct!(__MODULE__, &1))
    else
      []
    end
  end
end

defmodule UsbProxy.Api.TftpFile.SetData do
  @moduledoc false
  use Ash.Resource.Preparation

  def prepare(query, _opts, _context) do
    Ash.Query.before_action(query, fn query ->
      Ash.DataLayer.Simple.set_data(query, UsbProxy.Api.TftpFile.records())
    end)
  end
end
