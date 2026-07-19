defmodule Raxol.UI.Components.Harness.ChoicePromptTest do
  @moduledoc """
  The chevron choice prompt's key contract (V's spec, pinned):

    * idle: `[enter]`/`[escape]` hints on the option rows, Enter confirms,
      Escape cancels, placeholder at low prominence, caret at the start;
    * typing: hints disappear, Enter submits, Escape clears (hints return);
    * arrows: confirm ⇅ cancel ⇅ input, text-first inside a multi-line
      draft — Up hops out only from the first visual row, no wrap-around;
    * typing from an option row refocuses the input and inserts.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ChoicePrompt

  defp new(opts \\ []) do
    {:ok, state} = ChoicePrompt.init(Keyword.merge([id: "cp", width: 40], opts))
    state
  end

  defp press(state, key, modifiers \\ []) do
    ChoicePrompt.handle_event(
      Event.key_event(key, :pressed, modifiers),
      state,
      %{}
    )
  end

  defp type(state, text) do
    text
    |> String.graphemes()
    |> Enum.reduce(state, fn char, acc ->
      {new_state, _cmds} = press(acc, char)
      new_state
    end)
  end

  # collect {content, style} leaves per row, in document order
  defp rows(state) do
    ChoicePrompt.render(state, %{})
    |> Map.fetch!(:children)
    |> Enum.map(fn row ->
      Enum.map(row.children, fn seg -> {seg.content, seg.style} end)
    end)
  end

  defp row_text(state, index) do
    state |> rows() |> Enum.at(index) |> Enum.map_join("", &elem(&1, 0))
  end

  # ── the idle shape ───────────────────────────────────────────────────────

  describe "idle (empty draft)" do
    test "three chevron rows: confirm [enter], cancel [escape], placeholder" do
      state = new()

      assert row_text(state, 0) == "❯ confirm [enter]"
      assert row_text(state, 1) == "❯ cancel [escape]"
      assert row_text(state, 2) == "❯ explain what to do instead"
    end

    test "focus starts on the input row: its chevron is bold, option rows faded" do
      state = new()
      [confirm, cancel, input] = rows(state)

      assert {_, %{dim: true, fg: "#" <> _}} = hd(confirm)
      assert {_, %{dim: true, fg: "#" <> _}} = hd(cancel)
      assert {_, %{bold: true}} = hd(input)
    end

    test "the placeholder sits faded; the key hints are bold full-strength affordances" do
      state = new()
      [confirm, cancel, input] = rows(state)

      assert {" [enter]", %{bold: true}} = List.last(confirm)
      assert {" [escape]", %{bold: true}} = List.last(cancel)

      assert {"explain what to do instead", %{dim: true, fg: "#" <> _}} =
               List.last(input)
    end

    test "the caret parks at the input row's start (after the chevron cells)" do
      state = new()
      assert {2, col} = ChoicePrompt.edit_point(state)
      assert col == 3
    end

    test "Enter confirms (the [enter] hint kept honest)" do
      {_state, cmds} = new() |> press(:enter)
      assert cmds == [{:component_event, "cp", :confirm}]
    end

    test "Escape cancels (the [escape] hint kept honest)" do
      {_state, cmds} = new() |> press(:escape)
      assert cmds == [{:component_event, "cp", :cancel}]
    end
  end

  # ── typing ───────────────────────────────────────────────────────────────

  describe "typing (non-empty draft)" do
    test "the [enter]/[escape] hints disappear from the option rows" do
      state = new() |> type("do it differently")

      assert row_text(state, 0) == "❯ confirm"
      assert row_text(state, 1) == "❯ cancel"
      refute row_text(state, 0) =~ "[enter]"
      refute row_text(state, 1) =~ "[escape]"
    end

    test "the draft renders full-strength where the placeholder was quiet" do
      state = new() |> type("abc")
      [_confirm, _cancel, input] = rows(state)

      assert {"abc", %{}} = List.last(input)
    end

    test "Enter submits the draft text" do
      {_state, cmds} = new() |> type("use sed instead") |> press(:enter)
      assert cmds == [{:component_event, "cp", {:submit, "use sed instead"}}]
    end

    test "Escape clears the draft — no command, hints return, caret home" do
      state = new() |> type("half a thought")
      {cleared, cmds} = press(state, :escape)

      assert cmds == []
      assert ChoicePrompt.value(cleared) == ""
      assert row_text(cleared, 0) == "❯ confirm [enter]"
      assert {2, 3} = ChoicePrompt.edit_point(cleared)
    end

    test "Escape after the clear cancels (back to the idle contract)" do
      state = new() |> type("x")
      {cleared, []} = press(state, :escape)
      {_state, cmds} = press(cleared, :escape)

      assert cmds == [{:component_event, "cp", :cancel}]
    end

    test "the caret advances as the draft grows" do
      state = new() |> type("ab")
      assert {2, col} = ChoicePrompt.edit_point(state)
      assert col == 5
    end
  end

  # ── arrows ───────────────────────────────────────────────────────────────

  describe "arrow navigation (single-line draft)" do
    test "Up from the input lands on cancel, then confirm, then stops" do
      state = new()

      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {state, []} = press(state, :up)
      assert state.focus == :confirm

      {state, []} = press(state, :up)
      assert state.focus == :confirm
    end

    test "Down walks back: confirm → cancel → input" do
      state = new()
      {state, []} = press(state, :up)
      {state, []} = press(state, :up)
      assert state.focus == :confirm

      {state, []} = press(state, :down)
      assert state.focus == :cancel

      {state, []} = press(state, :down)
      assert state.focus == :input
    end

    test "the focused option row brightens; the input chevron drops to faded" do
      state = new()
      {state, []} = press(state, :up)

      [_confirm, cancel, input] = rows(state)
      assert {_, %{bold: true}} = hd(cancel)
      assert {_, %{dim: true, fg: "#" <> _}} = hd(input)
    end

    test "no caret while an option row holds focus" do
      state = new()
      {state, []} = press(state, :up)
      assert ChoicePrompt.edit_point(state) == nil
    end
  end

  describe "arrow navigation (multi-line draft): text first, boundary hop second" do
    # Shift+Enter authors the second line; the caret ends on line 2.
    defp two_line_draft do
      state = new() |> type("first line")
      {state, []} = press(state, :enter, [:shift])
      type(state, "second line")
    end

    test "Up inside the draft moves within the text, not out of it" do
      state = two_line_draft()
      assert {3, _col} = ChoicePrompt.edit_point(state)

      {state, []} = press(state, :up)
      assert state.focus == :input
      assert {2, _col} = ChoicePrompt.edit_point(state)
    end

    test "Up from the first line hops to cancel, then confirm" do
      state = two_line_draft()
      {state, []} = press(state, :up)
      assert state.focus == :input

      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {state, []} = press(state, :up)
      assert state.focus == :confirm
    end

    test "Down from cancel re-enters the draft; Down inside it walks the text" do
      state = two_line_draft()
      {state, []} = press(state, :up)
      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {state, []} = press(state, :down)
      assert state.focus == :input

      {state, []} = press(state, :down)
      assert state.focus == :input
      assert {3, _col} = ChoicePrompt.edit_point(state)
    end

    test "a multi-line draft renders one chevron row + hang-indented continuation" do
      state = two_line_draft()

      assert row_text(state, 2) == "❯ first line"
      assert row_text(state, 3) == "  second line"
    end
  end

  # ── option-row activation + type-to-input ───────────────────────────────

  describe "option rows" do
    test "Enter on confirm activates confirm" do
      state = new()
      {state, []} = press(state, :up)
      {state, []} = press(state, :up)
      assert state.focus == :confirm

      {_state, cmds} = press(state, :enter)
      assert cmds == [{:component_event, "cp", :confirm}]
    end

    test "Enter on cancel activates cancel" do
      state = new()
      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {_state, cmds} = press(state, :enter)
      assert cmds == [{:component_event, "cp", :cancel}]
    end

    test "typing from an option row refocuses the input and inserts" do
      state = new()
      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {state, _cmds} = press(state, "k")
      assert state.focus == :input
      assert ChoicePrompt.value(state) == "k"
    end

    test "Escape from an option row with a non-empty draft still clears the draft" do
      state = new() |> type("draft")
      {state, []} = press(state, :up)
      assert state.focus == :cancel

      {state, cmds} = press(state, :escape)
      assert cmds == []
      assert ChoicePrompt.value(state) == ""
      assert state.focus == :input
    end
  end

  # ── submit leaves the lifecycle to the host ─────────────────────────────

  test "submit does not clear the draft — the host owns the lifecycle" do
    {state, [_submit]} = new() |> type("keep me") |> press(:enter)
    assert ChoicePrompt.value(state) == "keep me"
  end
end
