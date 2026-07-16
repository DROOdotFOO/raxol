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

  alias Raxol.Harness.Surface.{Golden, GoldenDiff}
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Test.CrossTerminal.SequenceScanner

  # Sequence-vocabulary allowlist for `:inline_log`/`:tmux_conservative`
  # goldens -- the substrate's measured full vocabulary for those tiers:
  # CUP (`H`), EL (`K`), SGR (`m`), DECSTBM (`r`) from `InlineAuthority` /
  # `ScrollRegionManager`, plus DECSC/DECRC (`\e7`/`\e8`) save/restore-
  # cursor. A failure against these lists means either a poisoned golden
  # (something emitted a sequence outside this vocabulary, e.g. OSC 52
  # clipboard exfiltration) or a deliberate vocabulary extension that must
  # be reviewed and added here consciously.
  @allowed_csi_finals ~w(H K m r)
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

        for {:csi, _params, final} <- tokens do
          assert final in @allowed_csi_finals,
                 "#{fixture} x #{mode} golden contains a CSI sequence with " <>
                   "final #{inspect(final)}, outside the allowlist #{inspect(@allowed_csi_finals)}"
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

  # Text tokens of `raw` that carry UNAMBIGUOUS stripped-CSI residue:
  # `[` followed by a numeric parameter run and a final letter (`[2J`,
  # `[1;14r`, `[12;24H`) -- a shape prose never produces. Deliberately
  # NO empty-param branch: after `ContentGuard.sanitize_line/1` strips
  # the ESC, a paramless final (`\e[K` -> `[K`, likewise `[P`/`[L`/`[M`)
  # is byte-identical to the first two characters of an ordinary
  # uppercase bracket label (`[KEY]`, `[ERROR]`, `[DONE]` -- all
  # plausible agent output), so any fixed letter set either misses
  # paramless editors or false-positives on labels and blocks a
  # legitimate bless. That paramless class is owned upstream, at the
  # ContentGuard/seal seam (content handed to `InlineAuthority.seal/2`
  # must simply never carry escape sequences -- the `Surface.seal_block/2`
  # fix); this tripwire pins only the residue that is provably not text.
  @escless_residue ~r/\[\d{1,3}(?:;\d{1,3})*[A-Za-z]/
  defp escless_residue(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _}, &1))
    |> Enum.map(fn {:text, text} -> text end)
    |> Enum.filter(&Regex.match?(@escless_residue, &1))
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
