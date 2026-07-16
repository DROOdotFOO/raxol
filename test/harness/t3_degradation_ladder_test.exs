defmodule Raxol.Harness.T3DegradationLadderTest do
  @moduledoc """
  Acceptance suite for the degradation ladder: mode pick at startup (caps
  + env override -> `:inline_log` | `:tmux_conservative` | `:flat`); the
  same fixture renders a correct linear transcript with `TERM=dumb`; flat
  output contains no cursor-move/CUP/scroll sequences (mechanical
  assert); tmux env picks the conservative tier.

  Four groups:

    1. Mode-pick matrix — table + property coverage of
       `ModeSelect.select/3` over caps x env x geometry combinations.
    2. THE mechanical flat assert — a representative fixture driven
       through `FlatAuthority` contains zero escape-sequence tokens.
    3. A deliberately-wrong flat writer (one CUP) is caught by the same
       mechanical assert; the real `FlatAuthority` passes the identical
       fixture cleanly.
    4. Same-fixture parity — `InlineAuthority` and `FlatAuthority`, driven
       with the same fixture, agree on LINE CONTENT (styling/positioning
       aside).
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Terminal.Capabilities
  alias Raxol.Test.CrossTerminal.SequenceScanner

  alias Raxol.UI.Rendering.PaintAuthority.{
    FlatAuthority,
    InlineAuthority,
    ModeSelect
  }

  # ---------------------------------------------------------------------
  # A deliberately-wrong flat writer: same shape as
  # `Raxol.Harness.Test.BuggyAuthority` but scoped to this unit, since
  # BuggyAuthority's existing streams are all footer/history shaped, not
  # "a flat writer that shouldn't move the cursor at all."
  # ---------------------------------------------------------------------
  defmodule BuggyFlatAuthority do
    @moduledoc """
    Emits one CUP (`\\e[1;1H`) before every append -- exactly the shape a
    broken "let's just reposition to be safe" patch to `FlatAuthority`
    might introduce. Proves the mechanical zero-escape assert
    (`flat_is_pure_text?/1` below) actually catches an escape sequence
    instead of rubber-stamping every input.
    """
    @behaviour Raxol.UI.Rendering.PaintAuthority

    @enforce_keys [:device]
    defstruct [:device]

    @type t :: %__MODULE__{device: IO.device()}

    @impl true
    def append_sealed(%__MODULE__{device: device} = t, iodata) do
      IO.write(device, "\e[1;1H")
      IO.write(device, iodata)
      t
    end

    @impl true
    def repaint_footer(t, _iodata), do: t
    @impl true
    def keyframe_footer(t, _iodata), do: t
    @impl true
    def with_cursor(t, _region, fun), do: fun.(t)
    @impl true
    def resize(t, _width, _height), do: t
    @impl true
    def region_top(_t), do: 1
  end

  # -- shared harness helpers ------------------------------------------

  @width 40
  @height 10
  @footer_rows 2

  # A representative session: a mix of plain lines, a multi-line "tool
  # call" block, and unicode content -- close enough to the shape the
  # block builder's journal-fold projection will eventually hand this
  # unit (a list of sealed blocks, each a list of plain text lines with
  # NO terminator baked in yet) without depending on the block builder's
  # JSONL fixtures, which are journal-envelope shaped, not render-byte
  # shaped (bridging the two is the assembled harness's job, not this
  # unit's).
  @fixture_blocks [
    ["assistant: analyzing the request..."],
    ["tool_call: ls -la", "  total 24", "  drwxr-xr-x  5 raxol staff  160 ."],
    ["assistant: found 3 files, café résumé naïve — done."]
  ]

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  # Every scanned token is `{:text, _}` -- the mechanical "zero escape
  # bytes anywhere" assert `FlatAuthority`'s moduledoc commits to. Reuses
  # the project's existing ANSI tokenizer (CLAUDE.md: reuse
  # `raxol_terminal`'s parser as the test oracle, never hand-roll one)
  # rather than a bespoke `\e[` regex.
  defp flat_is_pure_text?(raw) when is_binary(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.all?(&match?({:text, _text}, &1))
  end

  # ---------------------------------------------------------------------
  # 1. Mode-pick matrix
  # ---------------------------------------------------------------------

  describe "ModeSelect.select/3: mode-pick matrix" do
    test "table: caps x env x geometry combinations pick the documented mode" do
      tmux_caps = %Capabilities{multiplexer: :tmux}
      no_caps = nil

      table = [
        # {description, caps, env, opts, expected}
        {"plain xterm, no signals -> inline_log", no_caps,
         %{"TERM" => "xterm-256color"}, [], :inline_log},
        {"TERM=dumb -> flat", no_caps, %{"TERM" => "dumb"}, [], :flat},
        {"non-tty (tty?: false) -> flat", no_caps,
         %{"TERM" => "xterm-256color", :tty? => false}, [], :flat},
        {"CI=true WITHOUT tty -> flat", no_caps,
         %{"CI" => "true", :tty? => false}, [], :flat},
        {"CI=true WITH tty -> inline_log (CI alone is not enough)", no_caps,
         %{"CI" => "true", :tty? => true, "TERM" => "xterm-256color"}, [],
         :inline_log},
        {"TMUX var set -> tmux_conservative", no_caps,
         %{
           "TMUX" => "/tmp/tmux-1000/default,1234,0",
           "TERM" => "tmux-256color"
         }, [], :tmux_conservative},
        {"TERM starts with screen, no TMUX var -> tmux_conservative", no_caps,
         %{"TERM" => "screen-256color"}, [], :tmux_conservative},
        {"caps.multiplexer == :tmux, no env hints -> tmux_conservative",
         tmux_caps, %{"TERM" => "xterm-256color"}, [], :tmux_conservative},
        {"degenerate geometry, no other signals -> flat", no_caps,
         %{"TERM" => "xterm-256color"}, [rows: 2, footer_rows: 2], :flat},
        {"adequate geometry -> inline_log", no_caps,
         %{"TERM" => "xterm-256color"}, [rows: 40, footer_rows: 2],
         :inline_log},
        {"geometry unknown (:rows omitted) -> treated as non-degenerate",
         no_caps, %{"TERM" => "xterm-256color"}, [footer_rows: 2], :inline_log},
        {"footer_rows: -1 (invalid) is guarded, fails open to non-degenerate rather than raising",
         no_caps, %{"TERM" => "xterm-256color"}, [rows: 2, footer_rows: -1],
         :inline_log},
        {"tmux AND degenerate geometry -> flat (see moduledoc: 'Why the degenerate floor applies after override resolution')",
         no_caps,
         %{
           "TMUX" => "/tmp/tmux-1000/default,1234,0",
           "TERM" => "tmux-256color"
         }, [rows: 2, footer_rows: 2], :flat},
        {"override=flat wins over an otherwise-plain terminal", no_caps,
         %{"RAXOL_HARNESS_MODE" => "flat", "TERM" => "xterm-256color"}, [],
         :flat},
        {"override=tmux wins over TERM=dumb (no geometry given -> no floor to apply)",
         no_caps, %{"RAXOL_HARNESS_MODE" => "tmux", "TERM" => "dumb"}, [],
         :tmux_conservative},
        {"override=inline at degenerate geometry is floored to :flat",
         no_caps, %{"RAXOL_HARNESS_MODE" => "inline", "TERM" => "dumb"},
         [rows: 2, footer_rows: 2], :flat},
        {"override=tmux at degenerate geometry is floored to :flat too",
         no_caps, %{"RAXOL_HARNESS_MODE" => "tmux", "TERM" => "xterm-256color"},
         [rows: 2, footer_rows: 2], :flat},
        {"override=flat at degenerate geometry is honored (already :flat, floor is a no-op)",
         no_caps, %{"RAXOL_HARNESS_MODE" => "flat", "TERM" => "xterm-256color"},
         [rows: 2, footer_rows: 2], :flat},
        {"override=inline wins over a detected tmux session (no geometry given -> no floor to apply)",
         tmux_caps, %{"RAXOL_HARNESS_MODE" => "inline", "TMUX" => "x"}, [],
         :inline_log},
        {"unrecognized override value falls through to auto-detect", no_caps,
         %{"RAXOL_HARNESS_MODE" => "bogus", "TERM" => "xterm-256color"}, [],
         :inline_log},
        {"override value is trimmed and downcased", no_caps,
         %{"RAXOL_HARNESS_MODE" => " Flat "}, [], :flat}
      ]

      for {description, caps, env, opts, expected} <- table do
        assert ModeSelect.select(caps, env, opts) == expected, description
      end
    end

    test "regression: tmux + degenerate geometry (rows=2, footer_rows=2) -> :flat, not :tmux_conservative" do
      # See ModeSelect's moduledoc ("Why the degenerate floor applies
      # after override resolution") for the byte-traced clobber this
      # pins against. Kept as a named test, independent of the table
      # above, so this corner can never silently regress.
      env_var_tmux = %{
        "TMUX" => "/tmp/tmux-1000/default,1234,0",
        "TERM" => "tmux-256color"
      }

      caps_multiplexer_tmux = %Capabilities{multiplexer: :tmux}

      assert ModeSelect.select(nil, env_var_tmux, rows: 2, footer_rows: 2) ==
               :flat

      assert ModeSelect.select(
               caps_multiplexer_tmux,
               %{"TERM" => "xterm-256color"},
               rows: 2,
               footer_rows: 2
             ) == :flat
    end

    property "explicit override wins over every other signal, UNLESS the degenerate floor clamps it to :flat" do
      # `rows <- integer(1..3)` with `footer_rows: 2` fixed is ALWAYS
      # degenerate (region_top = max(rows - 2, 1) = 1 < 2 for every value
      # in that range), so whenever geometry is given at all in this
      # property, the floor clamps any non-:flat override down to :flat.
      # Before this was fixed, this property asserted the override won
      # unconditionally even at that geometry -- exactly the clobber bug
      # fixed here (see ModeSelect's moduledoc).
      check all(
              term <-
                member_of(["dumb", "xterm-256color", "screen", "tmux-256color"]),
              tmux_var <- member_of([nil, "", "/tmp/tmux-1000/default,1234,0"]),
              ci <- member_of([nil, "true", "false"]),
              tty? <- boolean(),
              multiplexer <- member_of([:none, :tmux, :screen]),
              rows <- one_of([constant(nil), integer(1..3)]),
              override_mode <- member_of(["flat", "tmux", "inline"]),
              max_runs: 50
            ) do
        env =
          %{
            "TERM" => term,
            "CI" => ci,
            :tty? => tty?,
            "RAXOL_HARNESS_MODE" => override_mode
          }
          |> maybe_put_tmux(tmux_var)

        caps = %Capabilities{multiplexer: multiplexer}
        opts = if rows, do: [rows: rows, footer_rows: 2], else: []

        override_expected =
          case override_mode do
            "flat" -> :flat
            "tmux" -> :tmux_conservative
            "inline" -> :inline_log
          end

        # `rows` present in this property is always degenerate (see the
        # comment above) -- the floor only ever pushes TOWARD :flat.
        expected =
          if rows && override_expected != :flat,
            do: :flat,
            else: override_expected

        assert ModeSelect.select(caps, env, opts) == expected
      end
    end

    property "with no override: headless always wins flat regardless of tmux/geometry signals" do
      check all(
              tmux_var <- member_of([nil, "/tmp/tmux-1000/default,1234,0"]),
              multiplexer <- member_of([:none, :tmux, :screen]),
              rows <- integer(1..40),
              max_runs: 30
            ) do
        env = %{"TERM" => "dumb"} |> maybe_put_tmux(tmux_var)
        caps = %Capabilities{multiplexer: multiplexer}
        opts = [rows: rows, footer_rows: 2]

        assert ModeSelect.select(caps, env, opts) == :flat
      end
    end

    defp maybe_put_tmux(env, nil), do: env
    defp maybe_put_tmux(env, ""), do: env
    defp maybe_put_tmux(env, value), do: Map.put(env, "TMUX", value)
  end

  # ---------------------------------------------------------------------
  # 1b. Override-outranks-degenerate floor
  # ---------------------------------------------------------------------

  describe "ModeSelect.select_with_reason/3: override-outranks-degenerate floor" do
    test "override=inline at degenerate geometry clamps to :flat, not :inline_log" do
      # Before this was fixed, `select/3` returned the override mode
      # unconditionally (`override(env)` short-circuited before the
      # degenerate check ever ran), so this exact combination -- an
      # exported `RAXOL_HARNESS_MODE=inline` later run in a 2-row split --
      # returned `:inline_log` and reproduced the same byte-traced
      # row-1 clobber as the auto-detected tmux+degenerate regression
      # above. See ModeSelect's moduledoc for the full rationale.
      env = %{"RAXOL_HARNESS_MODE" => "inline", "TERM" => "xterm-256color"}

      assert ModeSelect.select(nil, env, rows: 2, footer_rows: 2) == :flat

      assert ModeSelect.select_with_reason(nil, env, rows: 2, footer_rows: 2) ==
               {:flat, :degenerate_clamp}
    end

    test "override=tmux at degenerate geometry also clamps to :flat" do
      env = %{"RAXOL_HARNESS_MODE" => "tmux", "TERM" => "xterm-256color"}

      assert ModeSelect.select_with_reason(nil, env, rows: 2, footer_rows: 2) ==
               {:flat, :degenerate_clamp}
    end

    test "override=flat at degenerate geometry is honored as-is (already :flat, floor is a no-op)" do
      env = %{"RAXOL_HARNESS_MODE" => "flat", "TERM" => "xterm-256color"}

      assert ModeSelect.select_with_reason(nil, env, rows: 2, footer_rows: 2) ==
               {:flat, :override}
    end

    test "override at ADEQUATE geometry is unaffected by the floor" do
      env = %{"RAXOL_HARNESS_MODE" => "inline", "TERM" => "xterm-256color"}

      assert ModeSelect.select_with_reason(nil, env, rows: 40, footer_rows: 2) ==
               {:inline_log, :override}
    end

    test "auto-detected reasons: :headless, :tmux, :default" do
      assert ModeSelect.select_with_reason(nil, %{"TERM" => "dumb"}, []) ==
               {:flat, :headless}

      assert ModeSelect.select_with_reason(
               nil,
               %{"TMUX" => "x", "TERM" => "tmux-256color"},
               []
             ) == {:tmux_conservative, :tmux}

      assert ModeSelect.select_with_reason(
               nil,
               %{"TERM" => "xterm-256color"},
               []
             ) ==
               {:inline_log, :default}
    end

    test "unrecognized override value falls through to auto-detect and surfaces :override_unrecognized" do
      env = %{"RAXOL_HARNESS_MODE" => "bogus", "TERM" => "xterm-256color"}

      assert ModeSelect.select_with_reason(nil, env, []) ==
               {:inline_log, :override_unrecognized}
    end

    test "override value is trimmed and downcased before matching" do
      assert ModeSelect.select(nil, %{"RAXOL_HARNESS_MODE" => "Flat"}, []) ==
               :flat

      assert ModeSelect.select(nil, %{"RAXOL_HARNESS_MODE" => " flat "}, []) ==
               :flat

      assert ModeSelect.select(nil, %{"RAXOL_HARNESS_MODE" => "TMUX"}, []) ==
               :tmux_conservative
    end
  end

  # ---------------------------------------------------------------------
  # 2. THE mechanical flat assert
  # ---------------------------------------------------------------------

  describe "FlatAuthority: the mechanical zero-escape assert" do
    test "TERM=dumb fixture, driven through FlatAuthority, contains zero cursor-move/CUP/scroll/escape sequences" do
      {:ok, device} = StringIO.open("")
      authority = FlatAuthority.new(device, @width, @height)

      _final =
        Enum.reduce(@fixture_blocks, authority, fn lines, auth ->
          FlatAuthority.seal(auth, flat_block(lines))
        end)

      output = raw(device)

      assert flat_is_pure_text?(output),
             "flat output must contain zero escape-sequence tokens, got: #{inspect(SequenceScanner.scan(output))}"

      # Linear-transcript correctness: the lines appear, in order, exactly
      # as sealed (append-only, no reordering, no loss).
      assert output ==
               Enum.map_join(@fixture_blocks, "", &flat_block/1)
    end

    test "resize and footer/keyframe calls on FlatAuthority write zero bytes" do
      {:ok, device} = StringIO.open("")
      authority = FlatAuthority.new(device, @width, @height)

      authority =
        authority
        |> FlatAuthority.seal("assistant: hello\n")
        |> FlatAuthority.repaint_footer("should not appear")
        |> FlatAuthority.keyframe_footer("should not appear either")
        |> FlatAuthority.resize(80, 24)

      assert FlatAuthority.region_top(authority) == 24
      assert raw(device) == "assistant: hello\n"
    end
  end

  describe "FlatAuthority: append_sealed/2 scrubs hostile escape bytes" do
    test "content carrying a CSI clear, an SGR color change, and a bare BEL is scrubbed to plain text" do
      {:ok, device} = StringIO.open("")
      authority = FlatAuthority.new(device, @width, @height)

      hostile = "before\e[2Jafter\e[31mred\adone\n"

      _final = FlatAuthority.seal(authority, hostile)

      output = raw(device)

      assert flat_is_pure_text?(output),
             "scrubbed output must contain zero escape-sequence tokens, got: #{inspect(SequenceScanner.scan(output))}"

      # Module-enforced, not caller-trusted (see moduledoc): the ESC lead
      # byte and the bare BEL are stripped, but the rest of each sequence's
      # bytes survive as a visible, garbled-looking fragment ("[2J",
      # "[31m") rather than being silently swallowed whole -- an HONEST
      # detectable failure, not an invisible injection.
      assert output == "before[2Jafter[31mreddone\n"
    end

    test "\\t, \\r, and \\n survive the scrub unchanged" do
      {:ok, device} = StringIO.open("")
      authority = FlatAuthority.new(device, @width, @height)

      _final = FlatAuthority.seal(authority, "a\tb\r\nc\n")

      assert raw(device) == "a\tb\r\nc\n"
    end

    test "multi-byte UTF-8 content is untouched by the byte-wise scrub" do
      {:ok, device} = StringIO.open("")
      authority = FlatAuthority.new(device, @width, @height)

      _final = FlatAuthority.seal(authority, "café résumé naïve\n")

      assert raw(device) == "café résumé naïve\n"
    end
  end

  # ---------------------------------------------------------------------
  # 3. The mechanical assert catches a real violation
  # ---------------------------------------------------------------------

  describe "the mechanical assert catches a real violation" do
    test "a flat writer that emits one CUP fails the assert; the real FlatAuthority passes the identical fixture" do
      {:ok, bad_device} = StringIO.open("")
      bad = %BuggyFlatAuthority{device: bad_device}

      Enum.each(@fixture_blocks, fn lines ->
        BuggyFlatAuthority.append_sealed(bad, flat_block(lines))
      end)

      bad_output = raw(bad_device)

      refute flat_is_pure_text?(bad_output),
             "the buggy authority's CUP must be caught by the mechanical assert"

      assert Enum.any?(
               SequenceScanner.scan(bad_output),
               &match?({:csi, _params, "H"}, &1)
             ),
             "the buggy stream should contain the injected CUP token"

      {:ok, good_device} = StringIO.open("")
      good = FlatAuthority.new(good_device, @width, @height)

      Enum.reduce(@fixture_blocks, good, fn lines, auth ->
        FlatAuthority.seal(auth, flat_block(lines))
      end)

      good_output = raw(good_device)

      assert flat_is_pure_text?(good_output),
             "the real FlatAuthority must never emit an escape sequence on the same fixture"
    end
  end

  # ---------------------------------------------------------------------
  # 4. Same-fixture parity: InlineAuthority vs FlatAuthority
  # ---------------------------------------------------------------------

  describe "same-fixture parity: InlineAuthority and FlatAuthority agree on line content" do
    test "the same transcript, different substrate: identical LINE CONTENT sequence" do
      {:ok, inline_device} = StringIO.open("")

      inline_authority =
        InlineAuthority.new(inline_device, @width, @height, @footer_rows,
          capabilities: nil
        )

      _final_inline =
        Enum.reduce(@fixture_blocks, inline_authority, fn lines, auth ->
          InlineAuthority.seal(auth, inline_block(lines))
        end)

      {:ok, flat_device} = StringIO.open("")
      flat_authority = FlatAuthority.new(flat_device, @width, @height)

      _final_flat =
        Enum.reduce(@fixture_blocks, flat_authority, fn lines, auth ->
          FlatAuthority.seal(auth, flat_block(lines))
        end)

      inline_lines = lines_from_raw(raw(inline_device))
      flat_lines = lines_from_raw(raw(flat_device))

      expected_lines = Enum.flat_map(@fixture_blocks, & &1)

      assert inline_lines == expected_lines
      assert flat_lines == expected_lines
      assert inline_lines == flat_lines
    end
  end

  # -- fixture-shaping helpers (test-local, not production contract) ---

  # InlineAuthority's real production contract: iodata already
  # `\r\n`-terminated per line (mirrors `renderer_seal_once_property_test.exs`'s
  # `block_gen/0` convention).
  defp inline_block(lines), do: Enum.map_join(lines, "", &(&1 <> "\r\n"))

  # FlatAuthority's documented convention: plain `\n`-terminated per line.
  defp flat_block(lines), do: Enum.map_join(lines, "", &(&1 <> "\n"))

  # Recovers the pure content-line sequence from a raw byte stream,
  # regardless of which authority produced it: scans out every escape
  # token (CUP, cursor save/restore, DECSTBM, ...) via the same tokenizer
  # `flat_is_pure_text?/1` uses, keeps only `{:text, _}` runs, then splits
  # on line terminators (normalizing `\r\n` to `\n` first so both
  # authorities' conventions compare equal).
  defp lines_from_raw(raw) do
    raw
    |> SequenceScanner.scan()
    |> Enum.filter(&match?({:text, _text}, &1))
    |> Enum.map_join("", fn {:text, text} -> text end)
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
    |> Enum.drop(-1)
  end
end
