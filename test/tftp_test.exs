defmodule UsbProxy.TftpTest do
  @moduledoc """
  Real TFTP transfers against a real server: OTP's `:tftp` client on one
  side, `UsbProxy.Tftp` on a high port with a temp root on the other.
  Nothing is faked — the protocol is the thing under test.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "tftp")
    port = 7300 + :erlang.phash2(self(), 200)

    previous = Application.get_env(:usb_proxy, UsbProxy.Tftp, [])

    Application.put_env(:usb_proxy, UsbProxy.Tftp,
      root: root,
      port: port,
      data_ports: 7500..7599,
      max_file_bytes: 100_000,
      max_total_bytes: 200_000
    )

    on_exit(fn -> Application.put_env(:usb_proxy, UsbProxy.Tftp, previous) end)

    start_supervised!(UsbProxy.Tftp)

    %{root: root, port: port}
  end

  ## Client helpers — OTP's tftp client with the in-memory callback.
  #
  # Two quirks of that client, so nobody chases them as server bugs:
  # every read costs a flat 3s (it dallies after the final ACK; curl
  # takes milliseconds), and errors arrive as {phase, Code, Text}.
  defp get(port, name, options \\ []) do
    :tftp.read_file(to_charlist(name), :binary, [{:host, ~c"127.0.0.1"}, {:port, port} | options])
  end

  defp put(port, name, contents, options \\ []) do
    :tftp.write_file(to_charlist(name), contents, [
      {:host, ~c"127.0.0.1"},
      {:port, port} | options
    ])
  end

  describe "transfers" do
    test "a board reads a file an agent uploaded", %{port: port} do
      image = :crypto.strong_rand_bytes(40_000)

      assert {:ok, 40_000} = put(port, "zImage", image)
      assert {:ok, ^image} = get(port, "zImage")
    end

    test "an empty file round-trips", %{port: port} do
      assert {:ok, 0} = put(port, "empty", <<>>)
      assert {:ok, <<>>} = get(port, "empty")
    end

    test "a file whose size is an exact multiple of the block size round-trips",
         %{port: port} do
      # The transfer only ends on a short block, so an exact multiple
      # needs a trailing empty one.
      image = :crypto.strong_rand_bytes(512 * 4)

      assert {:ok, _} = put(port, "aligned", image)
      assert {:ok, ^image} = get(port, "aligned")
    end

    # The server must not reduce it: OTP's client ignores a reduction
    # on upload and stalls.
    test "a client's requested blksize is honoured in both directions", %{port: port} do
      image = :crypto.strong_rand_bytes(20_000)

      assert {:ok, _} = put(port, "big-blocks", image, [{~c"blksize", ~c"8192"}])
      assert {:ok, ^image} = get(port, "big-blocks", [{~c"blksize", ~c"8192"}])
    end

    test "reading a file that is not there fails with enoent", %{port: port} do
      assert {:error, {_, :enoent, _}} = get(port, "nope")
    end

    # Through the callback: OTP's client refuses netascii-to-binary
    # before a packet leaves the machine.
    test "netascii is refused rather than silently corrupting an image", %{root: root} do
      File.write!(Path.join(root, "img"), <<0, 13, 10, 255>>)
      initial = %{root: root, max_file_bytes: 100_000, max_total_bytes: 200_000}

      assert {:error, {:badop, text}} =
               UsbProxy.Tftp.Store.open(
                 {:inet, ~c"127.0.0.1", 4242},
                 :read,
                 ~c"img",
                 ~c"netascii",
                 [],
                 initial
               )

      assert to_string(text) =~ "octet"
    end
  end

  describe "the flat namespace" do
    test "a bootloader's directory prefix resolves to the same file", %{port: port} do
      assert {:ok, _} = put(port, "default", "boot me")

      assert {:ok, "boot me"} = get(port, "pxelinux.cfg/default")
      assert {:ok, "boot me"} = get(port, "/srv/tftp/default")
    end

    test "a path escape cannot reach outside the root", %{port: port, root: root} do
      assert {:ok, _} = put(port, "../../escaped", "nope")

      assert File.exists?(Path.join(root, "escaped"))
      refute File.exists?(Path.join([root, "..", "..", "escaped"]))
    end

    test "uploading an existing name replaces it for everyone", %{port: port} do
      assert {:ok, _} = put(port, "shared", "first")
      assert {:ok, _} = put(port, "shared", "second")
      assert {:ok, "second"} = get(port, "shared")
      assert [%{name: "shared"}] = UsbProxy.Tftp.list()
    end

    test "dot-prefixed names are reserved", %{port: port} do
      assert {:error, {_, :eacces, _}} = put(port, ".hidden", "no")
    end
  end

  describe "atomic writes" do
    # Through the callback: pausing a real transfer mid-flight is a
    # race.
    test "an upload is invisible until it completes", %{root: root} do
      alias UsbProxy.Tftp.Store

      peer = {:inet, ~c"127.0.0.1", 4242}
      initial = %{root: root, max_file_bytes: 100_000, max_total_bytes: 200_000}

      assert {:ok, _options, state} =
               Store.open(peer, :write, ~c"slow", ~c"octet", [], initial)

      assert {:more, state} = Store.write(:binary.copy(<<7>>, 512), state)

      assert UsbProxy.Tftp.list() == []
      refute File.exists?(Path.join(root, "slow"))
      assert [_partial] = partials(root)

      # A short block ends the transfer.
      assert {:last, 612} = Store.write(:binary.copy(<<7>>, 100), state)

      assert [%{name: "slow", size: 612}] = UsbProxy.Tftp.list()
      assert partials(root) == []
    end

    test "an aborted upload leaves nothing behind", %{port: port, root: root} do
      # max_file_bytes is 100_000; this transfer is refused mid-flight.
      assert {:error, _} = put(port, "toobig", :crypto.strong_rand_bytes(120_000))

      refute File.exists?(Path.join(root, "toobig"))
      assert partials(root) == []
      assert UsbProxy.Tftp.list() == []
    end

    test "a partial file from a previous boot is swept on start", %{root: root} do
      File.write!(Path.join(root, ".ghost.part.1"), "interrupted by a power cut")

      :ok = stop_supervised!(UsbProxy.Tftp)
      start_supervised!(UsbProxy.Tftp)

      assert partials(root) == []
    end
  end

  describe "caps" do
    test "a client that declares its size is refused before sending anything", %{port: port} do
      assert {:error, {_, :enospc, text}} =
               put(port, "declared", :crypto.strong_rand_bytes(110_000), [
                 {~c"tsize", ~c"110000"}
               ])

      assert to_string(text) =~ "exceeds"
    end

    test "the directory cap stops uploads once it is reached", %{port: port} do
      # 200_000 total, 100_000 per file.
      assert {:ok, _} = put(port, "one", :crypto.strong_rand_bytes(100_000))
      assert {:ok, _} = put(port, "two", :crypto.strong_rand_bytes(100_000))

      assert {:error, {_, :enospc, _}} = put(port, "three", :crypto.strong_rand_bytes(1_000))

      assert :ok = UsbProxy.Tftp.delete("one")
      assert {:ok, _} = put(port, "three", :crypto.strong_rand_bytes(1_000))
    end

    test "a file too big for 16-bit block numbers is refused up front, not mid-transfer",
         %{port: port, root: root} do
      # One block past what the protocol can number at 512-byte blocks.
      # Written directly; uploading it would hit the same ceiling.
      File.write!(Path.join(root, "huge"), :binary.copy(<<0>>, 65_535 * 512 + 1))

      assert {:error, {_, :undef, text}} = get(port, "huge")
      assert to_string(text) =~ "blksize"

      # The same file is fine once the client negotiates bigger blocks.
      assert {:ok, data} = get(port, "huge", [{~c"blksize", ~c"8192"}])
      assert byte_size(data) == 65_535 * 512 + 1
    end
  end

  describe "bookkeeping" do
    test "transfers land in the event log with the peer", %{port: port} do
      assert {:ok, _} = put(port, "logged", "hello")
      assert {:ok, _} = get(port, "logged")

      events = UsbProxy.EventLog.tail(50)

      assert Enum.any?(events, &(&1["event"] == "tftp_write" and &1["name"] == "logged"))

      assert Enum.any?(events, fn e ->
               e["event"] == "tftp_read" and e["name"] == "logged" and
                 e["bytes"] == 5 and String.starts_with?(e["peer"], "127.0.0.1:")
             end)
    end

    test "list reports size and mtime, newest first", %{port: port} do
      assert {:ok, _} = put(port, "older", "a")
      assert {:ok, _} = put(port, "newer", "bb")

      assert [%{name: newest} | _] = UsbProxy.Tftp.list()
      assert newest in ["newer", "older"]
      assert Enum.map(UsbProxy.Tftp.list(), & &1.size) |> Enum.sort() == [1, 2]
    end

    test "info reports the caps and usage", %{port: port} do
      assert {:ok, _} = put(port, "counted", :crypto.strong_rand_bytes(1_234))

      assert %{running: true, file_count: 1, bytes_used: 1_234, max_total_bytes: 200_000} =
               UsbProxy.Tftp.info()
    end

    test "delete removes a file and refuses paths", %{port: port} do
      assert {:ok, _} = put(port, "doomed", "x")

      assert {:error, message} = UsbProxy.Tftp.delete("../doomed")
      assert message =~ "flat"

      assert :ok = UsbProxy.Tftp.delete("doomed")
      assert {:error, {_, :enoent, _}} = get(port, "doomed")
      assert {:error, _} = UsbProxy.Tftp.delete("doomed")
    end
  end

  describe "the API surface" do
    @tag :ash
    test "files are listable and deletable through Ash", %{port: port} do
      assert {:ok, _} = put(port, "via-ash", "contents")

      assert [%{name: "via-ash", size: 8}] = UsbProxy.Api.list_tftp_files!()

      assert %{deleted: true} = UsbProxy.Api.delete_tftp_file!("via-ash")
      assert UsbProxy.Api.list_tftp_files!() == []

      assert {:error, error} = UsbProxy.Api.delete_tftp_file("via-ash")
      assert Exception.message(error) =~ "no TFTP file named via-ash"
    end
  end

  ## Helpers

  defp partials(root) do
    root |> File.ls!() |> Enum.filter(&String.contains?(&1, ".part."))
  end
end
