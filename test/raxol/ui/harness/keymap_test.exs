defmodule Raxol.UI.Harness.KeymapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Driver.EventTranslator
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.Harness.Keymap

  # -- real-producer helpers (mirrors input_event_test.exs's approach: drive
  # the REAL T27 emitters, never hand-build a translator-/parser-shaped map) --

  @tb_escape 27
  @tb_tab 9

  defp translator_event(key_code, char_code, mod_code \\ 0) do
    {:ok, event} =
      EventTranslator.translate(%{
        type: :key,
        key: key_code,
        char: char_code,
        mod: mod_code
      })

    event
  end

  defp parser_event(binary) do
    [event] = InputParser.parse(binary)
    event
  end

  defp resolve_from(raw_event, context \\ %{}) do
    raw_event |> InputEvent.normalize() |> Keymap.resolve(context)
  end

  # -- 1. table test: each v1 bind, canonical event -> exactly its typed
  # command, driven through the real producers for every shape that can
  # represent it --

  describe "v1 binds -- table over real T27 producers" do
    test "ESC (translator shape) -> :interrupt" do
      assert resolve_from(translator_event(@tb_escape, 0)) ==
               %{type: :interrupt, payload: %{}}
    end

    test "ESC (ANSI parser shape) -> :interrupt" do
      assert resolve_from(parser_event(<<27>>)) ==
               %{type: :interrupt, payload: %{}}
    end

    test "ESC (Event.key_event/3 shape) -> :interrupt" do
      assert resolve_from(Event.key_event(:escape, :pressed, [])) ==
               %{type: :interrupt, payload: %{}}
    end

    test "Tab (translator shape) -> :steer" do
      assert resolve_from(translator_event(@tb_tab, 0)) ==
               %{type: :steer, payload: %{}}
    end

    test "Tab (ANSI parser shape) -> :steer" do
      assert resolve_from(parser_event(<<9>>)) == %{type: :steer, payload: %{}}
    end

    test "Tab (Event.key_event/3 shape) -> :steer" do
      assert resolve_from(Event.key_event(:tab, :pressed, [])) ==
               %{type: :steer, payload: %{}}
    end

    test "'z' (translator shape) -> :fold_toggle, not composing" do
      assert resolve_from(translator_event(0, ?z), %{composing?: false}) ==
               %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "'z' (ANSI parser shape) -> :fold_toggle, not composing" do
      assert resolve_from(parser_event("z"), %{composing?: false}) ==
               %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "'z' (Event.key_event/3 shape) -> :fold_toggle, carries focused_block_id" do
      assert resolve_from(Event.key_event("z", :pressed, []), %{
               composing?: false,
               focused_block_id: "blk-7"
             }) == %{type: :fold_toggle, payload: %{block_id: "blk-7"}}
    end

    test "'j' (translator shape) -> :jump_next, not composing" do
      assert resolve_from(translator_event(0, ?j), %{composing?: false}) ==
               %{type: :jump_next, payload: %{}}
    end

    test "'j' (ANSI parser shape) -> :jump_next, not composing" do
      assert resolve_from(parser_event("j"), %{composing?: false}) ==
               %{type: :jump_next, payload: %{}}
    end

    test "'k' (translator shape) -> :jump_prev, not composing" do
      assert resolve_from(translator_event(0, ?k), %{composing?: false}) ==
               %{type: :jump_prev, payload: %{}}
    end

    test "'k' (ANSI parser shape) -> :jump_prev, not composing" do
      assert resolve_from(parser_event("k"), %{composing?: false}) ==
               %{type: :jump_prev, payload: %{}}
    end

    test "Ctrl+E (ANSI parser shape, raw 0x05 byte) -> :edit_draft, even while composing" do
      assert resolve_from(parser_event(<<5>>), %{composing?: true}) ==
               %{type: :edit_draft, payload: %{}}
    end

    test "Ctrl+E (Event.key_event/3 shape) -> :edit_draft regardless of composing?" do
      for composing? <- [true, false] do
        assert resolve_from(Event.key_event("e", :pressed, [:ctrl]), %{
                 composing?: composing?
               }) == %{type: :edit_draft, payload: %{}}
      end
    end

    test "plain 'e' while composing stays :passthrough (ordinary character insertion)" do
      assert resolve_from(Event.key_event("e", :pressed, []), %{
               composing?: true
             }) == :passthrough
    end

    test "plain 'e' while NOT composing is :expand_diff (the full-screen diff expansion nav bind)" do
      assert resolve_from(Event.key_event("e", :pressed, []), %{
               composing?: false
             }) == %{type: :expand_diff, payload: %{block_id: nil}}
    end

    test "Ctrl+Alt+E -> :passthrough (chord binds require an EXACT mods match)" do
      assert resolve_from(Event.key_event("e", :pressed, [:ctrl, :alt]), %{
               composing?: true
             }) == :passthrough
    end

    test "an unbound key normalizes but resolves to :passthrough" do
      assert resolve_from(Event.key_event("q", :pressed, []), %{
               composing?: false
             }) == :passthrough
    end

    test "an unbound special key resolves to :passthrough" do
      assert resolve_from(Event.key_event(:up, :pressed, []), %{
               composing?: false
             }) == :passthrough
    end
  end

  # -- 2. ESC-during-streaming: the roadmap's named acceptance wording --

  describe "ESC during streaming" do
    test "ESC while streaming?: true still yields :interrupt, immediately, not buffered" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               streaming?: true,
               composing?: true
             }) == %{type: :interrupt, payload: %{}}
    end

    test "ESC while streaming?: false also yields :interrupt (harmless no-op downstream, never dropped)" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               streaming?: false
             }) == %{type: :interrupt, payload: %{}}
    end
  end

  # -- 3. composer-focus guard --

  describe "composer-focus guard" do
    test "'j'/'k'/'z' pass through while composing (no stolen keys)" do
      for char <- ["j", "k", "z"] do
        assert resolve_from(Event.key_event(char, :pressed, []), %{
                 composing?: true
               }) == :passthrough
      end
    end

    test "'j'/'k'/'z' resolve to their bind while not composing" do
      assert resolve_from(Event.key_event("j", :pressed, []), %{
               composing?: false
             }) == %{type: :jump_next, payload: %{}}

      assert resolve_from(Event.key_event("k", :pressed, []), %{
               composing?: false
             }) == %{type: :jump_prev, payload: %{}}

      assert resolve_from(Event.key_event("z", :pressed, []), %{
               composing?: false
             }) == %{type: :fold_toggle, payload: %{block_id: nil}}
    end

    test "composing?: unset defaults to the fail-safe (composing) behavior -- callers must opt in explicitly to guarded binds" do
      # Absence of :composing? in context must not accidentally let a
      # navigation bind fire and steal a keystroke -- Map.get(context,
      # :composing?, true) means "unset == composing", the fail-safe
      # default. Only an explicit composing?: false opts a caller INTO
      # guarded-bind resolution (e.g. a transcript-browsing mode that
      # deliberately declares it isn't composing).
      assert resolve_from(Event.key_event("j", :pressed, []), %{}) ==
               :passthrough
    end

    test "composing?: false explicitly opts in to guarded-bind resolution" do
      assert resolve_from(Event.key_event("j", :pressed, []), %{
               composing?: false
             }) == %{type: :jump_next, payload: %{}}
    end

    test "ESC and Tab are the explicit exceptions -- they fire even while composing?: true" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), %{
               composing?: true
             }) == %{type: :interrupt, payload: %{}}

      assert resolve_from(Event.key_event(:tab, :pressed, []), %{
               composing?: true
             }) == %{type: :steer, payload: %{}}
    end

    property "composing?: true always passes through printable characters, except the explicit exceptions" do
      check all(char <- StreamData.string(:alphanumeric, length: 1)) do
        result =
          resolve_from(Event.key_event(char, :pressed, []), %{
            composing?: true
          })

        assert result == :passthrough
      end
    end
  end

  # -- 4. invocation-parity seam (T15's palette) --

  describe "invocation parity" do
    test "command_types/0 is exactly the union binds/0 can ever emit" do
      # command_types/0 documents itself as "the exact set" -- a set, not a
      # dup-capable list -- so it uniqs internally now; no compensating
      # Enum.uniq/1 needed here.
      declared = Keymap.command_types() |> MapSet.new()

      emitted =
        Keymap.binds()
        |> Enum.map(fn bind ->
          norm = fixture_for(bind)
          context = context_for(bind)

          case Keymap.resolve(norm, context) do
            %{type: type} -> type
            :passthrough -> flunk("bind #{inspect(bind)} did not resolve")
          end
        end)
        |> MapSet.new()

      assert declared == emitted

      # Every bind still emits a declared type, but binds/0 is no longer
      # guaranteed 1:1 with command_types/0: :open_panel is intentionally
      # shared by three binds (the w/m/n panel binds), discriminated by
      # payload.panel rather than by a distinct command_type -- one
      # command type covers all three (see Keymap's moduledoc). The
      # residual gap between bind count and declared-type count is
      # exactly that: (open_panel bind count - 1).
      open_panel_binds =
        Enum.count(Keymap.binds(), &(&1.command_type == :open_panel))

      # The live-approval answer keys (Track D) are a second shared-type
      # family: `y`/`n`/`1`-`9` all emit `:approval_answer`, discriminated
      # by their `payload.answer` hint (same pattern as the panel binds
      # sharing `:open_panel`). Both families contribute (count - 1) to the
      # residual gap between bind count and distinct-command-type count.
      approval_answer_binds =
        Enum.count(Keymap.binds(), &(&1.command_type == :approval_answer))

      # A third shared-type family: `:scroll_to_tail` is emitted by BOTH
      # `End` and vim-style `G` (see the full-viewport scrollback binds),
      # so it contributes its own (count - 1) to the residual gap, exactly
      # like the panel and approval families above.
      scroll_to_tail_binds =
        Enum.count(Keymap.binds(), &(&1.command_type == :scroll_to_tail))

      assert length(Keymap.binds()) ==
               MapSet.size(declared) + (open_panel_binds - 1) +
                 (approval_answer_binds - 1) + (scroll_to_tail_binds - 1)
    end

    # The `guard: :overlay` bind's own context requirement differs from
    # every other bind's -- see `Keymap`'s moduledoc, "overlay-open ESC
    # capture": it only resolves when the caller explicitly opts in with
    # `overlay_open?: true`. Every other bind's context is unaffected by
    # that flag, so this only special-cases the one guard that needs it;
    # the resulting resolved set (and its size against `binds/0`) is
    # unchanged by driving each bind's own natural context here.
    defp context_for(%{guard: :overlay}),
      do: %{composing?: false, focused_block_id: "any", overlay_open?: true}

    # The live-approval answer guard opts in with `approval_pending?: true`
    # (Track D) -- its own natural context, same shape the surface builds
    # while a question is on screen. Without it these binds correctly stay
    # `:passthrough`, exactly like the `:overlay` bind above needs its own.
    defp context_for(%{guard: :awaiting_approval}),
      do: %{
        composing?: false,
        focused_block_id: "any",
        approval_pending?: true,
        composer_empty?: true
      }

    defp context_for(_bind), do: %{composing?: false, focused_block_id: "any"}

    defp fixture_for(%{key: key}),
      do: InputEvent.normalize(Event.key_event(key, :pressed, []))

    # A char-kind CHORD bind (declared `mods:`) needs its modifiers in the
    # fixture event, else the exact-mods match correctly rejects it.
    defp fixture_for(%{char: char, mods: mods}) do
      modifiers = for {mod, true} <- mods, do: mod
      InputEvent.normalize(Event.key_event(char, :pressed, modifiers))
    end

    defp fixture_for(%{char: char}),
      do: InputEvent.normalize(Event.key_event(char, :pressed, []))
  end

  # -- overlay-open ESC capture (the overlay picker's focus context) --
  #
  # An open overlay picker enters the keymap's context as
  # `overlay_open?: true`. ESC must then resolve to `:overlay_dismiss`
  # (close the overlay) BEFORE the global `:always` ESC-interrupt bind --
  # first-match-wins over the data table, no second dispatch mechanism.
  # The fail-safe direction mirrors `composing?`'s: a caller that never
  # sets `overlay_open?` gets the old behavior (ESC = interrupt),
  # so nothing load-bearing changes for existing callers.

  describe "overlay-open ESC capture" do
    test "ESC with overlay_open?: true -> :overlay_dismiss, not :interrupt" do
      assert resolve_from(translator_event(@tb_escape, 0), %{
               overlay_open?: true
             }) ==
               %{type: :overlay_dismiss, payload: %{}}
    end

    test "ESC with overlay_open?: true resolves :overlay_dismiss regardless of composing?/streaming?" do
      for composing? <- [true, false], streaming? <- [true, false] do
        context = %{
          overlay_open?: true,
          composing?: composing?,
          streaming?: streaming?
        }

        assert resolve_from(parser_event("\e"), context) ==
                 %{type: :overlay_dismiss, payload: %{}},
               "context #{inspect(context)} must dismiss, not interrupt"
      end
    end

    test "ESC with overlay_open?: false -> :interrupt (unchanged)" do
      assert resolve_from(parser_event("\e"), %{overlay_open?: false}) ==
               %{type: :interrupt, payload: %{}}
    end

    test "overlay_open?: unset defaults to the fail-safe (closed) reading -- ESC stays :interrupt" do
      assert resolve_from(parser_event("\e"), %{composing?: true}) ==
               %{type: :interrupt, payload: %{}}
    end

    test "only ESC gains an overlay meaning in the table -- printable chars and Enter stay :passthrough with the overlay open (the Surface routes them)" do
      # BOTH composing states: an overlay opened from transcript-browse
      # mode (composing?: false -- the natural open path for a jump /
      # search picker) must not lose keystrokes to the :not_composing
      # binds. The original version of this test pinned composing?: true
      # and probed only the unbound "a", which masked exactly that
      # desync (adversarial review, CRITICAL).
      for composing? <- [true, false] do
        context = %{overlay_open?: true, composing?: composing?}

        assert resolve_from(Event.key("a"), context) == :passthrough
        assert resolve_from(Event.key(:enter), context) == :passthrough
        assert resolve_from(Event.key(:up), context) == :passthrough
        assert resolve_from(Event.key(:down), context) == :passthrough
        assert resolve_from(Event.key(:backspace), context) == :passthrough
      end
    end

    test "z/j/k with the overlay open are FILTER TEXT, never fold/jump commands -- even from transcript-browse mode (composing?: false)" do
      # The regression the adversarial review named: z/j/k are
      # :not_composing-guarded binds, and a guard that consults only
      # composing? fires them straight past the open overlay --
      # dropped from the filter query AND mutating fold/jump state
      # behind the picker. j/k are common search letters; the picker's
      # PRIMARY open path (from transcript browsing) must keep them.
      context = %{overlay_open?: true, composing?: false}

      for char <- ["z", "j", "k"] do
        assert resolve_from(Event.key(char), context) == :passthrough,
               "#{inspect(char)} must pass through to the overlay filter, " <>
                 "not resolve to a transcript command behind it"
      end
    end

    test "command_types/0 includes :overlay_dismiss" do
      assert :overlay_dismiss in Keymap.command_types()
    end
  end

  # -- panel binds (w/m/n -- worktracks/memory/plan projection panels) ----

  describe "panel binds (w/m/n)" do
    @panel_chars [{"w", :worktracks}, {"m", :memory}, {"n", :plan}]

    test "resolve to :open_panel with the discriminating payload, not composing, no overlay" do
      for {char, kind} <- @panel_chars do
        assert resolve_from(Event.key(char), %{
                 composing?: false,
                 overlay_open?: false
               }) == %{type: :open_panel, payload: %{panel: kind}}
      end
    end

    test "pass through while composing" do
      for {char, _kind} <- @panel_chars do
        assert resolve_from(Event.key(char), %{composing?: true}) ==
                 :passthrough
      end
    end

    test "pass through while an overlay is open, even from transcript-browse mode" do
      for {char, _kind} <- @panel_chars do
        assert resolve_from(Event.key(char), %{
                 composing?: false,
                 overlay_open?: true
               }) == :passthrough
      end
    end

    test "pass through under ctrl/alt/meta (not a bare printable keypress)" do
      for {char, _kind} <- @panel_chars,
          mod <- [:ctrl, :alt, :meta] do
        assert resolve_from(Event.key_event(char, :pressed, [mod]), %{
                 composing?: false
               }) == :passthrough
      end
    end

    test "command_types/0 includes :open_panel" do
      assert :open_panel in Keymap.command_types()
    end

    test "the three panel binds appear in palette_binds/0 with their labels" do
      labels =
        Keymap.palette_binds() |> Enum.map(& &1.label) |> MapSet.new()

      assert "worktracks panel" in labels
      assert "memory panel" in labels
      assert "plan panel" in labels
    end

    test "command_for/2 yields the same payload-carrying command as a live keypress (palette invocation parity)" do
      for {char, kind} <- @panel_chars do
        # Filter by command_type too: the live-approval answer binds (Track
        # D) share `n` with the plan-panel bind (an answer while a question
        # is live wins; see Keymap's `@approval_binds` ordering note), so a
        # bare char lookup would find the approval bind first. This parity
        # check is about the PANEL bind specifically.
        bind =
          Enum.find(
            Keymap.binds(),
            &(Map.get(&1, :char) == char and &1.command_type == :open_panel)
          )

        assert bind.command_type == :open_panel

        assert Keymap.command_for(bind, %{composing?: false}) ==
                 %{type: :open_panel, payload: %{panel: kind}}
      end
    end
  end

  # -- the full guard x context matrix ----------------------------------
  #
  # Every bind resolved against every {composing?, overlay_open?}
  # combination (including each flag absent), so no guard/context pair
  # can go untested again -- the CRITICAL routing desync above survived
  # precisely because the overlay tests only ever pinned one corner of
  # this matrix.

  describe "guard x context matrix" do
    # overlay_open? values: true / false / :absent; composing? likewise.
    defp matrix_context(composing?, overlay_open?) do
      %{}
      |> put_flag(:composing?, composing?)
      |> put_flag(:overlay_open?, overlay_open?)
    end

    defp put_flag(context, _key, :absent), do: context
    defp put_flag(context, key, value), do: Map.put(context, key, value)

    # Expected resolution per bind kind. `composing?` absent defaults to
    # composing (fail-safe); `overlay_open?` absent defaults to closed
    # (fail-safe) -- both documented in the Keymap moduledoc.
    defp expected(:escape, _composing?, overlay_open?) do
      if overlay_open? == true,
        do: %{type: :overlay_dismiss, payload: %{}},
        else: %{type: :interrupt, payload: %{}}
    end

    defp expected(:tab, _composing?, _overlay_open?),
      do: %{type: :steer, payload: %{}}

    defp expected({:char, char, type}, composing?, overlay_open?) do
      effective_composing? = composing? in [true, :absent]
      overlay? = overlay_open? == true

      if effective_composing? or overlay? do
        :passthrough
      else
        payload = if type == :fold_toggle, do: %{block_id: nil}, else: %{}
        %{type: type, payload: payload}
      end
    end

    test "every bind x every context combination resolves as documented" do
      binds = [
        :escape,
        :tab,
        {:char, "z", :fold_toggle},
        {:char, "j", :jump_next},
        {:char, "k", :jump_prev}
      ]

      for bind <- binds,
          composing? <- [true, false, :absent],
          overlay_open? <- [true, false, :absent] do
        context = matrix_context(composing?, overlay_open?)

        event =
          case bind do
            {:char, char, _type} -> Event.key(char)
            key when is_atom(key) -> Event.key(key)
          end

        assert resolve_from(event, context) ==
                 expected(bind, composing?, overlay_open?),
               "bind #{inspect(bind)} with composing?: #{inspect(composing?)}, " <>
                 "overlay_open?: #{inspect(overlay_open?)} resolved wrong"
      end
    end
  end

  # -- 5. modifier-aware key binds (Drew's review, T12 fix-now #2) --

  describe "modifier-aware key binds" do
    test "Ctrl+Tab (translator shape) -> :passthrough" do
      assert resolve_from(translator_event(@tb_tab, 0, 2)) == :passthrough
    end

    test "Ctrl+Tab (Event.key_event/3 shape) -> :passthrough" do
      assert resolve_from(Event.key_event(:tab, :pressed, [:ctrl])) ==
               :passthrough
    end

    test "Alt+Tab (Event.key_event/3 shape) -> :passthrough" do
      assert resolve_from(Event.key_event(:tab, :pressed, [:alt])) ==
               :passthrough
    end

    test "plain Tab (translator shape, no modifiers) -> :steer" do
      assert resolve_from(translator_event(@tb_tab, 0)) ==
               %{type: :steer, payload: %{}}
    end

    test "plain Tab (Event.key_event/3 shape, no modifiers) -> :steer" do
      assert resolve_from(Event.key_event(:tab, :pressed, [])) ==
               %{type: :steer, payload: %{}}
    end

    test "a declared mods: bind requires an EXACT match, not just 'no modifiers held'" do
      # Fixture-only bind (never added to the shipped v1 table) that
      # exercises the chord-growth extension point the moduledoc promises:
      # a bind that declares `mods:` requires the normalized event's mods
      # to match it exactly, rather than falling back to the bare-keypress
      # default `matches?/3` uses for every un-chorded v1 bind.
      chord = %{
        key: :tab,
        command_type: :steer,
        guard: :always,
        mods: %{ctrl: true, alt: false, shift: false, meta: false}
      }

      ctrl_tab =
        Event.key_event(:tab, :pressed, [:ctrl]) |> InputEvent.normalize()

      plain_tab = Event.key_event(:tab, :pressed, []) |> InputEvent.normalize()

      alt_tab =
        Event.key_event(:tab, :pressed, [:alt]) |> InputEvent.normalize()

      ctrl_shift_tab =
        Event.key_event(:tab, :pressed, [:ctrl, :shift])
        |> InputEvent.normalize()

      assert Keymap.matches?(chord, ctrl_tab, %{})
      refute Keymap.matches?(chord, plain_tab, %{})
      refute Keymap.matches?(chord, alt_tab, %{})
      refute Keymap.matches?(chord, ctrl_shift_tab, %{})
    end
  end

  # -- 6. resolve/2 with a nil context ("no block focused" callers) --

  describe "resolve/2 with a nil context" do
    test "nil normalizes to %{} -- guard: :always binds are unaffected" do
      assert resolve_from(Event.key_event(:escape, :pressed, []), nil) ==
               %{type: :interrupt, payload: %{}}
    end

    test "nil normalizes to %{} -- guard: :not_composing binds no longer raise, and resolve to :passthrough per the fail-safe default" do
      # Before the fix, guard_passes?/2 called Map.get(nil, :composing?,
      # _) directly and raised (BadMapError) for any :not_composing-
      # guarded bind -- a crash surface that depended on which bind
      # matched, since :always binds never touch context at all. resolve/2
      # now normalizes nil to %{} up front, so every bind sees a real map.
      assert resolve_from(Event.key_event("j", :pressed, []), nil) ==
               :passthrough
    end
  end

  # -- 7. fail-first RED proofs (see commit message / report for the manual
  # red runs against deliberately-reverted code) --
  #
  # (a) The property test above ("composing?: true always passes
  # through...") is the fail-first proof for the composer-focus guard
  # itself: temporarily inlining `true` in place of `guard_passes?/2`'s
  # `:not_composing` clause (so `z`/`j`/`k` fire unconditionally,
  # reproducing the named prototype bug) reddens this exact property
  # immediately (StreamData shrinks to a single-char counterexample, e.g.
  # "j", within the same run) with no other test touched. Restoring the
  # guard turns it green again.
  #
  # (b) "composing?: unset defaults to the fail-safe (composing)
  # behavior" above is the fail-first proof for the DEFAULT DIRECTION
  # fix: reverting `guard_passes?/2`'s `Map.get(context, :composing?,
  # true)` back to the old `Map.get(context, :composing?, false)` reddens
  # this exact test (it asserts :passthrough; the old default resolves
  # to `%{type: :jump_next, payload: %{}}` instead) with no other test in
  # this module touched -- this is the precise inversion Drew's review
  # named: a caller that omits `composing?` must get guarded (dead)
  # navigation, not silently-armed guarded binds.

  describe "full-viewport scrollback binds" do
    test "PgUp is ALWAYS live (fires even while composing) -> :scroll_up" do
      assert resolve_from(parser_event("\e[5~"), %{composing?: true}) ==
               %{type: :scroll_up, payload: %{}}

      assert resolve_from(Event.key_event(:page_up, :pressed, []), %{
               composing?: true
             }) == %{type: :scroll_up, payload: %{}}
    end

    test "PgDn is ALWAYS live (fires even while composing) -> :scroll_down" do
      assert resolve_from(parser_event("\e[6~"), %{composing?: true}) ==
               %{type: :scroll_down, payload: %{}}

      assert resolve_from(Event.key_event(:page_down, :pressed, []), %{
               composing?: true
             }) == %{type: :scroll_down, payload: %{}}
    end

    test "End is :not_composing -> :scroll_to_tail off the composer, passthrough on it" do
      assert resolve_from(Event.key_event(:end, :pressed, []), %{
               composing?: false,
               overlay_open?: false
             }) == %{type: :scroll_to_tail, payload: %{}}

      # While composing, End stays the composer's own end-of-line key.
      assert resolve_from(Event.key_event(:end, :pressed, []), %{
               composing?: true
             }) == :passthrough
    end

    test "G is :not_composing -> :scroll_to_tail off the composer, passthrough on it" do
      assert resolve_from(parser_event("G"), %{
               composing?: false,
               overlay_open?: false
             }) == %{type: :scroll_to_tail, payload: %{}}

      # While composing, a typed "G" is text, never a scroll command.
      assert resolve_from(parser_event("G"), %{composing?: true}) ==
               :passthrough
    end
  end
end
