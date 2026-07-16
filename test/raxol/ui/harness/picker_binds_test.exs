defmodule Raxol.UI.Harness.PickerBindsTest do
  @moduledoc """
  Keymap vocabulary for the palette/jump/session pickers, the palette's
  bind-table derivation contract (`Keymap.palette_binds/0` +
  `Keymap.command_for/2` -- invocation parity made real), and the
  overlay picker's fuzzy filter seam
  (`Raxol.UI.Harness.OverlayPicker.fuzzy_filter/3`, the
  `Raxol.UI.ListScorer` adapter).
  """

  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.UI.Harness.{InputEvent, Keymap, OverlayPicker}
  alias Raxol.UI.ListScorer

  defp resolve_from(raw_event, context \\ %{}) do
    raw_event |> InputEvent.normalize() |> Keymap.resolve(context)
  end

  defp parser_event(binary) do
    [event] = InputParser.parse(binary)
    event
  end

  defp identity_label(item), do: item

  # -- 1. the three picker binds ------------------------------------------

  describe "picker binds" do
    test "Ctrl+P -> :open_palette even while composing (a chord is never typed text)" do
      assert resolve_from(Event.key_event("p", :pressed, [:ctrl]), %{
               composing?: true
             }) == %{type: :open_palette, payload: %{}}
    end

    test "Ctrl+P (raw 0x10 byte through the ANSI parser) -> :open_palette" do
      assert resolve_from(parser_event(<<16>>)) ==
               %{type: :open_palette, payload: %{}}
    end

    test "plain 'p' while composing stays :passthrough (typed text)" do
      assert resolve_from(Event.key_event("p", :pressed, []), %{
               composing?: true
             }) == :passthrough
    end

    test "'g' -> :open_jump_picker in transcript-browse only" do
      assert resolve_from(Event.key_event("g", :pressed, []), %{
               composing?: false
             }) == %{type: :open_jump_picker, payload: %{}}

      assert resolve_from(Event.key_event("g", :pressed, []), %{
               composing?: true
             }) == :passthrough
    end

    test "'s' -> :open_session_picker in transcript-browse only" do
      assert resolve_from(Event.key_event("s", :pressed, []), %{
               composing?: false
             }) == %{type: :open_session_picker, payload: %{}}

      assert resolve_from(Event.key_event("s", :pressed, []), %{
               composing?: true
             }) == :passthrough
    end

    test "an open overlay suppresses 'g'/'s' (filter text, never commands fired behind the picker)" do
      ctx = %{composing?: false, overlay_open?: true}

      assert resolve_from(Event.key_event("g", :pressed, []), ctx) ==
               :passthrough

      assert resolve_from(Event.key_event("s", :pressed, []), ctx) ==
               :passthrough
    end

    test "a missing composing? flag fail-safes the printable picker binds to :passthrough" do
      assert resolve_from(Event.key_event("g", :pressed, []), %{}) ==
               :passthrough

      assert resolve_from(Event.key_event("s", :pressed, []), %{}) ==
               :passthrough
    end
  end

  # -- 2. palette derivation: the bind table is the single source of truth --

  describe "palette derivation" do
    test "palette_binds/0 is exactly the labeled subset of binds/0 (derived, never a parallel list)" do
      labeled = Enum.filter(Keymap.binds(), &Map.has_key?(&1, :label))

      assert Keymap.palette_binds() == labeled
      assert labeled != [], "the palette must have entries to derive"
    end

    test "every palette bind carries a non-empty human label" do
      for bind <- Keymap.palette_binds() do
        assert is_binary(bind.label) and bind.label != "",
               "bind #{inspect(bind.command_type)} has no usable label"
      end
    end

    test ":overlay_dismiss never appears in the palette (the palette IS an overlay)" do
      refute Enum.any?(
               Keymap.palette_binds(),
               &(&1.command_type == :overlay_dismiss)
             )
    end

    test "command_for/2 emits the same command shape resolve/2 dispatches -- invocation parity made real" do
      ctx = %{composing?: false, focused_block_id: 7}

      for bind <- Keymap.palette_binds() do
        command = Keymap.command_for(bind, ctx)
        assert command.type == bind.command_type
        assert is_map(command.payload)
      end
    end

    test "command_for/2 threads context into :fold_toggle's payload exactly like resolve/2" do
      ctx = %{composing?: false, focused_block_id: 7}

      fold_bind =
        Enum.find(Keymap.binds(), &(&1.command_type == :fold_toggle))

      assert Keymap.command_for(fold_bind, ctx) ==
               resolve_from(Event.key_event("z", :pressed, []), ctx)
    end
  end

  # -- 3. the fuzzy filter seam (ListScorer adapter) ------------------------

  describe "OverlayPicker.fuzzy_filter/3" do
    test "keeps subsequence matches the default substring filter drops" do
      items = ["session-switch", "alpha"]

      assert OverlayPicker.fuzzy_filter("ssw", items, &identity_label/1) ==
               ["session-switch"]

      # honest contrast: the default filter is substring-only and drops it
      picker = OverlayPicker.new(items)
      assert picker.filter_fn.("ssw", items, &identity_label/1) == []
    end

    test "ranks by score: word-boundary + adjacency beats a scattered match" do
      results =
        OverlayPicker.fuzzy_filter(
          "sw",
          ["session-switch", "swim"],
          &identity_label/1
        )

      assert List.first(results) == "swim"
      assert "session-switch" in results
    end

    test "order agrees with ListScorer.rank/4 -- no second ranking policy" do
      items = ["beta", "alpha", "abracadabra"]

      expected =
        items
        |> ListScorer.rank("a", &identity_label/1)
        |> Enum.map(& &1.item)

      assert OverlayPicker.fuzzy_filter("a", items, &identity_label/1) ==
               expected
    end

    test "empty query returns every item in original order" do
      items = ["c", "a", "b"]
      assert OverlayPicker.fuzzy_filter("", items, &identity_label/1) == items
    end

    test "drives the picker end to end through handle_key (the filter_fn seam untouched)" do
      picker =
        OverlayPicker.new(["session-switch", "alpha"],
          filter_fn: &OverlayPicker.fuzzy_filter/3
        )

      picker =
        Enum.reduce(["s", "s", "w"], picker, fn ch, p ->
          {:continue, p} =
            OverlayPicker.handle_key(p, %{
              kind: :char,
              char: ch,
              key: nil,
              state: :pressed,
              mods: %{ctrl: false, alt: false, shift: false, meta: false}
            })

          p
        end)

      assert OverlayPicker.matches(picker) == ["session-switch"]
    end
  end
end
