defmodule Raxol.Harness.SurfaceSealPipelineTest do
  @moduledoc """
  The seal-pipeline hardening suite: three coupled correctness properties
  of the `Raxol.Harness.Surface` seal path, each mapped to a documented
  guarantee.

  1. **Two-phase seal (write -> confirm -> mark).** The seal walk marks a
     block committed only AFTER the device write confirmed. A failed
     write halts the walk with the cursor strictly before the failed
     entry; the next `advance/2` retries -- the block never silently
     vanishes (print-once means a marked-but-unprinted block could never
     be emitted again). `InlineAuthority.try_seal/2` is the
     write-confirming substrate; `Raxol.Harness.SealFrontier.commit_walk/5`'s
     `{:error, :write_failed, state}` branch (previously corpus-only) is
     driven here through the REAL device seam.

  2. **Frame-order law (adopt resize dims FIRST, then seal, then repaint
     the footer).** A resize arriving in the same frame as an advance
     must be adopted before any seal in that advance -- a block sealed at
     a stale width hard-wraps over-wide rows and permanently garbles the
     print-once copy in native scrollback. This is the named red-first
     obligation recorded at the bottom of
     `test/harness/seal_frontier_test.exs`. (In this substrate the footer
     row count is geometry-fixed -- never a function of post-seal state --
     so "size the footer to the post-seal state" is satisfied by
     construction; the load-bearing halves are adopt-before-seal and
     footer-repaint-after-seal.)

  3. **Synchronized output (DEC private mode 2026).** A frame that seals
     at least one block AND repaints the footer is wrapped in
     `\\e[?2026h` ... `\\e[?2026l` so multi-block seals present
     atomically -- gated on the terminal capability record
     (`Capabilities.sync_output`); capability absent/unknown emits
     nothing. Brackets stay balanced even when a seal write fails
     mid-frame, and the O1 byte oracle models the bracket tokens rather
     than halting unverifiable.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Surface
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Capabilities
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority
  alias Raxol.UI.TextMeasure

  @width 100
  @rows 20
  @footer_rows 6

  @sync_open "\e[?2026h"
  @sync_close "\e[?2026l"

  # A content marker that appears in exactly one place: the sealed block's
  # body. The failing device keys on it, and the retry-not-vanish
  # assertions count its occurrences in the confirmed byte stream.
  @marker "RETRY-ME"

  # ---------------------------------------------------------------------
  # A device that fails exactly one targeted write, then recovers.
  #
  # Implements the Erlang I/O protocol. Replies `{:error, :enospc}` to the
  # FIRST `put_chars` request whose bytes contain `marker` AND a `\r\n`
  # (only SEAL writes are `\r\n`-terminated -- the footer's pending
  # preview carries the same content but is CUP-positioned, never
  # newline-carrying, so the failure targets exactly the seal write). With
  # `fail_first: true` it instead fails the very first request of any
  # kind. Every other request delegates to an inner StringIO sink -- so
  # the sink holds exactly the bytes the device CONFIRMED, which is what a
  # real terminal would have received. `IO.write/2` surfaces the error
  # reply as a raised `ArgumentError` (and a dead device as `ErlangError`)
  # -- the two error classes `InlineAuthority.try_seal/2` must catch.
  # ---------------------------------------------------------------------
  defmodule FailingDevice do
    def start(opts) do
      {:ok, sink} = StringIO.open("")
      marker = Keyword.get(opts, :marker)
      fail_first? = Keyword.get(opts, :fail_first, false)
      pid = spawn_link(fn -> loop(sink, marker, fail_first?, false) end)
      {pid, sink}
    end

    def confirmed_bytes(sink) do
      {_in, out} = StringIO.contents(sink)
      out
    end

    defp loop(sink, marker, fail_first?, failed?) do
      receive do
        {:io_request, from, ref, {:put_chars, _enc, chars}} ->
          bytes = IO.iodata_to_binary(chars)

          fail_now? =
            not failed? and
              (fail_first? or
                 (marker != nil and String.contains?(bytes, marker) and
                    String.contains?(bytes, "\r\n")))

          if fail_now? do
            send(from, {:io_reply, ref, {:error, :enospc}})
            loop(sink, marker, fail_first?, true)
          else
            IO.write(sink, bytes)
            send(from, {:io_reply, ref, :ok})
            loop(sink, marker, fail_first?, failed?)
          end

        {:io_request, from, ref, _other} ->
          send(from, {:io_reply, ref, {:error, :request}})
          loop(sink, marker, fail_first?, failed?)
      end
    end
  end

  # -- shared helpers -----------------------------------------------------

  # One turn, one completed message block carrying `content`.
  defp message_events(content) do
    [
      %{
        id: 1,
        family: :loop,
        type: :turn_started,
        tier: :durable,
        payload: %{prompt: "go"}
      },
      %{
        id: 2,
        family: :loop,
        type: :item_started,
        tier: :durable,
        payload: %{item_id: "i1", item_type: "message"}
      },
      %{
        id: 3,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{item_id: "i1", item_type: "message", content: content}
      },
      %{
        id: 4,
        family: :loop,
        type: :turn_completed,
        tier: :durable,
        payload: %{final: true}
      }
    ]
  end

  defp new_model(events, opts) do
    device =
      Keyword.get_lazy(opts, :device, fn ->
        {:ok, dev} = StringIO.open("")
        dev
      end)

    Surface.new(
      events,
      Keyword.merge(
        [
          device: device,
          width: @width,
          rows: @rows,
          footer_rows: @footer_rows,
          mode: :inline_log,
          capabilities: nil
        ],
        opts
      )
    )
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # Advances until exactly one step BEFORE the flush: all but the last
  # event revealed, the single block still pending (held by the foldable
  # window, which releases only when the reveal finishes). The NEXT
  # advance reveals the final event AND seals -- the sealing frame.
  defp advance_to_pending_flush(model) do
    Enum.reduce(1..(length(model.events) - 1), model, fn _n, m ->
      {m, :ok} = Surface.advance(m)
      m
    end)
  end

  # The bytes a single step emitted: run `fun`, return {result, new_bytes}.
  defp frame_bytes(read_fun, fun) do
    before_bytes = read_fun.()
    result = fun.()
    after_bytes = read_fun.()

    {result,
     binary_part(
       after_bytes,
       byte_size(before_bytes),
       byte_size(after_bytes) - byte_size(before_bytes)
     )}
  end

  defp occurrences(haystack, needle) do
    haystack |> :binary.matches(needle) |> length()
  end

  # Max VISIBLE line width in a byte stream: folds the token stream,
  # accumulating text-run display widths into the current line; a newline
  # or any cursor reposition (CUP) starts a new line, escape tokens
  # contribute zero width. This is what "laid out at the adopted width"
  # means at the byte level.
  defp max_visible_line_width(bytes) do
    bytes
    |> SequenceScanner.scan()
    |> Enum.reduce({0, 0}, fn
      {:csi, _params, "H"}, {cur, max_w} ->
        {0, max(max_w, cur)}

      {:text, text}, {cur, max_w} ->
        [first | rest] = String.split(text, ["\r\n", "\n"])

        case rest do
          [] ->
            {cur + TextMeasure.display_width(first), max_w}

          _ ->
            widths = [cur + TextMeasure.display_width(first)] ++
                Enum.map(rest, &TextMeasure.display_width/1)

            {List.last(widths), Enum.max([max_w | widths])}
        end

      _token, acc ->
        acc
    end)
    |> then(fn {cur, max_w} -> max(cur, max_w) end)
  end

  # =======================================================================
  # 1. Two-phase seal: write -> confirm -> mark
  # =======================================================================

  describe "1. two-phase seal (write -> confirm -> mark)" do
    test "a failed device write leaves the block unsealed and the next advance retries it (retry-not-vanish)" do
      {device, sink} = FailingDevice.start(marker: @marker)

      # The marker sits on the block's THIRD body line: the footer's
      # pending-preview (a legitimately repaintable surface, NOT sealed
      # history) shows only the first two body lines, so the marker's
      # ONLY route to the device is the seal write itself -- which is
      # exactly what the confirmed-bytes occurrence counts below measure.
      content =
        "preview line one\npreview line two\n" <>
          @marker <> " " <> String.duplicate("payload ", 6)

      model = new_model(message_events(content), device: device)

      # Reveal everything; the block is still pending (foldable window).
      model = advance_to_pending_flush(model)
      assert model.painted_count == 0

      # The flushing frame: the device rejects the seal's content write.
      # The walk must halt WITHOUT marking -- painted_count unchanged, the
      # frame survives (no raise out of advance), and no marker bytes were
      # confirmed by the device.
      {model, :ok} = Surface.advance(model)

      assert model.painted_count == 0,
             "a failed write must never mark the block committed " <>
               "(mark-before-write would make it vanish from print-once history)"

      assert occurrences(FailingDevice.confirmed_bytes(sink), @marker) == 0

      # The very next advance retries the SAME entry and succeeds: the
      # block seals exactly once -- retried, never vanished, never doubled.
      {model, :done} = Surface.advance(model)

      assert model.painted_count == 1
      assert occurrences(FailingDevice.confirmed_bytes(sink), @marker) == 1
    end

    test "try_seal/2 returns the authority untouched on a dead device (ErlangError class)" do
      {:ok, dead} = StringIO.open("")
      # Drain the construction bytes, then kill the device.
      authority = InlineAuthority.new(dead, 40, 10, 3)
      StringIO.close(dead)

      assert {:error, :write_failed, returned} =
               InlineAuthority.try_seal(authority, "line\r\n")

      assert returned == authority,
             "a failed seal must return the ORIGINAL authority " <>
               "(next_row not advanced) so the retry re-positions from scratch"
    end

    test "try_seal/2 returns the authority untouched on an {:error, _} device reply (ArgumentError class)" do
      # Construction bytes (the DECSTBM set) carry no marker, so they
      # succeed; the seal content write is the first marker-bearing
      # request and gets the {:error, :enospc} reply.
      {device, sink} = FailingDevice.start(marker: "line")
      authority = InlineAuthority.new(device, 40, 10, 3)

      assert {:error, :write_failed, returned} =
               InlineAuthority.try_seal(authority, "line\r\n")

      assert returned.next_row == authority.next_row
      assert occurrences(FailingDevice.confirmed_bytes(sink), "line") == 0
    end

    test "try_seal/2 still raises on the caller-contract violation (missing \\r\\n) -- never masked as :write_failed" do
      {:ok, device} = StringIO.open("")
      authority = InlineAuthority.new(device, 40, 10, 3)

      assert_raise ArgumentError, ~r/\\r\\n-terminated/, fn ->
        InlineAuthority.try_seal(authority, "no terminator")
      end
    end

    test "post-seal fill protection: a fold override on an already-painted block is rejected and stores nothing" do
      # No placeholder-fill path against sealed content exists in this
      # codebase (grepped; the SessionRecap pattern has no analogue) -- so
      # this test PINS the API contract: the only mutation channel aimed
      # at a painted block (a fold override) must be rejected, storing
      # nothing, and sealed history bytes must stay byte-identical.
      {:ok, device} = StringIO.open("")
      model = new_model(message_events("sealed body"), device: device)

      model =
        Enum.reduce_while(1..10, model, fn _n, m ->
          case Surface.advance(m) do
            {m, :done} -> {:halt, m}
            {m, :ok} -> {:cont, m}
          end
        end)

      assert model.painted_count == 1
      history_before = raw(device)

      toggled =
        model
        |> Surface.focus_transcript()
        |> Surface.handle_input(Raxol.Core.Events.Event.key("j"))
        |> Surface.handle_input(Raxol.Core.Events.Event.key("z"))

      assert toggled.fold_overrides == %{},
             "a fold override for a painted block index must never be stored"

      # Footer notice may repaint; sealed history rows must not. Every new
      # byte after the toggle must stay inside the footer region.
      new_bytes =
        binary_part(
          raw(device),
          byte_size(history_before),
          byte_size(raw(device)) - byte_size(history_before)
        )

      region_top = @rows - @footer_rows

      for row <- SealOracle.cup_rows(new_bytes) do
        assert row > region_top or row == 1,
               "post-toggle byte addressed history row #{row} -- " <>
                 "sealed content must be untouchable after paint"
      end
    end
  end

  # =======================================================================
  # 2. Frame-order law: adopt resize dims FIRST, then seal, then footer
  # =======================================================================

  describe "2. frame-order law (resize-during-commit)" do
    test "a block finalizing on a shrink frame commits at the adopted width, not the stale one" do
      # The named obligation from test/harness/seal_frontier_test.exs:
      # stale-width bytes in the print-once stream are permanent
      # corruption -- native scrollback cannot be rewritten.
      {:ok, device} = StringIO.open("")
      long_line = String.duplicate("wide-content ", 7) <> "END"
      assert TextMeasure.display_width(long_line) > 60

      model =
        new_model(message_events(long_line), device: device, width: @width)

      model = advance_to_pending_flush(model)
      assert model.painted_count == 0

      new_width = 60

      {{model, :done}, flush_bytes} =
        frame_bytes(fn -> raw(device) end, fn ->
          Surface.advance(model, nil, resize: {new_width, @rows})
        end)

      assert model.width == new_width
      assert model.painted_count == 1

      assert max_visible_line_width(flush_bytes) <= new_width,
             "a block sealing on a shrink frame must be laid out at the " <>
               "NEW width (#{new_width}); found a wider line -- stale-width " <>
               "bytes in the print-once stream are permanent corruption"
    end

    test "in a combined frame the region re-set precedes the seal, and the footer repaint follows it" do
      {:ok, device} = StringIO.open("")
      model = new_model(message_events(@marker), device: device)
      model = advance_to_pending_flush(model)

      new_rows = 14

      {{model, :done}, flush_bytes} =
        frame_bytes(fn -> raw(device) end, fn ->
          Surface.advance(model, nil, resize: {@width, new_rows})
        end)

      assert model.rows == new_rows

      # Adopt-first, mechanically: the DECSTBM re-set for the NEW split is
      # the frame's only region set, and it appears BEFORE the sealed
      # content bytes.
      assert SealOracle.region_sets(flush_bytes) ==
               [{1, new_rows - @footer_rows}]

      {region_at, _} = :binary.match(flush_bytes, "\e[1;#{new_rows - @footer_rows}r")
      {seal_at, _} = :binary.match(flush_bytes, @marker)

      assert region_at < seal_at,
             "resize dims must be adopted (region re-set) before the seal writes"

      # Footer-repaint-after-seal: at least one footer-region CUP appears
      # after the sealed content (the keyframe at the new geometry).
      footer_top = new_rows - @footer_rows + 1
      tail = binary_part(flush_bytes, seal_at, byte_size(flush_bytes) - seal_at)

      footer_rows_addressed =
        tail
        |> SealOracle.cup_rows()
        |> Enum.filter(&(&1 >= footer_top))

      assert footer_rows_addressed != [],
             "the footer must be repainted after the seal, at the new geometry"
    end
  end

  # =======================================================================
  # 3. Synchronized output (DEC private mode 2026)
  # =======================================================================

  describe "3. synchronized output (DEC 2026)" do
    defp sync_caps, do: %Capabilities{sync_output: true}

    test "a sealing frame is wrapped in ?2026 brackets when the capability reports support" do
      {:ok, device} = StringIO.open("")

      model =
        new_model(message_events("hello"),
          device: device,
          capabilities: sync_caps()
        )

      model = advance_to_pending_flush(model)

      {{_model, :done}, flush_bytes} =
        frame_bytes(fn -> raw(device) end, fn -> Surface.advance(model) end)

      assert String.starts_with?(flush_bytes, @sync_open),
             "the sealing frame's FIRST bytes must open the sync bracket"

      assert String.ends_with?(flush_bytes, @sync_close),
             "the sealing frame's LAST bytes must close the sync bracket " <>
               "(after the footer repaint)"

      assert occurrences(flush_bytes, @sync_open) == 1
      assert occurrences(flush_bytes, @sync_close) == 1
    end

    test "a non-sealing frame emits no sync brackets" do
      {:ok, device} = StringIO.open("")

      model =
        new_model(message_events("hello"),
          device: device,
          capabilities: sync_caps()
        )

      # The first advance reveals turn_started -- no block, no seal.
      {{_model, :ok}, bytes} =
        frame_bytes(fn -> raw(device) end, fn -> Surface.advance(model) end)

      refute bytes =~ "2026"
    end

    test "capability absent (nil) emits no brackets anywhere in a full run" do
      {:ok, device} = StringIO.open("")
      model = new_model(message_events("hello"), device: device)

      Enum.reduce_while(1..10, model, fn _n, m ->
        case Surface.advance(m) do
          {m, :done} -> {:halt, m}
          {m, :ok} -> {:cont, m}
        end
      end)

      refute raw(device) =~ "2026",
             "capability unknown -> don't emit (inline mode included)"
    end

    test "flat mode never emits brackets even with the capability present" do
      {:ok, device} = StringIO.open("")

      model =
        new_model(message_events("hello"),
          device: device,
          mode: :flat,
          capabilities: sync_caps()
        )

      Enum.reduce_while(1..10, model, fn _n, m ->
        case Surface.advance(m) do
          {m, :done} -> {:halt, m}
          {m, :ok} -> {:cont, m}
        end
      end)

      refute raw(device) =~ "2026"
    end

    test "a seal failure inside the bracket still emits the closing bracket (balanced)" do
      {device, sink} = FailingDevice.start(marker: @marker)

      model =
        new_model(message_events(@marker <> " body"),
          device: device,
          capabilities: sync_caps()
        )

      model = advance_to_pending_flush(model)

      # Failing frame, then the retry frame.
      {model, :ok} = Surface.advance(model)
      {_model, :done} = Surface.advance(model)

      confirmed = FailingDevice.confirmed_bytes(sink)

      assert occurrences(confirmed, @sync_open) ==
               occurrences(confirmed, @sync_close),
             "sync brackets must stay balanced across a mid-frame seal failure"

      assert occurrences(confirmed, @sync_close) >= 1
    end

    test "the O1 row walk models a sync-bracketed seal stream instead of halting unverifiable" do
      {:ok, device} = StringIO.open("")

      model =
        new_model(message_events("hello"),
          device: device,
          capabilities: sync_caps()
        )

      model = advance_to_pending_flush(model)

      {{_model, :done}, flush_bytes} =
        frame_bytes(fn -> raw(device) end, fn -> Surface.advance(model) end)

      assert {:ok, _rows} = SealOracle.row_walk(flush_bytes),
             "?2026 h/l must be in the oracle's ignorable vocabulary"

      assert SequenceScanner.capability({:csi, "?2026", "h"}) ==
               :synchronized_output
    end
  end
end
