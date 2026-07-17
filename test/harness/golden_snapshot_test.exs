defmodule Raxol.Harness.Surface.GoldenSnapshotTest do
  @moduledoc """
  Byte-golden snapshot tests for the harness degradation ladder: each
  fixed fixture session x render mode pair in
  `Raxol.Harness.Surface.Golden.fixtures()/modes()` is rendered end-to-end
  through the assembled `Raxol.Harness.Surface` and compared byte-for-byte
  against a checked-in golden file
  (`test/fixtures/harness/goldens/<fixture>.<mode>.golden`).

  Complements, rather than duplicates, `test/harness/t13a_surface_test.exs`
  (which asserts SEMANTIC invariants -- footer confinement, no-full-clear,
  seal-once, unicode survival -- via the O1/O2 oracles and plain-text
  projections) and `test/harness/golden_diff_test.exs` (which unit-tests
  the diff formatter in isolation). This suite is the byte-exact
  regression net one level below both: any change to the emitted bytes at
  all -- intentional or not -- fails here first, with a bounded, readable
  diff (never a raw binary dump) pointing at the first divergent byte.

  Run `mix raxol.harness.goldens.bless` to (re)generate the golden files
  after an intentional rendering change, and `mix raxol.harness.goldens.bless
  --check` to verify without writing (the CI-facing half).
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Surface
  alias Raxol.Harness.Surface.{Golden, GoldenDiff, ViewText}
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner
  alias Raxol.UI.Components.Harness.{Block, BlockBody}
  alias Raxol.UI.Rendering.PaintAuthority.ContentGuard

  # Geometry shared with `Golden.render/2` (see that module's determinism
  # audit) -- needed here by the seal-seam ingress tests, which drive the
  # Surface directly to get at the MODEL, not just the bytes.
  @width 60
  @rows 20
  @footer_rows 6
  @region_top @rows - @footer_rows

  # Sequence-vocabulary allowlist for `:inline_log`/`:tmux_conservative`
  # goldens -- the substrate's measured full vocabulary for those tiers:
  # CUP (`H`), EL (`K`), SGR (`m`), DECSTBM (`r`) from `InlineAuthority` /
  # `ScrollRegionManager`, plus DECSC/DECRC (`\e7`/`\e8`) save/restore-
  # cursor. A failure against these lists means either a poisoned golden
  # (something emitted a sequence outside this vocabulary, e.g. OSC 52
  # clipboard exfiltration) or a deliberate vocabulary extension that must
  # be reviewed and added here consciously.
  #
  # DEC 2026 synchronized-update brackets (`CSI ? 2026 h`/`l`, finals
  # `h`/`l`) are capability-gated (`Capabilities.sync_output`), and every
  # golden here renders with `capabilities: nil` -- so they never appear
  # in this vocabulary at all, deliberately: the capability-absent case is
  # pinned by `test/harness/surface_seal_pipeline_test.exs`
  # ("capability absent (nil) emits no brackets anywhere in a full run").
  #
  # CONSCIOUS EXTENSION (cursor-park protocol): DECTCEM hide/show
  # (`CSI ? 25 l`/`h`) wraps multi-row footer repaint bursts so the
  # parked composer cursor never visibly hops rows mid-rewrite (see
  # `InlineAuthority.repaint/3`'s park-protocol doc). The finals `h`/`l`
  # are NOT added to `@allowed_csi_finals` wholesale -- that would also
  # legitimize 2026 brackets and arbitrary private modes sneaking into a
  # capability-nil golden -- only the exact `?25` parameter is allowed,
  # via `@allowed_private_modes` below.
  @allowed_csi_finals ~w(H K m r)
  @allowed_private_modes ~w(?25)
  @allowed_esc_chars ~w(7 8)

  # ---------------------------------------------------------------------
  # (a) byte-golden + (b) determinism, one test pair per fixture x mode
  # ---------------------------------------------------------------------

  for fixture <- Golden.fixtures(), mode <- Golden.modes() do
    @fixture fixture
    @mode mode

    test "#{fixture} x #{mode}: byte-for-byte match against the checked-in golden" do
      rendered = Golden.render(@fixture, @mode)
      path = Golden.golden_path(@fixture, @mode)

      golden =
        case File.read(path) do
          {:ok, bytes} ->
            bytes

          {:error, _reason} ->
            flunk(
              "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`"
            )
        end

      case GoldenDiff.compare(golden, rendered) do
        :ok ->
          :ok

        {:diverged, _offset, report} ->
          flunk(
            "#{@fixture} x #{@mode} diverged from its checked-in golden -- " <>
              "if this is intentional, run `mix raxol.harness.goldens.bless` " <>
              "and review the diff before re-committing:\n\n#{report}"
          )
      end
    end

    test "#{fixture} x #{mode}: rendering twice in one run is byte-identical (determinism tripwire)" do
      first = Golden.render(@fixture, @mode)
      second = Golden.render(@fixture, @mode)

      assert first == second,
             "#{@fixture} x #{@mode} rendered different bytes across two calls " <>
               "in the SAME run -- some hidden state (map iteration order, " <>
               "process dictionary, unseeded randomness) is leaking into the " <>
               "byte stream; see Golden's moduledoc determinism audit"
    end
  end

  # ---------------------------------------------------------------------
  # (c) semantic guards on the CHECKED-IN golden bytes (must survive
  #     re-blessing -- these read the golden file, never a fresh render)
  # ---------------------------------------------------------------------

  describe "semantic guards on checked-in goldens" do
    test "flat mode goldens contain zero ESC bytes and zero escape-sequence tokens" do
      for fixture <- Golden.fixtures() do
        golden = read_golden!(fixture, :flat)

        refute golden =~ <<0x1B>>,
               "#{fixture} x flat golden contains a raw ESC byte"

        assert Enum.all?(SequenceScanner.scan(golden), &match?({:text, _}, &1)),
               "#{fixture} x flat golden contains a non-text (escape-sequence) token"
      end
    end

    test "inline_log and tmux_conservative goldens never emit a full-screen clear" do
      for fixture <- Golden.fixtures(),
          mode <- [:inline_log, :tmux_conservative] do
        golden = read_golden!(fixture, mode)

        refute golden =~ "\e[2J",
               "#{fixture} x #{mode} golden contains \\e[2J (full clear)"

        refute golden =~ "\e[3J",
               "#{fixture} x #{mode} golden contains \\e[3J (full clear + scrollback)"

        refute SealOracle.emits_full_clear?(golden),
               "#{fixture} x #{mode} golden emits a full clear per SealOracle"
      end
    end

    test "inline_log and tmux_conservative goldens use only the measured sequence vocabulary" do
      for fixture <- Golden.fixtures(),
          mode <- [:inline_log, :tmux_conservative] do
        golden = read_golden!(fixture, mode)
        tokens = SequenceScanner.scan(golden)

        refute Enum.any?(tokens, &match?({:osc, _}, &1)),
               "#{fixture} x #{mode} golden contains an OSC sequence -- outside " <>
                 "the measured vocabulary (see the allowlist comment above)"

        refute Enum.any?(tokens, &match?({:dcs, _}, &1)),
               "#{fixture} x #{mode} golden contains a DCS sequence -- outside " <>
                 "the measured vocabulary (see the allowlist comment above)"

        for {:csi, params, final} <- tokens do
          assert final in @allowed_csi_finals or
                   (final in ~w(h l) and params in @allowed_private_modes),
                 "#{fixture} x #{mode} golden contains a CSI sequence " <>
                   "#{inspect(params)} #{inspect(final)}, outside the " <>
                   "allowlist #{inspect(@allowed_csi_finals)} + private " <>
                   "modes #{inspect(@allowed_private_modes)}"
        end

        for {:esc, ch} <- tokens do
          assert ch in @allowed_esc_chars,
                 "#{fixture} x #{mode} golden contains an ESC sequence #{inspect(ch)}, " <>
                   "outside the allowlist #{inspect(@allowed_esc_chars)}"
        end
      end
    end

    test "no golden carries ESC-less parameterized control-sequence residue (the ContentGuard-stripped class)" do
      # `ContentGuard.sanitize_line/1`'s "visible-honest" neutralization
      # strips a disallowed sequence's ESC byte but keeps the printable
      # remainder -- so a caller that wrongly embeds a control sequence
      # (e.g. `\e[1;14r`) in CONTENT it hands to `InlineAuthority.seal/2`
      # leaves literal residue painted into sealed history, visible on a
      # real terminal, invisible to every substring-based semantic
      # assertion. This guard scans each golden's TEXT tokens (already
      # ESC-free by tokenization) for the UNAMBIGUOUS half of that class
      # -- see `escless_residue/1`'s comment for why paramless residue
      # (`[K` et al.) is out of scope here and owned by the ContentGuard/
      # seal seam upstream.
      for fixture <- Golden.fixtures(), mode <- Golden.modes() do
        golden = read_golden!(fixture, mode)
        residue = escless_residue(golden)

        assert residue == [],
               "#{fixture} x #{mode} golden contains ESC-less control-sequence " <>
                 "residue in its text tokens (a ContentGuard-stripped sequence " <>
                 "embedded in sealed content): #{inspect(residue, printable_limit: 200)}"
      end
    end
  end

  # Text tokens of `raw` that carry stripped-CSI residue: `[` followed
  # by a numeric parameter run and a final letter (`[2J`, `[1;14r`,
  # `[12;24H`). Deliberately NO empty-param branch: after
  # `ContentGuard.sanitize_line/1` strips the ESC, a paramless final
  # (`\e[K` -> `[K`, likewise `[P`/`[L`/`[M`) is byte-identical to the
  # first two characters of an ordinary uppercase bracket label
  # (`[KEY]`, `[ERROR]`, `[DONE]` -- all plausible agent output), so any
  # fixed letter set either misses paramless editors or false-positives
  # on labels and blocks a legitimate bless. The paramless class is
  # owned by the ENFORCED seal-seam ingress invariant (describe
  # "seal-seam ingress invariant" above: outbound seal content must be a
  # ContentGuard fixed point, pinned to reality by the replay
  # comparison), not by this regex.
  #
  # Known residual false-positive class, accepted and documented: short
  # digit-leading bracket labels -- 1-3 digits immediately followed by a
  # letter (`[4K]`, `[8K]`, `[2FA]`, `[3D]`, `[1st]`, `[100x]`) are
  # shape-identical to real residue post-strip and WILL trip this guard
  # (`[200 OK]` and `[1080p]` pass clean: the digit run caps at 3 and
  # must be immediately followed by a letter). None of the current
  # fixtures carries such a label; the first fixture that does will need
  # this guard revisited (e.g. a per-fixture allowlist), not silently
  # widened.
  @escless_residue ~r/\[\d{1,3}(?:;\d{1,3})*[A-Za-z]/
  defp escless_residue(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.filter(&Regex.match?(@escless_residue, &1))
  end

  # ---------------------------------------------------------------------
  # (c2) the seal-seam ingress invariant: the ENFORCED owner of the
  #      paramless-residue class the narrowed guard above deliberately
  #      does not cover. Dropping seal_block/2's embedded \e[K was a
  #      SOURCE fix; these tests make the seam contract an INVARIANT: if
  #      any future seal caller re-embeds a non-SGR escape in content,
  #      ContentGuard strips it to ESC-less text that no post-hoc regex
  #      can distinguish from prose -- so the check must live at ingress.
  # ---------------------------------------------------------------------

  describe "seal-seam ingress invariant" do
    # Drives the REAL Surface (same construction as `Golden.render/2`,
    # but keeping the final model) so the sealed blocks and the actual
    # emitted bytes come from one replay.
    defp drive_fixture(fixture, mode) do
      path =
        Path.join([
          "test",
          "fixtures",
          "harness",
          "sessions",
          "#{fixture}.jsonl"
        ])

      {:ok, session} = Fixture.load(path)
      {:ok, device} = StringIO.open("")

      model =
        Surface.new(session,
          device: device,
          width: @width,
          rows: @rows,
          footer_rows: @footer_rows,
          mode: mode,
          env: %{},
          capabilities: nil
        )

      model =
        Golden.drive_to_completion(
          model,
          Golden.max_steps(length(session.envelopes))
        )

      {_in, out} = StringIO.contents(device)
      StringIO.close(device)
      {model, out}
    end

    # Reconstructs exactly the iodata `Surface.seal_block/2` (inline
    # path) hands to `InlineAuthority.seal/2`, one binary per block:
    # `BlockBody.render/2 |> ViewText.lines(width, :styled)` then
    # `\r\n`-terminated lines. Valid for a replay with NO fold input:
    # `fold_overrides` is empty, so `apply_fold_override/3` returns every
    # block unchanged, and `detach_up_to/2` only `:binary.copy/1`s
    # content (byte-identical) -- the final model's `projection.blocks`
    # ARE the sealed blocks. The faithfulness of this reconstruction is
    # itself pinned by the replay-comparison test below, so it cannot
    # silently drift from what seal_block really does.
    # Mirrors the REAL seal path (`Surface.render_block_lines/3` + the
    # doctrine margin): content renders at width - 2 and every line
    # carries the 1-column left margin. The blank separator rows the
    # seal path emits between blocks are deliberately NOT reconstructed:
    # both sides of the ingress comparison reject blank lines, and the
    # fixed-point guard has nothing to check on an empty row.
    defp seal_ingress_binaries(model) do
      content_width = model.width - 2

      for block <- model.projection.blocks do
        block
        |> BlockBody.render(%{
          width: content_width,
          # Mirrors Surface.render_block_lines/3's absence-row
          # suppression flag (V ruling; policy seat
          # Block.completion_rows/3) -- the reconstruction must render
          # under the same policy the real seal path did.
          turn_has_tools?: reconstructed_turn_has_tools?(block, model)
        })
        |> ViewText.lines(content_width, :styled)
        |> decorate_lines(block)
        |> Enum.map(&[&1, "\r\n"])
        |> IO.iodata_to_binary()
      end
    end

    # Mirrors `Surface.sealed_history_lines/4`'s margin/chevron seam: an
    # EXPANDED user :message block is the prompt echo (`❯ ` first line,
    # 2-space hang on the rest -- plain prefixes here; the real sigil's
    # bold SGR is orthogonal to both the fixed-point and the plain-text
    # anti-drift comparison), everything else takes the 1-column margin.
    defp decorate_lines(lines, %Block{kind: :message, fold: :expanded} = block) do
      if Block.role(block) == :user do
        case lines do
          [] -> []
          [first | rest] -> ["❯ " <> first | Enum.map(rest, &("  " <> &1))]
        end
      else
        Enum.map(lines, &(" " <> &1))
      end
    end

    defp decorate_lines(lines, _block), do: Enum.map(lines, &(" " <> &1))

    # An INDEPENDENT re-derivation of the Surface's window fact (same
    # referent -- the block's own turn's events -- computed here from
    # scratch so the reconstruction never just echoes the module under
    # test).
    defp reconstructed_turn_has_tools?(block, model) do
      events = model.projection.source_events
      refs = MapSet.new(block.event_refs || [])

      turn_id =
        Enum.find_value(events, fn event ->
          if MapSet.member?(refs, Map.get(event, :id)),
            do: Map.get(event, :turn_id)
        end)

      turn_id == nil or
        Enum.any?(events, fn event ->
          payload = Map.get(event, :payload)

          Map.get(event, :turn_id) == turn_id and is_map(payload) and
            (Map.get(payload, "item_type") || Map.get(payload, :item_type)) in [
              "tool_use",
              "tool_result"
            ]
        end)
    end

    defp plain_lines(styled_binary) do
      styled_binary
      |> String.split("\r\n", trim: false)
      |> Enum.map(fn line ->
        line
        |> SequenceScanner.scan()
        |> Enum.filter(&match?({:text, _}, &1))
        |> Enum.map_join("", fn {:text, text} -> text end)
        |> String.trim_trailing()
      end)
    end

    defp row_text(row_cells) do
      row_cells
      |> Enum.map_join("", &(&1.char || " "))
      |> String.trim_trailing()
    end

    test "content handed to InlineAuthority.seal/2 is a ContentGuard fixed point (nothing would be stripped)" do
      # NOT "zero ESC bytes": sealed styled content LEGITIMATELY carries
      # SGR (`\e[2m...\e[0m` block headers -- allowlisted by
      # ContentGuard's grammar). The enforceable invariant is that
      # sanitization is the IDENTITY on outbound seal content: if
      # `sanitize_line/1` changes nothing, no ESC was ever going to be
      # stripped into ESC-less residue.
      for fixture <- Golden.fixtures(),
          mode <- [:inline_log, :tmux_conservative] do
        {model, _out} = drive_fixture(fixture, mode)
        binaries = seal_ingress_binaries(model)
        assert binaries != []

        for bin <- binaries do
          assert ContentGuard.sanitize_line(bin) == bin,
                 "#{fixture} x #{mode}: content handed to seal/2 is not a " <>
                   "ContentGuard fixed point -- something upstream embedded " <>
                   "a non-SGR escape that would be stripped to ESC-less " <>
                   "residue: #{inspect(bin, printable_limit: 200)}"
        end
      end
    end

    test "replayed sealed history matches the reconstructed ingress exactly (anti-drift: catches any re-embedded escape)" do
      # The fixed-point test above checks a RECONSTRUCTION of seal
      # ingress; this test pins that reconstruction to reality. Replay
      # the actual emitted bytes through the seal oracle's emulator and
      # compare history row text against the plain-text projection of
      # the reconstructed ingress: any divergence between what
      # seal_block/2 really emitted and what we reconstructed -- e.g. a
      # re-embedded \e[K stripped to a literal "[K" row prefix, the
      # exact regression class the narrowed residue guard cannot see --
      # shows up as a row mismatch here. (Red-proven by temporarily
      # re-embedding \e[K in seal_block/2: this assertion trips while
      # the fixed-point one stays green.)
      for fixture <- Golden.fixtures() do
        {model, out} = drive_fixture(fixture, :inline_log)

        expected_lines =
          model
          |> seal_ingress_binaries()
          |> Enum.flat_map(&plain_lines/1)
          |> Enum.reject(&(&1 == ""))

        emulator = SealOracle.replay(out, width: @width, height: @rows)

        history_lines =
          emulator
          |> SealOracle.history(@region_top)
          |> Enum.map(&row_text/1)
          |> Enum.reject(&(&1 == ""))

        assert history_lines == expected_lines,
               "#{fixture} x inline_log: replayed sealed history diverges " <>
                 "from the reconstructed seal ingress -- the seal path " <>
                 "emitted something (residue, reordering, loss) the " <>
                 "ingress reconstruction does not contain"
      end
    end
  end

  # ---------------------------------------------------------------------
  # (d) guard falsifiability: prove each guard above CAN actually fail,
  #     independent of what today's golden content happens to contain
  # ---------------------------------------------------------------------

  describe "guard falsifiability" do
    test "SealOracle.emits_full_clear?/1 detects an injected \\e[2J" do
      assert SealOracle.emits_full_clear?("x\e[2Jy")
      assert SealOracle.emits_full_clear?("x\e[3Jy")
      refute SealOracle.emits_full_clear?("no clears here")
    end

    test "the flat zero-escape guard fails on a string containing an ESC byte" do
      corrupted = "plain text\e[31mred text"

      refute Enum.all?(
               SequenceScanner.scan(corrupted),
               &match?({:text, _}, &1)
             ),
             "a corrupted flat stream with an embedded ESC must fail the " <>
               "all-tokens-are-text guard"

      assert corrupted =~ <<0x1B>>
    end

    test "an injected OSC 52 (clipboard) sequence produces an {:osc, _} token -- the allowlist guard would catch it" do
      poisoned = "x\e]52;c;aGVsbG8=\a y"

      assert Enum.any?(SequenceScanner.scan(poisoned), &match?({:osc, _}, &1)),
             "an injected OSC 52 sequence must scan as an {:osc, _} token so " <>
               "the sequence-vocabulary allowlist guard rejects it"
    end

    test "the ESC-less residue guard detects parameterized stripped-sequence remnants but never bracket labels" do
      # UNAMBIGUOUS residue -- `[` + a parameter run + a final letter is
      # not a shape prose produces; every one of these must trip:
      assert escless_residue("[1;14r positioned") != []
      assert escless_residue("half [2J cleared") != []
      assert escless_residue("moved [12;24H mid-line") != []

      # Bracket labels -- lowercase AND uppercase -- are ordinary
      # agent/LLM output and must never block a legitimate bless:
      assert escless_residue("[assistant]\r\nHello!\r\n") == []
      assert escless_residue("[reasoning] thinking...") == []
      assert escless_residue("[ERROR] build failed") == []
      assert escless_residue("[DONE] all tests passed") == []
      assert escless_residue("[KEY] press any") == []
      assert escless_residue("[Kernel panic] not syncing") == []
      assert escless_residue("[200 OK] response received") == []
      assert escless_residue("[1080p] stream quality") == []

      # Documented residual FALSE POSITIVES, pinned deliberately: short
      # digit-leading labels are shape-identical to real residue after
      # ESC-strip, so the regex cannot clear them. If one of these
      # assertions ever starts failing, the guard got wider or narrower
      # -- either way review `@escless_residue`'s comment before
      # touching the fixtures.
      assert escless_residue("[4K] video output") != []
      assert escless_residue("[2FA] enabled") != []

      # Documented false negative, accepted by design: a PARAMLESS
      # stripped final (`\e[K` -> `[K`, likewise `[P`/`[L`/`[M`) is
      # byte-identical to the start of an uppercase bracket label after
      # ContentGuard's neutralization, so no text-side regex can tell
      # them apart. That class is owned upstream by the ContentGuard/
      # seal seam (content must simply never carry escapes -- the
      # Surface.seal_block/2 fix), not by this tripwire.
      assert escless_residue("prefix [Ksuffix\r\n") == []
    end
  end

  # ---------------------------------------------------------------------
  # (e) drift tripwire: the in-suite mirror of `mix raxol.harness.goldens.bless
  #     --check` (same spirit as test/harness/tf_fixture_test.exs's own
  #     ".blocks.json is current" drift check)
  # ---------------------------------------------------------------------

  describe "drift tripwire" do
    test "the full fixtures x modes matrix is current against its checked-in goldens" do
      assert {:ok, _results} = Golden.run(check: true)
    end
  end

  # ---------------------------------------------------------------------
  # (f) bounded drive_to_completion: the step-budgeted replacement for the
  #     former unbounded recursion (see Golden's moduledoc / the raise
  #     path's own doc for why this must be loud rather than a silent
  #     hang in CI/bless).
  # ---------------------------------------------------------------------

  describe "bounded drive_to_completion" do
    test "max_steps/1 derives the documented budget (2 * event_count + 32)" do
      assert Golden.max_steps(10) == 52
      assert Golden.max_steps(0) == 32
    end

    test "a non-converging advance_fun raises instead of hanging forever" do
      non_converging = fn model -> {model, :ok} end

      assert_raise RuntimeError, ~r/never returned :done within 5 steps/, fn ->
        Golden.drive_to_completion(:whatever_model, non_converging, 5)
      end
    end

    test "an advance_fun that converges within budget returns the final model" do
      # returns :done on the 3rd call -- well within a 5-step budget.
      countdown = fn
        n when n >= 2 -> {n + 1, :done}
        n -> {n + 1, :ok}
      end

      assert Golden.drive_to_completion(0, countdown, 5) == 3
    end
  end

  # ---------------------------------------------------------------------
  # (g) escape_lines/1: the pure formatter behind the reviewable textual
  #     sidecar bless writes next to every byte golden.
  # ---------------------------------------------------------------------

  describe "escape_lines/1" do
    @round_trip_samples [
      "",
      "\n",
      "hello\n",
      "\e[2Jworld",
      <<0, 1, 2, 255, 254>>,
      "line1\nline2\n\nline4",
      "no trailing newline",
      "a\r\nb\r\nc"
    ]

    test "round-trips: concatenating the unescaped chunks reproduces the original binary" do
      for sample <- @round_trip_samples do
        escaped = Golden.escape_lines(sample)
        assert String.ends_with?(escaped, "\n")

        body = String.slice(escaped, 0, byte_size(escaped) - 1)
        lines = if body == "", do: [], else: String.split(body, "\n")

        rebuilt =
          Enum.map_join(lines, "", fn line ->
            {value, _bindings} = Code.eval_string(line)
            value
          end)

        assert rebuilt == sample
      end
    end

    test "escapes ESC (\\e) visibly rather than emitting a raw control byte" do
      escaped = Golden.escape_lines("\e[2J")
      assert escaped =~ "\\e"
      refute escaped =~ <<0x1B>>
    end

    test "output is deterministic across calls" do
      sample = "\e[H\e[Kfoo\nbar\e7baz"
      assert Golden.escape_lines(sample) == Golden.escape_lines(sample)
    end

    test "a known input produces the documented literal escaped form" do
      assert Golden.escape_lines("ab\n") ==
               inspect("ab\n", limit: :infinity, printable_limit: :infinity) <>
                 "\n"
    end

    test "empty binary produces zero escaped lines, just the trailing newline" do
      assert Golden.escape_lines("") == "\n"
    end
  end

  # ---------------------------------------------------------------------
  # (h) explicit file-read error handling in bless (Fix 4): a directory
  #     occupying a golden's path must raise a read-diagnosis error, not
  #     be silently treated as "absent" and masked by a failed write.
  # ---------------------------------------------------------------------

  describe "bless :dir option + explicit file-read error handling" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "golden-bless-test-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "a directory occupying a golden's path raises a read-diagnosis error",
         %{dir: dir} do
      fixture = List.first(Golden.fixtures())
      mode = List.first(Golden.modes())
      path = Path.join(dir, "#{fixture}.#{mode}.golden")
      # occupy the golden's own path with a directory instead of a file --
      # `File.read/1` on it returns `{:error, :eisdir}`.
      File.mkdir_p!(path)

      assert_raise RuntimeError, ~r/failed to read golden.*eisdir/s, fn ->
        Golden.run(dir: dir)
      end
    end
  end

  defp read_golden!(fixture, mode) do
    path = Golden.golden_path(fixture, mode)

    case File.read(path) do
      {:ok, bytes} ->
        bytes

      {:error, _reason} ->
        flunk(
          "golden missing at #{path} -- run `mix raxol.harness.goldens.bless`"
        )
    end
  end
end
