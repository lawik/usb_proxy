defmodule UsbProxy.Api.SerialConsole do
  @moduledoc """
  A serial console exported as a raw TCP port.

  Reads snapshot the live SerialConsoles service; `set_speed` is the
  one write, reopening the adapter's UART at another baud rate.
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
      route(:post, "/:name/speed", :set_speed)
    end
  end

  @speeds [
    1200,
    2400,
    4800,
    9600,
    19_200,
    38_400,
    57_600,
    115_200,
    230_400,
    460_800,
    921_600,
    1_500_000,
    3_000_000
  ]

  actions do
    default_accept([])

    read :read do
      primary?(true)
      description("List every serial console this usbproxy exports.")
    end

    action :set_speed, :map do
      description("""
      Set a console's baud rate and reopen its UART at that speed —
      connected TCP clients stay connected, the target's bytes just
      start arriving at the new rate. Consoles default to 115200; use
      this when a target speaks something else (bootloaders at 57600,
      many SoCs at 921600). The setting sticks for the rest of this
      usbproxy's uptime, including across replugs, so put it back when
      you are done. Allowed speeds: #{Enum.join(@speeds, ", ")}.
      """)

      argument(:name, :string, allow_nil?: false)
      argument(:speed, :integer, allow_nil?: false)

      run(fn input, _context ->
        %{name: name, speed: speed} = input.arguments

        if speed in @speeds do
          case UsbProxy.SerialConsoles.set_speed(name, speed) do
            {:ok, status} ->
              {:ok, Map.put(status, :name, name)}

            {:error, :no_console} ->
              {:error,
               Ash.Error.Action.InvalidArgument.exception(
                 field: :name,
                 message: "no serial console named #{name}"
               )}
          end
        else
          {:error,
           Ash.Error.Action.InvalidArgument.exception(
             field: :speed,
             message: "unsupported speed; use one of #{Enum.join(@speeds, ", ")}"
           )}
        end
      end)
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
      constraints(one_of: [:up, :adapter_missing, :released])

      description("""
      Console state: :up (serving), :adapter_missing (device absent,
      port stays open and resumes on return), :released (device
      currently exposed as usbip; console idle until exposure flips back).
      """)
    end

    attribute :client_count, :integer do
      public?(true)
      description("Number of currently connected TCP clients.")
    end

    attribute :speed, :integer do
      public?(true)

      description("""
      Baud rate the UART is open at. 115200 unless changed with
      set_serial_console_speed.
      """)
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
