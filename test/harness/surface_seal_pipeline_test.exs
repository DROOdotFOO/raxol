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
     (`Capabilities.sync_output`, strict struct match); capability
     absent/unknown emits nothing. Brackets stay balanced even when a
     seal write fails mid-frame; a CLOSE write the device refuses is
     latched as owed and re-attempted at the next frame of any kind (the
     dangling-open wedge heals -- describe 4). The O1 byte oracle models
     the bracket tokens rather than halting unverifiable.

  Describe block 4 covers the adversarial-review hardening pass on the
  above: device-error classification by origin
  (`InlineAuthority.device_io_error?/2` -- a logic bug raising the same
  exception class must stay loud, never become a silent retry loop), the
  `Dialect`-owned sync wire vocabulary, the strict capability-record
  match, and the dangling-close heal.
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
  # FIRST `put_chars` request whose bytes satisfy the `fail_when`
  # predicate, and delegates every other request to an inner StringIO sink
  # -- so the sink holds exactly the bytes the device ACCEPTED, which is
  # what a real terminal would have received. `IO.write/2` surfaces the
  # error reply as a raised `ArgumentError` (and a dead device as
  # `ErlangError`) -- the two device-error classes the authority's seam
  # must classify (see `InlineAuthority.device_io_error?/2`).
  #
  # `seal_write_with/1` builds the predicate the retry tests use: only
  # SEAL writes are `\r\n`-terminated (the footer's pending preview
  # carries the same content but is CUP-positioned, never
  # newline-carrying), so marker + `\r\n` targets exactly the seal write.
  # ---------------------------------------------------------------------
  defmodule FailingDevice do
    def start(opts) do
      {:ok, sink} = StringIO.open("")
      fail_when = Keyword.fetch!(opts, :fail_when)
      # :once (default) recovers after the first failure -- the transient
      # topology. :always keeps refusing every matching write -- the
      # non-transient topology round-2's observability finding targets.
      mode = Keyword.get(opts, :mode, :once)
      pid = spawn_link(fn -> loop(sink, fail_when, mode, false) end)
      {pid, sink}
    end

    def confirmed_bytes(sink) do
      {_in, out} = StringIO.contents(sink)
      out
    end

    defp loop(sink, fail_when, mode, failed?) do
      receive do
        {:io_request, from, ref, {:put_chars, _enc, chars}} ->
          bytes = IO.iodata_to_binary(chars)

          if (mode == :always or not failed?) and fail_when.(bytes) do
            send(from, {:io_reply, ref, {:error, :enospc}})
            loop(sink, fail_when, mode, true)
          else
            IO.write(sink, bytes)
            send(from, {:io_reply, ref, :ok})
            loop(sink, fail_when, mode, failed?)
          end

        {:io_request, from, ref, _other} ->
          send(from, {:io_reply, ref, {:error, :request}})
          loop(sink, fail_when, mode, failed?)
      end
    end
  end

  defp seal_write_with(marker) do
    fn bytes ->
      String.contains?(bytes, marker) and String.contains?(bytes, "\r\n")
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
            widths =
              [cur + TextMeasure.display_width(first)] ++
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
      {device, sink} = FailingDevice.start(fail_when: seal_write_with(@marker))

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

    test "try_seal/2 fail-fasts on a dead device -- a corpse is never retried" do
      # Round-2 review: a dead device (%ErlangError{original: :terminated})
      # is PERMANENT by construction -- the io-server pid is gone and the
      # same pid can never come back -- so classifying it retryable turned
      # the pre-PR loud crash into a silent infinite retry loop. try_seal/2
      # must re-raise it (fail-fast, restoring the loud failure), reserving
      # {:error, :write_failed, _} for the ALIVE-but-refusing device class
      # (the {:error, reason} io reply), which is plausibly transient.
      {:ok, dead} = StringIO.open("")
      authority = InlineAuthority.new(dead, 40, 10, 3)
      StringIO.close(dead)

      assert_raise ErlangError, fn ->
        InlineAuthority.try_seal(authority, "line\r\n")
      end
    end

    test "try_seal/2 returns the authority untouched on an {:error, _} device reply (ArgumentError class)" do
      # Construction bytes (the DECSTBM set) carry no marker, so they
      # succeed; the seal content write is the first marker-bearing
      # request and gets the {:error, :enospc} reply.
      {device, sink} = FailingDevice.start(fail_when: seal_write_with("line"))
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

    test "a refused seal write keeps the unsealed block visible in the footer preview (the display half of retry-not-vanish)" do
      # The state half of retry-not-vanish (the test above) proves the
      # block stays unsealed for retry. This is the DISPLAY half: while
      # it waits, the block must still be somewhere the operator can see
      # -- it is not in history (the device refused those bytes), so the
      # footer's pending preview is its only honest home. Deriving the
      # preview from `scan_frontier/3`'s tail_start hides it: the scan is
      # the PRE-commit projection ("what would remain after an ideal
      # commit"), which consumes committable entries -- including the one
      # whose write just failed -- so the failed block lands BEFORE
      # tail_start and vanishes from both surfaces at once. The preview
      # must key on the committed cursor (painted_count) instead.
      {device, sink} =
        FailingDevice.start(fail_when: seal_write_with(@marker), mode: :always)

      model = new_model(message_events(@marker <> " body"), device: device)
      model = advance_to_pending_flush(model)

      # The flushing frame: the seal write is refused, the block stays
      # unsealed (state half, pinned above).
      {model, :ok} = Surface.advance(model)
      assert model.painted_count == 0

      # Force a full-footer keyframe (resize/2 keyframes unconditionally;
      # footer rows are CUP-positioned, never \r\n-carrying, so the
      # :always device accepts them) and read exactly its bytes: the
      # unsealed block's content MUST be painted in the footer preview.
      read = fn -> FailingDevice.confirmed_bytes(sink) end

      {_model, keyframe_bytes} =
        frame_bytes(read, fn -> Surface.resize(model, @width, @rows) end)

      assert occurrences(keyframe_bytes, @marker) >= 1,
             "an unsealed (refused-write) block must stay visible in the " <>
               "footer preview -- invisible-but-retrying is under-reporting"
    end

    test "no full-clear reaches the wire through the refused-write footer-preview path (end-to-end, independent oracle)" do
      # The display half above pins that a refused block stays VISIBLE in the
      # footer preview. This pins that it stays visible HONESTLY: content that
      # smuggles a raw CSI full-screen clear (`\e[2J` -- forbidden on the
      # inline surface, it wipes native scrollback / the immutable prefix)
      # must never reach the wire as a live escape through this path.
      #
      # SCOPE + attribution (the #635-R1 correction). This is an END-TO-END
      # integration pin over the whole refused-write -> footer-preview
      # pipeline, NOT a single-seam pin -- and it does not attribute to one
      # layer. TWO layers neutralize here, so this path has genuine defense
      # in depth (traced: the raw `\e[2J` is already gone from the rendered
      # view before ContentGuard ever runs):
      #   1. the message-body renderer strips ESC/C0 while building the
      #      display view, so footer content arrives already de-escaped;
      #   2. the footer paint routes EVERY line through
      #      `ContentGuard.sanitize_line/1` (`inline_authority.ex:436,860`).
      # The two SEAM guarantees are pinned directly and red-first ELSEWHERE:
      # `ContentGuard.sanitize_line(<<0x1B, "[2J">>) == "[2J"` in
      # `test/raxol/harness/c1_sanitizer_test.exs`, and the footer-paint seam
      # against the same independent full-clear oracle in
      # `test/property/renderer_t2c_review_fixes_test.exs`. This test proves
      # they COMPOSE over the refused-write preview surface, judged by that
      # independent oracle (`SealOracle.emits_full_clear?/1`) rather than a
      # brittle byte-substring match.
      hostile = @marker <> " \e[2J HOSTILE"

      # Fail-first (the t2c discipline): the oracle must be ABLE to catch a
      # raw full-clear, or the GREEN refute below is vacuous.
      assert SealOracle.emits_full_clear?("composer " <> hostile),
             "fail-first: the full-clear oracle must catch a raw \\e[2J, " <>
               "or the clean result below is meaningless"

      {device, sink} =
        FailingDevice.start(fail_when: seal_write_with(@marker), mode: :always)

      model = new_model(message_events(hostile), device: device)
      model = advance_to_pending_flush(model)

      {model, :ok} = Surface.advance(model)
      assert model.painted_count == 0

      read = fn -> FailingDevice.confirmed_bytes(sink) end

      {_model, keyframe_bytes} =
        frame_bytes(read, fn -> Surface.resize(model, @width, @rows) end)

      assert occurrences(keyframe_bytes, @marker) >= 1,
             "the refused block must still be visible in the footer preview"

      refute SealOracle.emits_full_clear?(keyframe_bytes),
             "no \\e[2J may reach the wire through the refused-write footer " <>
               "preview -- the independent full-clear oracle must stay silent"

      assert occurrences(keyframe_bytes, "[2J") >= 1,
             "the neutralized clear-screen stays honestly visible as literal " <>
               "`[2J` residue in the footer preview (not silently dropped)"
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

      {region_at, _} =
        :binary.match(flush_bytes, "\e[1;#{new_rows - @footer_rows}r")

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
      {device, sink} = FailingDevice.start(fail_when: seal_write_with(@marker))

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

  # =======================================================================
  # 4. Adversarial-review hardening (PR review round 1)
  # =======================================================================

  describe "4. review hardening: device-error classification" do
    test "device_io_error?/2 recognizes the two device classes and rejects local raises" do
      # Class 1: an io server replying {:error, reason} -- IO.write raises
      # ArgumentError FROM :io.put_chars (the stack head names the origin).
      {device, _sink} = FailingDevice.start(fail_when: fn _bytes -> true end)

      {reply_error, reply_stack} =
        try do
          IO.write(device, "x")
          flunk("expected the failing device to raise")
        rescue
          e -> {e, __STACKTRACE__}
        end

      assert %ArgumentError{} = reply_error
      assert InlineAuthority.device_io_error?(reply_error, reply_stack)

      # Class 2: a dead device -- ErlangError{original: :terminated},
      # same :io origin.
      {:ok, dead} = StringIO.open("")
      StringIO.close(dead)

      {dead_error, dead_stack} =
        try do
          IO.write(dead, "x")
          flunk("expected the dead device to raise")
        rescue
          e -> {e, __STACKTRACE__}
        end

      assert %ErlangError{original: :terminated} = dead_error
      assert InlineAuthority.device_io_error?(dead_error, dead_stack)

      # A logic bug raising the SAME exception class from NON-device code
      # must NOT classify as a device error -- it must stay loud (the
      # over-broad-rescue finding: masking it would turn a code bug into
      # an unbounded silent retry loop).
      {local_error, local_stack} =
        try do
          raise ArgumentError, "logic bug, not a device"
        rescue
          e -> {e, __STACKTRACE__}
        end

      refute InlineAuthority.device_io_error?(local_error, local_stack)
    end

    test "the Dialect owns the sync-bracket wire vocabulary (raw-byte oracle)" do
      # The raw bytes here are DELIBERATELY duplicated rather than read
      # from the constant under test: this is the drift guard -- a typo in
      # the Dialect (2026 vs 2027, h vs l) fails here instead of
      # propagating silently into every emit site.
      alias Raxol.UI.Rendering.PaintAuthority.Dialect

      assert Dialect.sync_begin() == "\e[?2026h"
      assert Dialect.sync_end() == "\e[?2026l"
    end

    test "a plain map masquerading as a capability record does not enable sync emission" do
      {:ok, device} = StringIO.open("")

      model =
        new_model(message_events("hello"),
          device: device,
          capabilities: %{sync_output: true}
        )

      model = advance_to_pending_flush(model)

      {_result, flush_bytes} =
        frame_bytes(fn -> raw(device) end, fn -> Surface.advance(model) end)

      refute flush_bytes =~ "2026",
             "only a %Capabilities{} record may enable sync emission -- " <>
               "a stray map with the right key must not"
    end
  end

  describe "4. review hardening: dangling sync bracket heals" do
    test "a close-write failure does not wedge the terminal: the owed close is re-attempted on the next frame" do
      # The device accepts the OPEN but faults exactly on the CLOSE write
      # -- the wedge case: ?2026h landed on the wire with no matching
      # ?2026l, terminal frozen in synchronized mode. The authority must
      # remember the owed close and re-attempt it on the next frame of any
      # kind (here: a plain tick), healing as soon as the device accepts a
      # byte again.
      {device, sink} =
        FailingDevice.start(
          fail_when: fn bytes -> String.contains?(bytes, "\e[?2026l") end
        )

      model =
        new_model(message_events("hello"),
          device: device,
          capabilities: %Capabilities{sync_output: true}
        )

      model = advance_to_pending_flush(model)
      {model, :done} = Surface.advance(model)

      confirmed = FailingDevice.confirmed_bytes(sink)

      assert occurrences(confirmed, @sync_open) == 1

      assert occurrences(confirmed, @sync_close) == 0,
             "precondition: the close write was rejected by the device"

      # The next frame -- a plain ticker frame, no seal -- must emit the
      # owed close.
      _model = Surface.tick(model, 1)

      healed = FailingDevice.confirmed_bytes(sink)

      assert occurrences(healed, @sync_close) == 1,
             "the owed close must be re-attempted on the next frame -- " <>
               "a dangling ?2026h wedges the terminal in synchronized mode"

      assert occurrences(healed, @sync_open) ==
               occurrences(healed, @sync_close)

      # And the close landed AFTER the open (ordering sanity).
      {open_at, _} = :binary.match(healed, @sync_open)
      {close_at, _} = :binary.match(healed, @sync_close)
      assert close_at > open_at
    end
  end

  # =======================================================================
  # 5. Review round 2: non-transient failure observability
  # =======================================================================

  describe "5. review round 2: refused-write telemetry" do
    test "every refused seal write emits [:raxol, :harness, :seal, :write_failed] -- a persistent refusal is observable, not silent" do
      # Round-2 review: an ALIVE device that permanently refuses the seal
      # write drives advance/2 to return {model, :ok} forever -- an
      # unbounded retry with, previously, no external signal at all. The
      # retry itself is the designed behavior for a refusing-but-alive
      # device (it may recover; a bound would strand the block when it
      # does) -- what was missing is OBSERVABILITY. This pins the
      # telemetry emit: one event per refused write, carrying the block
      # index and kind, so a driver/operator can see the loop and decide.
      handler_id = "seal-write-failed-#{inspect(make_ref())}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :harness, :seal, :write_failed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:write_failed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {device, sink} =
        FailingDevice.start(
          fail_when: seal_write_with(@marker),
          mode: :always
        )

      content = "preview line one\npreview line two\n" <> @marker
      model = new_model(message_events(content), device: device)
      model = advance_to_pending_flush(model)

      # Three failing frames: each returns :ok (retry pending), never
      # marks, never raises -- and each emits exactly one event.
      model =
        Enum.reduce(1..3, model, fn n, m ->
          {m, :ok} = Surface.advance(m)
          assert m.painted_count == 0

          assert_received {:write_failed, _measurements, metadata},
                          "refused write ##{n} must emit telemetry"

          assert metadata.index == 0
          assert metadata.kind == :message
          refute_received {:write_failed, _, _}
          m
        end)

      assert occurrences(FailingDevice.confirmed_bytes(sink), @marker) == 0

      # The loop stays honest end-to-end: the device is alive, so a
      # recovery is still possible -- this test only pins that the loop
      # is VISIBLE while it lasts.
      assert {_model, :ok} = Surface.advance(model)
      assert_received {:write_failed, _, _}
    end
  end
end
