defmodule Raxol.UI.Harness.InputEventTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Terminal.Driver.EventTranslator
  alias Raxol.UI.Harness.InputEvent

  # termbox modifier bitmask, per event_translator.ex: bit0=shift bit1=ctrl
  # bit2=alt bit3=meta
  @shift 1
  @ctrl 2
  @alt 4
  @meta 8

  # Real TB_KEY_* values (see event_translator.ex's moduledoc -- these are
  # NOT the ANSI-final-byte/ncurses values the driver used to use).
  @tb_up 65_517
  @tb_down 65_516
  @tb_left 65_515
  @tb_right 65_514
  @tb_home 65_521
  @tb_end 65_520
  @tb_insert 65_523
  @tb_delete 65_522
  @tb_page_up 65_519
  @tb_page_down 65_518
  @tb_back_tab 65_513
  @tb_f1 65_535
  @tb_f2 65_534
  @tb_f3 65_533
  @tb_f4 65_532
  @tb_f5 65_531
  @tb_f6 65_530
  @tb_f7 65_529
  @tb_f8 65_528
  @tb_f9 65_527
  @tb_f10 65_526
  @tb_f11 65_525
  @tb_f12 65_524
  @tb_enter 13
  @tb_tab 9
  @tb_escape 27
  @tb_backspace 127

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

  # Fixtures for the table-driven test below. Resolved at *runtime* (inside
  # the generated test bodies) rather than at module-compile time, since
  # these call private functions defined in this same module.
  defp fixture(:translator_char), do: translator_event(0, ?a)
  defp fixture(:translator_ctrl_char), do: translator_event(0, ?a, @ctrl)
  defp fixture(:translator_up), do: translator_event(@tb_up, 0)
  defp fixture(:translator_enter), do: translator_event(@tb_enter, 0)
  defp fixture(:translator_tab), do: translator_event(@tb_tab, 0)
  defp fixture(:translator_escape), do: translator_event(@tb_escape, 0)
  defp fixture(:translator_backspace), do: translator_event(@tb_backspace, 0)
  defp fixture(:parser_char), do: parser_event("a")
  defp fixture(:parser_ctrl_char), do: parser_event(<<1>>)
  defp fixture(:parser_up), do: parser_event(<<27, 91, 65>>)
  defp fixture(:parser_enter), do: parser_event(<<13>>)
  defp fixture(:ek_char), do: Event.key_event("a", :pressed, [])
  defp fixture(:ek_shift_char), do: Event.key_event("A", :pressed, [:shift])
  defp fixture(:ek_ctrl_char), do: Event.key_event("a", :pressed, [:ctrl])
  defp fixture(:ek_enter), do: Event.key_event(:enter, :pressed, [])

  # -- shape (a): native termbox driver (event_translator.ex) --

  describe "normalize/1 -- event_translator.ex shape" do
    test "plain char" do
      event = translator_event(0, ?a)

      assert InputEvent.normalize(event) == %{
               kind: :char,
               char: "a",
               key: nil,
               text: nil,
               mods: %{ctrl: false, alt: false, shift: false, meta: false},
               state: nil,
               raw: event
             }
    end

    test "shift + char is still text" do
      event = translator_event(0, ?A, @shift)
      norm = InputEvent.normalize(event)
      assert norm.kind == :char
      assert norm.char == "A"
      assert norm.mods == %{ctrl: false, alt: false, shift: true, meta: false}
      assert InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == "A"
      refute InputEvent.shortcut?(norm)
    end

    test "ctrl + char is a shortcut, not text" do
      event = translator_event(0, ?a, @ctrl)
      norm = InputEvent.normalize(event)
      assert norm.kind == :char
      assert norm.mods.ctrl
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
      assert InputEvent.printable_char(norm) == nil
    end

    test "alt + char is a shortcut" do
      event = translator_event(0, ?a, @alt)
      norm = InputEvent.normalize(event)
      assert norm.mods.alt
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
    end

    test "meta (Cmd/Super) + char is a shortcut, NOT literal text" do
      event = translator_event(0, ?a, @meta)
      norm = InputEvent.normalize(event)
      assert norm.kind == :char
      assert norm.char == "a"
      assert norm.mods.meta
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
      assert InputEvent.printable_char(norm) == nil
    end

    test "arrow keys map to :key (real TB_KEY_ARROW_* codes)" do
      for {code, expected} <- [
            {@tb_up, :up},
            {@tb_down, :down},
            {@tb_right, :right},
            {@tb_left, :left}
          ] do
        event = translator_event(code, 0)
        norm = InputEvent.normalize(event)
        assert norm.kind == :key
        assert norm.key == expected
        assert InputEvent.key(norm) == expected
        assert InputEvent.printable_char(norm) == nil
        refute InputEvent.text?(norm)
      end
    end

    test "function keys F1/F2 map to :key (real TB_KEY_F1/TB_KEY_F2 codes)" do
      assert InputEvent.normalize(translator_event(@tb_f1, 0)).key == :f1
      assert InputEvent.normalize(translator_event(@tb_f2, 0)).key == :f2
    end

    test "control keys (Enter/Tab/Escape/Backspace) map to :key, not printable char" do
      assert InputEvent.normalize(translator_event(@tb_enter, 0)).key == :enter
      assert InputEvent.normalize(translator_event(@tb_tab, 0)).key == :tab

      assert InputEvent.normalize(translator_event(@tb_escape, 0)).key ==
               :escape

      assert InputEvent.normalize(translator_event(@tb_backspace, 0)).key ==
               :backspace

      # And the same control bytes arriving via char_code instead of
      # key_code (the wiring convention is not settled -- see
      # event_translator.ex's moduledoc) resolve identically, never
      # leaking through as `char:`.
      assert InputEvent.normalize(translator_event(0, @tb_enter)).key ==
               :enter

      assert InputEvent.normalize(translator_event(0, @tb_escape)).key ==
               :escape
    end

    test "shift+tab (TB_KEY_BACK_TAB) recovers the shift bit" do
      norm = InputEvent.normalize(translator_event(@tb_back_tab, 0))
      assert norm.key == :tab
      assert norm.mods.shift
      refute InputEvent.shortcut?(norm)
    end

    test "unrecognized keycode still normalizes (kind: :key, key: :unknown)" do
      norm = InputEvent.normalize(translator_event(999, 0))
      assert norm.kind == :key
      assert norm.key == :unknown
    end
  end

  # -- shape (b): raw ANSI parser (input_parser.ex) --

  describe "normalize/1 -- input_parser.ex shape" do
    test "plain printable char (key: :char, char: binary)" do
      event = parser_event("a")

      assert InputEvent.normalize(event) == %{
               kind: :char,
               char: "a",
               key: nil,
               text: nil,
               mods: %{ctrl: false, alt: false, shift: false, meta: false},
               state: nil,
               raw: event
             }
    end

    test "ctrl+a (bytes 1-26) is a shortcut" do
      norm = InputEvent.normalize(parser_event(<<1>>))
      assert norm.kind == :char
      assert norm.char == "a"
      assert norm.mods.ctrl
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
    end

    test "alt+key (ESC char) is a shortcut" do
      norm = InputEvent.normalize(parser_event(<<27, ?a>>))
      assert norm.kind == :char
      assert norm.char == "a"
      assert norm.mods.alt
      assert InputEvent.shortcut?(norm)
    end

    test "arrow keys, enter, backspace, escape, tab map to :key" do
      assert InputEvent.normalize(parser_event(<<27, 91, 65>>)).key == :up
      assert InputEvent.normalize(parser_event(<<27, 91, 66>>)).key == :down
      assert InputEvent.normalize(parser_event(<<27, 91, 67>>)).key == :right
      assert InputEvent.normalize(parser_event(<<27, 91, 68>>)).key == :left
      assert InputEvent.normalize(parser_event(<<13>>)).key == :enter
      assert InputEvent.normalize(parser_event(<<127>>)).key == :backspace
      assert InputEvent.normalize(parser_event(<<27>>)).key == :escape
      assert InputEvent.normalize(parser_event(<<9>>)).key == :tab
    end

    test "shift+tab (backtab) is :key with shift mod but not a shortcut" do
      norm = InputEvent.normalize(parser_event(<<27, 91, 90>>))
      assert norm.key == :tab
      assert norm.mods.shift
      refute InputEvent.shortcut?(norm)
    end

    test "multi-byte UTF-8 / emoji grapheme survives intact" do
      emoji = "👍"
      norm = InputEvent.normalize(parser_event(emoji))
      assert norm.kind == :char
      assert norm.char == emoji
      assert InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == emoji
    end

    test "bracketed paste" do
      payload =
        <<27, 91, 50, 48, 48, 126>> <> "hi" <> <<27, 91, 50, 48, 49, 126>>

      norm = InputEvent.normalize(parser_event(payload))
      assert norm.kind == :paste
      assert norm.text == "hi"
      assert norm.char == nil
      assert norm.key == nil
    end
  end

  # -- shape (c): Event.key_event/3 (test/component API) --

  describe "normalize/1 -- Event.key_event/3 shape" do
    test "bare binary key is text" do
      event = Event.key_event("a", :pressed, [])
      norm = InputEvent.normalize(event)
      assert norm.kind == :char
      assert norm.char == "a"
      assert InputEvent.text?(norm)
    end

    test "shift-only modifier is still text" do
      event = Event.key_event("A", :pressed, [:shift])
      norm = InputEvent.normalize(event)
      assert norm.mods == %{ctrl: false, alt: false, shift: true, meta: false}
      assert InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == "A"
    end

    test "ctrl modifier makes a char a shortcut" do
      event = Event.key_event("a", :pressed, [:ctrl])
      norm = InputEvent.normalize(event)
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
    end

    test "alt modifier makes a char a shortcut" do
      event = Event.key_event("a", :pressed, [:alt])
      norm = InputEvent.normalize(event)
      assert InputEvent.shortcut?(norm)
    end

    test "meta modifier (in the modifiers list) makes a char a shortcut" do
      event = Event.key_event("s", :pressed, [:meta])
      norm = InputEvent.normalize(event)
      assert norm.mods.meta
      refute InputEvent.text?(norm)
      assert InputEvent.shortcut?(norm)
    end

    test "atom key is a special key" do
      for key <- [:enter, :backspace, :escape, :tab, :up, :down] do
        event = Event.key_event(key, :pressed, [])
        norm = InputEvent.normalize(event)
        assert norm.kind == :key
        assert norm.key == key
        assert InputEvent.key(norm) == key
      end
    end

    test "emoji grapheme via key_event/3 survives intact" do
      family = "👨‍👩‍👧‍👦"
      event = Event.key_event(family, :pressed, [])
      norm = InputEvent.normalize(event)
      assert norm.char == family
      assert InputEvent.printable_char(norm) == family
    end
  end

  # -- paste event via Event.paste_event/2 --

  describe "normalize/1 -- Event.paste_event/2" do
    test "paste normalizes to kind: :paste with text" do
      event = Event.paste_event("pasted text", {0, 0})
      norm = InputEvent.normalize(event)
      assert norm.kind == :paste
      assert norm.text == "pasted text"
      refute InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == nil
      assert InputEvent.key(norm) == nil
    end
  end

  # -- bare (unwrapped) data maps --

  describe "normalize/1 -- bare data maps (no Event wrapper)" do
    test "bare event_translator-shaped data map" do
      data = %{
        shift: false,
        ctrl: false,
        alt: false,
        meta: false,
        char: "z",
        key: nil
      }

      norm = InputEvent.normalize(data)
      assert norm.kind == :char
      assert norm.char == "z"
    end

    test "bare input_parser-shaped data map" do
      data = %{key: :char, char: "z", ctrl: true}
      norm = InputEvent.normalize(data)
      assert norm.kind == :char
      assert norm.mods.ctrl
      assert InputEvent.shortcut?(norm)
    end

    test "bare special-key data map" do
      norm = InputEvent.normalize(%{key: :up})
      assert norm.kind == :key
      assert norm.key == :up
    end

    test "bare paste-shaped data map (no :type wrapper)" do
      norm = InputEvent.normalize(%{text: "hi"})
      assert norm.kind == :paste
      assert norm.text == "hi"
    end
  end

  # -- fallback / totality for non-key event shapes --

  describe "normalize/1 -- unrecognized shapes never crash" do
    test "mouse event normalizes to :other" do
      event = Event.mouse(:left, {1, 2})
      norm = InputEvent.normalize(event)
      assert norm.kind == :other
      assert norm.raw == event
      refute InputEvent.text?(norm)
      refute InputEvent.shortcut?(norm)
      assert InputEvent.key(norm) == nil
      assert InputEvent.printable_char(norm) == nil
    end

    test "resize event normalizes to :other" do
      norm = InputEvent.normalize(Event.new(:resize, %{width: 80, height: 24}))
      assert norm.kind == :other
    end

    test "empty key data map normalizes to :other" do
      norm = InputEvent.normalize(%{})
      assert norm.kind == :other
    end

    test "nil, integers, lists, strings never crash" do
      for input <- [
            nil,
            42,
            [1, 2, 3],
            "just a string",
            {:a, :b},
            %{random: :junk}
          ] do
        norm = InputEvent.normalize(input)
        assert norm.kind in [:char, :key, :paste, :other]
        assert norm.raw == input
      end
    end
  end

  # -- table-driven: shapes x key classes --

  describe "table-driven: every shape x key class" do
    # {label, fixture_key, expected_kind, expected_key_or_char, text?, shortcut?}
    table = [
      {"translator: plain char", :translator_char, :char, "a", true, false},
      {"translator: ctrl+char", :translator_ctrl_char, :char, "a", false, true},
      {"translator: arrow up", :translator_up, :key, :up, false, false},
      {"translator: enter", :translator_enter, :key, :enter, false, false},
      {"translator: tab", :translator_tab, :key, :tab, false, false},
      {"translator: escape", :translator_escape, :key, :escape, false, false},
      {"translator: backspace", :translator_backspace, :key, :backspace, false,
       false},
      {"parser: plain char", :parser_char, :char, "a", true, false},
      {"parser: ctrl+char", :parser_ctrl_char, :char, "a", false, true},
      {"parser: arrow up", :parser_up, :key, :up, false, false},
      {"parser: enter", :parser_enter, :key, :enter, false, false},
      {"event_key: plain char", :ek_char, :char, "a", true, false},
      {"event_key: shift char", :ek_shift_char, :char, "A", true, false},
      {"event_key: ctrl char", :ek_ctrl_char, :char, "a", false, true},
      {"event_key: enter", :ek_enter, :key, :enter, false, false}
    ]

    for {label, fixture_key, expected_kind, expected_payload, text?, shortcut?} <-
          table do
      # Build only the ONE relevant field assertion for this row at
      # generation time -- a runtime `case` on a compile-time-constant atom
      # would still emit both branches (norm.char == <atom> and
      # norm.key == <binary>), tripping the type checker on the row where
      # the branch is dead code but still statically type-mismatched.
      payload_assertion =
        case expected_kind do
          :char ->
            quote(do: assert(var!(norm).char == unquote(expected_payload)))

          :key ->
            quote(do: assert(var!(norm).key == unquote(expected_payload)))
        end

      test label do
        event = fixture(unquote(fixture_key))
        norm = InputEvent.normalize(event)

        assert norm.kind == unquote(expected_kind)
        unquote(payload_assertion)

        assert InputEvent.text?(norm) == unquote(text?)
        assert InputEvent.shortcut?(norm) == unquote(shortcut?)
      end
    end
  end

  # -- properties --

  describe "properties" do
    property "normalize/1 is total: never raises on arbitrary-ish event maps" do
      check all(
              kind_seed <-
                one_of([
                  constant(:char),
                  constant(:key),
                  constant(:paste),
                  constant(:other)
                ]),
              key_atom <-
                one_of([
                  nil,
                  :char,
                  :up,
                  :down,
                  :enter,
                  :escape,
                  :backspace,
                  :tab,
                  :unknown
                ]),
              char_bin <-
                one_of([
                  constant(nil),
                  constant(""),
                  constant("a"),
                  constant("A"),
                  constant("👍")
                ]),
              ctrl <- boolean(),
              alt <- boolean(),
              shift <- boolean(),
              meta <- boolean(),
              modifiers <-
                list_of(one_of([:ctrl, :alt, :shift, :meta]), max_length: 4),
              state <-
                one_of([nil, :pressed, :released, :repeat, :bogus]),
              text_bin <-
                one_of([constant(nil), constant(""), constant("pasted")]),
              max_runs: 200
            ) do
        data = %{
          key: key_atom,
          char: char_bin,
          ctrl: ctrl,
          alt: alt,
          shift: shift,
          meta: meta,
          modifiers: modifiers,
          state: state
        }

        raw =
          case kind_seed do
            :paste -> %{type: :paste, data: %{text: text_bin || ""}}
            _ -> %{type: :key, data: data}
          end

        norm = InputEvent.normalize(raw)
        assert is_map(norm)
        assert norm.kind in [:char, :key, :paste, :other]
        assert is_map(norm.mods)
        assert is_boolean(norm.mods.ctrl)
        assert is_boolean(norm.mods.alt)
        assert is_boolean(norm.mods.shift)
        assert is_boolean(norm.mods.meta)

        # helpers must never raise either
        _ = InputEvent.text?(norm)
        _ = InputEvent.shortcut?(norm)
        _ = InputEvent.printable_char(norm)
        _ = InputEvent.key(norm)
      end
    end

    property "normalize/1 is total on genuinely arbitrary terms" do
      check all(term <- term(), max_runs: 100) do
        norm = InputEvent.normalize(term)
        assert norm.kind in [:char, :key, :paste, :other]
      end
    end
  end

  # -- cross-shape agreement: REAL emitters --
  #
  # The previous version of this suite hand-built "translator-shaped" and
  # "parser-shaped" maps directly (`%{key: k, char: nil, ctrl: ctrl, ...}`)
  # instead of calling `EventTranslator.translate/1` / `InputParser.parse/1`.
  # For :up/:down/etc that happened to line up with what the real functions
  # produce, but for enter/tab/escape/backspace it was a FICTION: the real
  # `EventTranslator.translate/1` only mapped 6 keycodes (arrows + F1/F2,
  # and both used the WRONG numeric codes -- see event_translator.ex's
  # moduledoc), so a REAL termbox enter/tab/esc/backspace normalized to
  # `key: :unknown` while the ANSI parser correctly produced
  # `:enter`/`:tab`/... for the same keypress. The hand-built map asserted
  # agreement that could not exist between the real functions.
  #
  # Every event below is produced by the REAL `EventTranslator.translate/1`
  # and REAL `InputParser.parse/1` -- no hand-built normalized maps. See
  # input_event.ex's moduledoc ("Cross-shape agreement: scope") for
  # exactly what modifier combinations are and are not claimed to agree,
  # and why (meta is unrepresentable over ANSI; Enter/Tab/Escape/Backspace
  # have no modifier-carrying ANSI encoding).
  describe "cross-shape agreement (real translator + real parser)" do
    # {ansi letter, is F-key/SS3-unmodified?} -- unmodified F1-F4 use SS3
    # (ESC O <letter>); everything else here uses CSI (ESC [ <letter>).
    # The modified form (ESC [ 1 ; <mod> <letter>) is the same for both,
    # per input_parser.ex's `csi_letter_to_key/1` clause list.
    @letter_form_keys %{
      :up => {65, false},
      :down => {66, false},
      :right => {67, false},
      :left => {68, false},
      :home => {72, false},
      :end => {70, false},
      :f1 => {80, true},
      :f2 => {81, true},
      :f3 => {82, true},
      :f4 => {83, true}
    }

    # CSI tilde-number keys (ESC [ <n> ~, or ESC [ <n> ; <mod> ~).
    @tilde_form_keys %{
      :insert => 2,
      :delete => 3,
      :page_up => 5,
      :page_down => 6,
      :f5 => 15,
      :f6 => 17,
      :f7 => 18,
      :f8 => 19,
      :f9 => 20,
      :f10 => 21,
      :f11 => 23,
      :f12 => 24
    }

    @tb_key_codes %{
      :up => @tb_up,
      :down => @tb_down,
      :left => @tb_left,
      :right => @tb_right,
      :home => @tb_home,
      :end => @tb_end,
      :insert => @tb_insert,
      :delete => @tb_delete,
      :page_up => @tb_page_up,
      :page_down => @tb_page_down,
      :f1 => @tb_f1,
      :f2 => @tb_f2,
      :f3 => @tb_f3,
      :f4 => @tb_f4,
      :f5 => @tb_f5,
      :f6 => @tb_f6,
      :f7 => @tb_f7,
      :f8 => @tb_f8,
      :f9 => @tb_f9,
      :f10 => @tb_f10,
      :f11 => @tb_f11,
      :f12 => @tb_f12
    }

    @modifiable_keys Map.keys(@letter_form_keys) ++ Map.keys(@tilde_form_keys)

    # xterm CSI modifier parameter: 1 + (shift?1) + (alt?2) + (ctrl?4),
    # per input_parser.ex's `decode_modifier/1`.
    defp mod_digit(%{shift: shift, alt: alt, ctrl: ctrl}) do
      1 + bit(shift, 1) + bit(alt, 2) + bit(ctrl, 4)
    end

    defp bit(true, n), do: n
    defp bit(false, _n), do: 0

    defp no_mods?(%{shift: shift, alt: alt, ctrl: ctrl}),
      do: not (shift or alt or ctrl)

    # termbox mod_code bitmask: bit0=shift(1) bit1=ctrl(2) bit2=alt(4).
    defp termbox_mod_code(%{shift: shift, alt: alt, ctrl: ctrl}) do
      bit(shift, @shift) + bit(ctrl, @ctrl) + bit(alt, @alt)
    end

    defp ansi_bytes_for(key, mods) when is_map_key(@letter_form_keys, key) do
      {letter, ss3?} = Map.fetch!(@letter_form_keys, key)

      cond do
        no_mods?(mods) and ss3? -> <<27, 79, letter>>
        no_mods?(mods) -> <<27, 91, letter>>
        true -> <<27, 91, 49, 59, ?0 + mod_digit(mods), letter>>
      end
    end

    defp ansi_bytes_for(key, mods) when is_map_key(@tilde_form_keys, key) do
      n = Map.fetch!(@tilde_form_keys, key)

      if no_mods?(mods) do
        "\e[#{n}~"
      else
        "\e[#{n};#{mod_digit(mods)}~"
      end
    end

    defp mods_map(shift, alt, ctrl),
      do: %{shift: shift, alt: alt, ctrl: ctrl, meta: false}

    defp assert_agrees(translator_event, parser_event, expected_key, mods) do
      translator_norm = InputEvent.normalize(translator_event)
      parser_norm = InputEvent.normalize(parser_event)

      fields = [:kind, :char, :key, :mods]

      assert Map.take(translator_norm, fields) == Map.take(parser_norm, fields),
             "translator/parser disagreed for #{expected_key} #{inspect(mods)}: " <>
               "#{inspect(Map.take(translator_norm, fields))} vs " <>
               "#{inspect(Map.take(parser_norm, fields))}"

      assert translator_norm.kind == :key
      assert translator_norm.key == expected_key
      assert translator_norm.mods == mods
    end

    test "modifiable keys (arrows, home/end, F1-F4, insert/delete/pgup/pgdn, F5-F12) agree across the full ctrl/alt/shift power set" do
      for key <- @modifiable_keys,
          shift <- [false, true],
          alt <- [false, true],
          ctrl <- [false, true] do
        mods = mods_map(shift, alt, ctrl)

        translator_event =
          translator_event(
            Map.fetch!(@tb_key_codes, key),
            0,
            termbox_mod_code(mods)
          )

        parser_event = parser_event(ansi_bytes_for(key, mods))

        assert_agrees(translator_event, parser_event, key, mods)
      end
    end

    test "shift+tab (backtab) agrees: TB_KEY_BACK_TAB vs CSI Z" do
      translator_event = translator_event(@tb_back_tab, 0)
      parser_event = parser_event(<<27, 91, 90>>)

      assert_agrees(
        translator_event,
        parser_event,
        :tab,
        mods_map(true, false, false)
      )
    end

    test "control keys with no ANSI modifier encoding agree unmodified (Enter/Tab/Escape/Backspace)" do
      no_mods = mods_map(false, false, false)

      for {key, tb_code, ansi_bytes} <- [
            {:enter, @tb_enter, <<13>>},
            {:tab, @tb_tab, <<9>>},
            {:escape, @tb_escape, <<27>>},
            {:backspace, @tb_backspace, <<127>>}
          ] do
        translator_event = translator_event(tb_code, 0)
        parser_event = parser_event(ansi_bytes)
        assert_agrees(translator_event, parser_event, key, no_mods)
      end
    end

    test "printable chars agree unmodified (any printable char)" do
      for char <- ["a", "z", "5", " ", "!"] do
        <<byte>> = char

        assert_chars_agree(
          translator_event(0, byte),
          parser_event(char),
          char,
          mods_map(false, false, false)
        )
      end
    end

    test "ctrl+letter agrees (bytes 1-26 on the wire -- input_parser.ex only maps ctrl this way for a-z)" do
      for char <- ["a", "z"] do
        <<byte>> = char
        ctrl_ansi = <<byte - 96>>

        assert_chars_agree(
          translator_event(0, byte, @ctrl),
          parser_event(ctrl_ansi),
          char,
          mods_map(false, false, true)
        )
      end
    end

    test "alt+char agrees (ESC <char> on the wire)" do
      for char <- ["a", "z", "5"] do
        <<byte>> = char
        alt_ansi = <<27, byte>>

        assert_chars_agree(
          translator_event(0, byte, @alt),
          parser_event(alt_ansi),
          char,
          mods_map(false, true, false)
        )
      end
    end

    defp assert_chars_agree(translator_event, parser_event, char, mods) do
      translator_norm = InputEvent.normalize(translator_event)
      parser_norm = InputEvent.normalize(parser_event)
      fields = [:kind, :char, :key, :mods]

      assert Map.take(translator_norm, fields) == Map.take(parser_norm, fields),
             "translator/parser disagreed for #{inspect(char)} #{inspect(mods)}: " <>
               "#{inspect(Map.take(translator_norm, fields))} vs " <>
               "#{inspect(Map.take(parser_norm, fields))}"

      assert translator_norm.kind == :char
      assert translator_norm.char == char
      assert translator_norm.mods == mods
    end
  end

  # -- event state (:pressed/:released/:repeat) --

  describe "event state" do
    test "release does not insert text" do
      event = Event.key_event("a", :released, [])
      norm = InputEvent.normalize(event)
      assert norm.kind == :char
      assert norm.state == :released
      refute InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == nil
    end

    test "press and repeat still insert text" do
      for state <- [:pressed, :repeat] do
        event = Event.key_event("a", state, [])
        norm = InputEvent.normalize(event)
        assert InputEvent.text?(norm)
        assert InputEvent.printable_char(norm) == "a"
      end
    end

    test "release does not dispatch a special key" do
      event = Event.key_event(:enter, :released, [])
      norm = InputEvent.normalize(event)
      assert norm.kind == :key
      assert InputEvent.key(norm) == nil
    end

    test "press and repeat still dispatch a special key" do
      for state <- [:pressed, :repeat] do
        event = Event.key_event(:enter, state, [])
        norm = InputEvent.normalize(event)
        assert InputEvent.key(norm) == :enter
      end
    end

    test "no state field (event_translator.ex / input_parser.ex shapes) defaults to nil, treated as press" do
      norm = InputEvent.normalize(translator_event(0, ?a))
      assert norm.state == nil
      assert InputEvent.text?(norm)

      key_norm = InputEvent.normalize(translator_event(@tb_up, 0))
      assert key_norm.state == nil
      assert InputEvent.key(key_norm) == :up
    end
  end

  # -- content validation --

  describe "content validation" do
    test "a control sequence smuggled into :char normalizes to :other, not :char" do
      norm = InputEvent.normalize(%{type: :key, data: %{char: "\e[2J"}})
      refute norm.kind == :char
      assert norm.kind == :other
      refute InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == nil
    end

    test "a bare multi-grapheme string in :key normalizes to :other, not an insertable char" do
      norm = InputEvent.normalize(%{type: :key, data: %{key: "enter"}})
      refute norm.kind == :char
      refute InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == nil
    end

    test "text?/1 and printable_char/1 reject a hand-built map with a control byte, even outside normalize/1" do
      bad = %{
        kind: :char,
        char: "\e",
        key: nil,
        text: nil,
        mods: %{ctrl: false, alt: false, shift: false, meta: false},
        state: nil,
        raw: nil
      }

      refute InputEvent.text?(bad)
      assert InputEvent.printable_char(bad) == nil
    end

    test "a single-codepoint emoji is still valid text (not rejected as multi-byte)" do
      norm = InputEvent.normalize(parser_event("👍"))
      assert InputEvent.text?(norm)
      assert InputEvent.printable_char(norm) == "👍"
    end

    test "bracketed paste strips embedded control bytes but keeps tab/newline/CR" do
      payload =
        <<27, 91, 50, 48, 48, 126>> <>
          "line one\ttabbed\nline two\e[2Jinjected" <>
          <<27, 91, 50, 48, 49, 126>>

      norm = InputEvent.normalize(parser_event(payload))
      assert norm.kind == :paste
      # ESC (the byte that makes "[2J" a live terminal control sequence
      # instead of inert text) is stripped; tab/newline are preserved as
      # legitimate multi-line paste content.
      assert norm.text == "line one\ttabbed\nline two[2Jinjected"
      refute String.contains?(norm.text, "\e")
    end
  end

  describe "normalize/1 -- idempotence (the SessionPump contract)" do
    # PumpContract §4: the live pump normalizes at its boundary, and
    # HarnessApp.Model.handle_key/2 normalizes again for its own routing.
    # A second pass must be a no-op -- before this property held, the
    # second pass read mods as all-false (un-pressing Ctrl on every live
    # chord) and buried the original Event one :raw level too deep for
    # component dispatch.

    test "a normalized char map passes through unchanged" do
      norm = InputEvent.normalize(Event.key("x"))
      assert InputEvent.normalize(norm) == norm
      assert norm.raw != nil
    end

    test "ctrl chords survive the double pass (the quit-protocol bug)" do
      norm =
        InputEvent.normalize(%Event{
          type: :key,
          data: %{key: "c", state: :pressed, modifiers: [:ctrl]}
        })

      twice = InputEvent.normalize(norm)
      assert twice.mods.ctrl == true
      assert twice == norm
    end

    test "a normalized special key keeps its key atom and :raw Event" do
      event = Event.key_event(:enter, :pressed, [])
      norm = InputEvent.normalize(event)
      twice = InputEvent.normalize(norm)

      assert twice.kind == :key
      assert twice.key == :enter
      assert twice.raw == event
    end

    test "the paste shape is idempotent too" do
      norm = InputEvent.normalize(Event.paste_event("hello", {0, 0}))
      assert InputEvent.normalize(norm) == norm
    end

    # The fast path must recognize only GENUINELY-normalized events (the
    # canonical four-key mods shape), never any map that merely carries a
    # `kind` and some `mods` field. `mods: %{}` matches ANY map, so before
    # this a crafted map short-circuited the normalizer and returned its
    # unsanitized content verbatim.
    test "a paste-shaped map with empty mods is NOT trusted verbatim -- it is re-sanitized" do
      hostile = %{kind: :paste, text: "\e[2J\e]0;pwned\ahi", mods: %{}}

      result = InputEvent.normalize(hostile)

      # Fell through to real paste normalization: ESC/BEL control bytes are
      # stripped, not passed through to an insertion sink.
      refute result.text =~ "\e"
      refute result.text =~ "\a"
      assert result.text =~ "hi"
    end

    test "a partial-mods map is re-normalized to the canonical mods shape" do
      partial = %{kind: :char, char: "a", mods: %{ctrl: true}}

      result = InputEvent.normalize(partial)

      # Not returned unchanged: mods is rebuilt to the full four-key shape
      # so text?/1 and shortcut?/1 clause heads bind.
      assert Map.keys(result.mods) |> Enum.sort() == [:alt, :ctrl, :meta, :shift]
    end

    test "a fully-canonical map (all four mods keys) still passes through unchanged" do
      norm = %{
        kind: :char,
        char: "a",
        key: nil,
        text: nil,
        mods: %{ctrl: false, alt: false, shift: false, meta: false},
        state: nil,
        raw: :original
      }

      assert InputEvent.normalize(norm) == norm
    end
  end
end
