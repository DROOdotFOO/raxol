defmodule Raxol.UI.Components.Harness.ComposerTeaTest do
  @moduledoc """
  The Composer's TEA-path additions (harness TEA migration U2): the
  id/attrs render stamp and `visual_lines/2` (the LayoutEngine-renderable
  draft rows, byte-aligned with `edit_point/2`). The editing/wrap/chord
  logic itself is pinned by the existing composer suite; this file pins only
  what U2 added.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Composer

  defp composer(opts) do
    {:ok, state} = Composer.init(Keyword.put_new(opts, :width, 40))
    state
  end

  describe "render/2 stamps identity (U2)" do
    test "the root column carries id + :composer attrs" do
      view = Composer.render(composer(id: "composer"), %{available_width: 40})
      assert view.type == :column
      assert view.id == "composer"
      assert view.attrs.kind == :composer
      assert view.attrs.component_module == Composer
    end
  end

  describe "visual_lines/2 (TEA-path draft render)" do
    test "a single-line draft is one row equal to the value" do
      state = Composer.set_value(composer(id: "c"), "hi there")
      assert Composer.visual_lines(state, 40) == ["hi there"]
    end

    test "a wrapped draft is one string per visual row" do
      state =
        Composer.set_value(composer(id: "c", wrap: :word), "alpha beta gamma")

      rows = Composer.visual_lines(state, 8)
      # word-wrapped at width 8 -> multiple rows, each within the width
      assert length(rows) > 1
      assert Enum.all?(rows, &(String.length(&1) <= 8))
      assert Enum.join(rows, " ") =~ "alpha"
    end

    test "an empty, unfocused draft with a placeholder returns the placeholder row" do
      state = composer(id: "c", focused: false, placeholder: "type a prompt")
      assert Composer.visual_lines(state, 40) == ["type a prompt"]
    end

    test "an empty, FOCUSED draft is one empty row (the caret's home, not the placeholder)" do
      state = composer(id: "c", focused: true, placeholder: "type a prompt")
      assert Composer.visual_lines(state, 40) == [""]
    end

    test "a queued-steer banner is the first row (matching edit_point's accounting)" do
      state =
        composer(id: "c")
        |> Composer.set_value("draft")

      {state, _} =
        Composer.update(
          {:set_queued_steer, %{text: "later", queued_at: 0}},
          state
        )

      [banner | rest] = Composer.visual_lines(state, 40)
      assert banner =~ "later"
      assert rest == ["draft"]
    end
  end

  describe "visual_lines/2 stays byte-aligned with edit_point/2" do
    test "the edit-point row indexes into the visual_lines list" do
      state = Composer.set_value(composer(id: "c"), "hi there")
      rows = Composer.visual_lines(state, 40)
      {row, col} = Composer.edit_point(state, 40)

      # row is a valid index into the rendered rows, and the 1-based column
      # sits at the end of that row's content + 1 (the caret after "hi there")
      assert Enum.at(rows, row) == "hi there"
      assert col == String.length("hi there") + 1
    end
  end
end
