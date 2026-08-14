defmodule UsbProxy.Tftp.Store do
  @moduledoc """
  The TFTP server callback: one flat directory on the data partition.

  Server-side only. What it adds over OTP's `tftp_file`:

    * flat namespace — directory components are stripped, so a board's
      `pxelinux.cfg/default` and an agent's `default` are one file;
    * atomic writes — an upload lands in a dot-prefixed temp file and
      is renamed into place on the last block, so a board never reads a
      half-written image;
    * per-transfer and whole-directory byte caps, refused with `enospc`;
    * an event-log entry per transfer with the peer address, the only
      audit trail a protocol with no authentication can offer.

  `octet` mode only: netascii's CRLF translation would corrupt images.
  """

  @behaviour :tftp

  @enforce_keys [:access, :peer, :name, :path, :blksize, :limit, :options]
  defstruct [
    :access,
    :peer,
    :name,
    :path,
    :temp_path,
    :fd,
    :blksize,
    :limit,
    :options,
    count: 0
  ]

  # Never reduce a client's blksize: OTP's client ignores the reduction
  # in an OACK on upload and stalls until it times out. The engine
  # refuses anything above 65464 before we see it.
  @max_blksize 65_464
  @default_blksize 512

  # 16-bit block numbers, and the engine has no rollover clause — past
  # block 65535 a transfer dies with a function_clause partway through
  # rather than an error the client can report. Refuse it up front.
  @max_blocks 65_535

  ## tftp callbacks

  @impl true
  def prepare(_peer, _access, _filename, _mode, _options, _initial) do
    # Client-side hook; usbproxy is only ever the server.
    {:error, {:badop, "usbproxy's TFTP callback is server-side only"}}
  end

  @impl true
  def open(peer, access, filename, mode, options, %{root: _} = initial) do
    with :ok <- check_mode(mode),
         {:ok, name} <- safe_name(filename),
         {:ok, state} <- build(peer, access, name, options, initial) do
      do_open(state)
    end
  end

  # The engine may re-enter open/6 with an already-built state once the
  # options are settled; the file is already open by then.
  def open(_peer, _access, _filename, _mode, _options, %__MODULE__{} = state) do
    {:ok, state.options, state}
  end

  @impl true
  def read(%__MODULE__{access: :read} = state) do
    blksize = state.blksize

    case :file.read(state.fd, blksize) do
      {:ok, bin} when byte_size(bin) == blksize ->
        {:more, bin, %{state | count: state.count + blksize}}

      {:ok, bin} ->
        count = state.count + byte_size(bin)
        :file.close(state.fd)
        log(state, "tftp_read", count)
        {:last, bin, count}

      :eof ->
        :file.close(state.fd)
        log(state, "tftp_read", state.count)
        {:last, <<>>, state.count}

      {:error, reason} ->
        :file.close(state.fd)
        {:error, file_error(reason)}
    end
  end

  @impl true
  def write(bin, %__MODULE__{access: :write} = state) do
    blksize = state.blksize
    count = state.count + byte_size(bin)

    cond do
      count > state.limit ->
        discard(state)

        {:error,
         {:enospc,
          "#{state.name} exceeds the #{state.limit} byte limit for this transfer " <>
            "(per-file cap, or the space left under the directory cap)"}}

      true ->
        case :file.write(state.fd, bin) do
          :ok when byte_size(bin) == blksize ->
            {:more, %{state | count: count}}

          :ok ->
            commit(state, count)

          {:error, reason} ->
            discard(state)
            {:error, file_error(reason)}
        end
    end
  end

  @impl true
  def abort(code, text, %__MODULE__{} = state) do
    discard(state)

    UsbProxy.EventLog.append(:tftp_aborted, %{
      name: state.name,
      access: state.access,
      peer: state.peer,
      bytes: state.count,
      reason: "#{code}: #{text}"
    })

    :ok
  end

  ## Open

  defp build(peer, access, name, options, initial) do
    path = Path.join(Map.fetch!(initial, :root), name)
    blksize = negotiated_blksize(options)

    with {:ok, space} <- space_limit(access, path, initial),
         limit = smaller(space, @max_blocks * blksize),
         :ok <- check_size(access, path, limit, blksize),
         {:ok, accepted} <- accept_options(options, access, path, limit) do
      {:ok,
       %__MODULE__{
         access: access,
         peer: format_peer(peer),
         name: name,
         path: path,
         blksize: blksize,
         limit: limit,
         options: accepted
       }}
    end
  end

  # Refuse an oversized read before a single block goes out.
  defp check_size(:read, path, limit, blksize) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > limit ->
        {:error,
         {:undef,
          "#{Path.basename(path)} is #{size} bytes; TFTP tops out at #{limit} with the " <>
            "negotiated #{blksize} byte blocks (16-bit block numbers). Ask for a larger " <>
            "blksize, or split the file."}}

      _ ->
        :ok
    end
  end

  defp check_size(:write, _path, _limit, _blksize), do: :ok

  defp do_open(%{access: :read} = state) do
    case :file.open(state.path, [:read, :read_ahead, :raw, :binary]) do
      {:ok, fd} -> {:ok, state.options, %{state | fd: fd}}
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp do_open(%{access: :write} = state) do
    # Dot-prefixed so `safe_name/1` can never name a temp file.
    temp = Path.join(Path.dirname(state.path), ".#{state.name}.part.#{unique()}")

    case :file.open(temp, [:write, :delayed_write, :raw, :binary]) do
      {:ok, fd} -> {:ok, state.options, %{state | fd: fd, temp_path: temp}}
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  ## Finishing a write

  defp commit(state, count) do
    with :ok <- :file.sync(state.fd),
         :ok <- :file.close(state.fd),
         :ok <- :file.rename(state.temp_path, state.path) do
      log(state, "tftp_write", count)
      {:last, count}
    else
      {:error, reason} ->
        _ = :file.delete(state.temp_path)
        {:error, file_error(reason)}
    end
  end

  defp discard(%{access: :write} = state) do
    _ = state.fd && :file.close(state.fd)
    _ = state.temp_path && :file.delete(state.temp_path)
    :ok
  end

  defp discard(state) do
    _ = state.fd && :file.close(state.fd)
    :ok
  end

  ## Names, modes, limits

  defp check_mode(~c"octet"), do: :ok
  defp check_mode("octet"), do: :ok

  defp check_mode(mode) do
    {:error,
     {:badop,
      "usbproxy serves TFTP in octet mode only (asked for #{mode}); " <>
        "netascii would corrupt binary images"}}
  end

  # `boot/zImage`, `/zImage` and `zImage` are the same file.
  defp safe_name(filename) do
    name = filename |> to_string() |> Path.basename()

    cond do
      name in ["", ".", ".."] ->
        {:error, {:badop, "empty filename"}}

      String.starts_with?(name, ".") ->
        {:error, {:eacces, "filenames starting with '.' are reserved for uploads in flight"}}

      true ->
        {:ok, name}
    end
  end

  # A write is bounded by the smaller of the per-file cap and the room
  # left under the directory cap. The scan counts temp files, so
  # concurrent uploads see each other approximately — this is a safety
  # valve, not a quota system.
  defp space_limit(:read, _path, _initial), do: {:ok, :infinity}

  defp space_limit(:write, path, initial) do
    max_file = Map.fetch!(initial, :max_file_bytes)
    max_total = Map.fetch!(initial, :max_total_bytes)
    root = Map.fetch!(initial, :root)

    # The file being replaced frees its own bytes on rename.
    replacing = with {:ok, %{size: size}} <- File.stat(path), do: size, else: (_ -> 0)
    room = max_total - used_bytes(root) + replacing

    case min(max_file, room) do
      limit when limit > 0 ->
        {:ok, limit}

      _ ->
        {:error,
         {:enospc, "the TFTP directory is at its #{max_total} byte cap; delete something first"}}
    end
  end

  defp used_bytes(root) do
    root
    |> File.ls!()
    |> Enum.reduce(0, fn entry, acc ->
      case File.stat(Path.join(root, entry)) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _ -> acc
      end
    end)
  end

  ## Option negotiation (RFC 2347-2349)
  #
  # Options may be dropped or answered with a different value, never
  # added. Keys and values stay charlists: the engine looks them up
  # with lists:keysearch/3 and a binary would silently miss.

  defp accept_options(options, access, path, limit) do
    Enum.reduce_while(options, {:ok, []}, fn option, {:ok, acc} ->
      case accept_option(option, access, path, limit) do
        {:ok, accepted} -> {:cont, {:ok, acc ++ accepted}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp accept_option({~c"blksize", value}, _access, _path, _limit) do
    case to_integer(value) do
      {:ok, requested} when requested > 0 ->
        {:ok, [{~c"blksize", ~c"#{min(requested, @max_blksize)}"}]}

      _ ->
        {:error, {:badopt, "bad blksize"}}
    end
  end

  # RFC 2349: on a read the client sends 0 and we answer with the real
  # size; on a write it declares the size and we echo it back.
  defp accept_option({~c"tsize", _value}, :read, path, _limit) do
    case File.stat(path) do
      {:ok, %{size: size}} -> {:ok, [{~c"tsize", ~c"#{size}"}]}
      {:error, reason} -> {:error, file_error(reason)}
    end
  end

  defp accept_option({~c"tsize", value}, :write, _path, limit) do
    case to_integer(value) do
      {:ok, size} when size <= limit -> {:ok, [{~c"tsize", value}]}
      {:ok, size} -> {:error, {:enospc, "#{size} bytes exceeds the #{limit} byte limit"}}
      :error -> {:error, {:badopt, "bad tsize"}}
    end
  end

  defp accept_option({~c"timeout", value}, _access, _path, _limit) do
    {:ok, [{~c"timeout", value}]}
  end

  # Anything else is dropped rather than refused: an unknown option is
  # not a reason to fail a boot.
  defp accept_option(_option, _access, _path, _limit), do: {:ok, []}

  # Needed before the options are assembled: the per-transfer byte
  # ceiling depends on it.
  defp negotiated_blksize(options) do
    with {_, value} <- List.keyfind(options, ~c"blksize", 0),
         {:ok, requested} when requested > 0 <- to_integer(value) do
      min(requested, @max_blksize)
    else
      _ -> @default_blksize
    end
  end

  defp smaller(:infinity, b), do: b
  defp smaller(a, b), do: min(a, b)

  defp to_integer(value) do
    {:ok, value |> to_string() |> String.to_integer()}
  rescue
    ArgumentError -> :error
  end

  ## Bits and pieces

  defp log(state, event, bytes) do
    UsbProxy.EventLog.append(event, %{name: state.name, peer: state.peer, bytes: bytes})
  end

  # The callback docs promise an ip_address(), but the engine runs it
  # through tftp_lib:host_to_string/1 first. Handle both.
  defp format_peer({_type, host, port}) when is_list(host), do: "#{host}:#{port}"
  defp format_peer({_type, host, port}) when is_tuple(host), do: "#{:inet.ntoa(host)}:#{port}"
  defp format_peer(other), do: inspect(other)

  defp unique(), do: System.unique_integer([:positive])

  defp file_error(reason) when is_atom(reason) do
    text = reason |> :file.format_error() |> to_string()

    case reason do
      r when r in [:eexist, :enoent, :eacces, :enospc] -> {r, text}
      :eperm -> {:eacces, text}
      other -> {:undef, "#{text} (#{other})"}
    end
  end
end
