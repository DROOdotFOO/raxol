defmodule Raxol.Terminal.InlineDriverCursorProbeTest do
  @moduledoc """
  The DSR cursor probe (`Raxol.Terminal.InlineDriver.probe_cursor/2`) —
  the GUEST-BOOT substrate — plus its pure scanner
  (`Raxol.Terminal.InlineDriver.CursorReport`).

  Byte contracts under test (the unit's red-first falsifiers):

    * the probe request (`CSI 6n`) is emitted exactly once per call, and
      NEVER on the `tty?: false` fast path (zero bytes to a device that
      cannot answer);
    * the CPR reply is CONSUMED — it never reaches the subscriber as an
      event, in particular never as the phantom modified-F3 keypress
      `InputParser` would decode a row-1 reply into;
    * keystrokes interleaved with / split around the reply reach the
      subscriber in arrival order (leak-free);
    * on timeout, every byte read while waiting has been forwarded;
    * the scanner survives the hostile alphabet (invalid UTF-8, 8-bit
      C1, bare ESC, unbounded digits) and bounds its held-back tail.
  """

  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Capabilities
  alias Raxol.Terminal.InlineDriver
  alias Raxol.Terminal.InlineDriver.CursorReport

  setup do
    Capabilities.reset_cache()
    on_exit(fn -> Capabilities.reset_cache() end)
    {:ok, sio} = StringIO.open("")
    %{sio: sio}
  end

  defp contents(sio) do
    {_input, output} = StringIO.contents(sio)
    output
  end

  # tty?: true forces the byte-emission path while stty_enabled?: false /
  # install_reader?: false keep the real OS tty untouched -- the exact
  # test seam InlineDriver's moduledoc documents.
  defp start_driver!(sio, opts \\ []) do
    {:ok, pid} =
      InlineDriver.start_link(
        Keyword.merge(
          [
            device: sio,
            subscriber: self(),
            tty?: true,
            stty_enabled?: false,
            install_reader?: false,
            probe?: false
          ],
          opts
        )
      )

    pid
  end

  defp inject(pid, bytes) do
    send(pid, {:trace, self(), :send, {make_ref(), {:data, bytes}}, self()})
  end

  defp count_requests(sio) do
    sio |> contents() |> :binary.matches("\e[6n") |> length()
  end

  # A reply injected BEFORE the probe request would be consumed by the
  # driver's ordinary input path (mailbox order), which is exactly what
  # a real terminal can never do -- it only replies AFTER reading `CSI
  # 6n`. Mirror that: run the call from a task, wait for the request
  # bytes to hit the device (the observable "probe is in flight" fact),
  # THEN inject.
  defp probe_async(sio, pid, bytes_to_inject, opts \\ []) do
    task = Task.async(fn -> InlineDriver.probe_cursor(pid, opts) end)
    await_request(sio)
    Enum.each(List.wrap(bytes_to_inject), &inject(pid, &1))
    Task.await(task, 10_000)
  end

  defp await_request(sio, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    cond do
      count_requests(sio) >= 1 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("CSI 6n never reached the device")

      true ->
        Process.sleep(5)
        await_request(sio, deadline)
    end
  end

  describe "probe_cursor/2 -- the reply path" do
    test "consumes the CPR and returns the position; exactly one CSI 6n emitted",
         %{sio: sio} do
      pid = start_driver!(sio)

      assert {:ok, {17, 42}} = probe_async(sio, pid, "\e[17;42R")
      assert count_requests(sio) == 1

      # The CPR never reaches the subscriber -- not as any event at all.
      refute_received {:inline_input, _event}
      GenServer.stop(pid)
    end

    test "a row-1 reply is NOT delivered as the phantom modified-F3 keypress",
         %{sio: sio} do
      pid = start_driver!(sio)

      # `\e[1;5R` is byte-identical to ctrl-F3 on the wire -- the classic
      # DSR/F3 collision. InputParser would decode it as a key event;
      # the probe must consume it first.
      assert {:ok, {1, 5}} = probe_async(sio, pid, "\e[1;5R")
      refute_received {:inline_input, %Event{type: :key}}
      GenServer.stop(pid)
    end

    test "a reply split across chunks is still found", %{sio: sio} do
      pid = start_driver!(sio)

      assert {:ok, {23, 1}} = probe_async(sio, pid, ["\e[2", "3;", "1R"])
      refute_received {:inline_input, _event}
      GenServer.stop(pid)
    end

    test "keystrokes interleaved with the reply reach the subscriber in order, CPR-free",
         %{sio: sio} do
      pid = start_driver!(sio)

      assert {:ok, {3, 7}} = probe_async(sio, pid, "ab\e[3;7Rc")

      assert_receive {:inline_input, %Event{type: :key, data: %{char: "a"}}}
      assert_receive {:inline_input, %Event{type: :key, data: %{char: "b"}}}
      assert_receive {:inline_input, %Event{type: :key, data: %{char: "c"}}}
      refute_received {:inline_input, _stray}
      GenServer.stop(pid)
    end

    test "raw_sink sees every chunk exactly once, CPR bytes included", %{
      sio: sio
    } do
      pid = start_driver!(sio, raw_sink: self())

      chunk = "x\e[9;9Ry"
      assert {:ok, {9, 9}} = probe_async(sio, pid, chunk)

      # The byte-level tap's contract is "exactly as it arrived" -- the
      # CPR is only removed from the PARSED path.
      assert_receive {:inline_raw_input, ^chunk}
      refute_received {:inline_raw_input, _again}
      GenServer.stop(pid)
    end
  end

  describe "probe_cursor/2 -- fallback paths" do
    test "tty?: false replies :no_tty and writes ZERO bytes", %{sio: sio} do
      pid = start_driver!(sio, tty?: false)
      before_bytes = contents(sio)

      assert {:error, :no_tty} = InlineDriver.probe_cursor(pid)
      assert contents(sio) == before_bytes
      GenServer.stop(pid)
    end

    test "a silent device times out; bytes read while waiting are forwarded",
         %{sio: sio} do
      pid = start_driver!(sio)

      assert {:error, :timeout} =
               probe_async(sio, pid, "zz", budget_ms: 120)

      assert count_requests(sio) == 1
      assert_receive {:inline_input, %Event{type: :key, data: %{char: "z"}}}
      assert_receive {:inline_input, %Event{type: :key, data: %{char: "z"}}}
      GenServer.stop(pid)
    end

    test "a held-back partial-CPR tail is forwarded once the deadline lapses",
         %{sio: sio} do
      pid = start_driver!(sio)

      # Looks like the start of a CPR forever -- must not be dropped.
      assert {:error, :timeout} =
               probe_async(sio, pid, "\e[12;3", budget_ms: 120)

      # The tail flows down the ordinary parse path after the probe.
      # `\e[12;3` alone parses to nothing meaningful -- what matters is
      # the driver is alive and a subsequent real key still works.
      inject(pid, "k")
      assert_receive {:inline_input, %Event{type: :key, data: %{char: "k"}}}
      GenServer.stop(pid)
    end
  end

  describe "CursorReport.scan/1 -- the pure scanner" do
    test "finds a lone CPR" do
      assert {:reply, {5, 10}, "", ""} = CursorReport.scan("\e[5;10R")
    end

    test "preserves leading and trailing bytes in order" do
      assert {:reply, {2, 3}, "ab", "cd"} = CursorReport.scan("ab\e[2;3Rcd")
    end

    test "rejects the impossible 0-position and forwards it as input" do
      assert {:pending, "\e[0;0R", ""} = CursorReport.scan("\e[0;0R")

      # ...and still finds a real reply past it.
      assert {:reply, {4, 4}, "\e[0;7R", ""} =
               CursorReport.scan("\e[0;7R\e[4;4R")
    end

    test "keeps a plausible partial tail, bounded to 12 bytes" do
      assert {:pending, "abc", "\e[12;3"} = CursorReport.scan("abc\e[12;3")
      assert {:pending, "x", "\e"} = CursorReport.scan("x\e")
      assert {:pending, "x", "\e["} = CursorReport.scan("x\e[")

      # Digits past any valid CPR width stop looking like a prefix: the
      # ESC sits outside the 12-byte window, so everything flushes.
      long = "\e[123456789012345"
      assert {:pending, ^long, ""} = CursorReport.scan(long)
    end

    test "a non-CPR escape is flushed, never held" do
      # Arrow key: final byte present, just not a CPR.
      assert {:pending, "\e[A", ""} = CursorReport.scan("\e[A")
      # Second parameter separator -- no CPR has two semicolons.
      assert {:pending, "q\e[1;2;", ""} = CursorReport.scan("q\e[1;2;")
    end

    test "survives the hostile alphabet without crashing" do
      hostile = <<0xFF, 0xFE, "\e[", 0x9B, "girl\r\n", 0x00, "\e[7;1R", 0x90>>
      assert {:reply, {7, 1}, leading, trailing} = CursorReport.scan(hostile)
      assert leading == <<0xFF, 0xFE, "\e[", 0x9B, "girl\r\n", 0x00>>
      assert trailing == <<0x90>>

      # Invalid UTF-8 with no reply: everything forwards, nothing raises.
      assert {:pending, <<0xC3, 0x28, 0xA0, 0xA1>>, ""} =
               CursorReport.scan(<<0xC3, 0x28, 0xA0, 0xA1>>)
    end

    test "scan is stable across arbitrary chunkings of the same stream" do
      stream = "ty\e[24;80Rped"

      for split <- 1..(byte_size(stream) - 1) do
        head = binary_part(stream, 0, split)
        tail = binary_part(stream, split, byte_size(stream) - split)

        {forwarded, buffer} =
          case CursorReport.scan(head) do
            {:reply, pos, lead, trail} ->
              # Reply complete in the head alone (split past the R).
              assert pos == {24, 80}
              {lead <> trail <> tail, :done}

            {:pending, fwd, keep} ->
              {fwd, keep <> tail}
          end

        case buffer do
          :done ->
            assert forwarded == "ty" <> "ped"

          buffer ->
            assert {:reply, {24, 80}, lead2, trail2} =
                     CursorReport.scan(buffer)

            assert forwarded <> lead2 <> trail2 == "typed"
        end
      end
    end
  end
end
