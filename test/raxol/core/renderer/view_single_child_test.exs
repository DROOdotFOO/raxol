defmodule Raxol.Core.Renderer.ViewSingleChildTest do
  @moduledoc """
  A container whose `do` block holds one expression must render that child
  (#1114). A one-expression block evaluates to the element map itself, not
  a list, and containers used to store it as `children` unwrapped; layout
  then silently drew an empty container.

  Views are built through the DSL an app gets from
  `use Raxol.Core.Runtime.Application` and laid out by the live layout
  engine; the assertions read the text elements it positions for drawing.
  """
  use ExUnit.Case, async: true

  import Raxol.Core.Renderer.View, except: [view: 1]

  alias Raxol.Core.Renderer.View.Layout.Flex
  alias Raxol.UI.Layout.Engine

  defp rendered_text(tree) do
    tree
    |> Engine.apply_layout(%{width: 40, height: 12})
    |> Enum.filter(&(&1.type == :text))
    |> Enum.sort_by(&{&1.y, &1.x})
    |> Enum.map(& &1.text)
  end

  defp optional_child_column(show?) do
    column style: %{gap: 1} do
      if show?, do: text("optional child")
    end
  end

  describe "View DSL container with a single-expression do block" do
    test "column with options renders its child" do
      tree =
        column style: %{gap: 1} do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "row with options renders its child" do
      tree =
        row gap: 1 do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "column without options renders its child" do
      tree =
        column do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "box with options renders its child" do
      tree =
        box style: %{padding: 1} do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "flex renders its child" do
      tree =
        flex direction: :column do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "panel renders its child" do
      tree =
        panel do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "split renders its child" do
      tree =
        split :horizontal, ratio: {1, 1} do
          text("only child")
        end

      assert rendered_text(tree) == ["only child"]
    end

    test "split_layout :dashboard renders its child" do
      tree =
        split_layout :dashboard do
          text("only child")
        end

      # The preset also draws its (empty) right-hand pane's divider.
      assert "only child" in rendered_text(tree)
    end

    test "nested single-child containers render the innermost child" do
      tree =
        box style: %{padding: 1} do
          column style: %{gap: 1} do
            row gap: 1 do
              text("deep child")
            end
          end
        end

      assert rendered_text(tree) == ["deep child"]
    end
  end

  describe "Raxol.View.Elements container macros" do
    require Raxol.View.Elements
    alias Raxol.View.Elements

    test "column and row render a single child" do
      tree =
        Elements.column style: %{gap: 1} do
          Elements.row gap: 1 do
            Elements.text("only child")
          end
        end

      assert rendered_text(tree) == ["only child"]
    end
  end

  describe "do blocks that do not end in a single element" do
    test "an `if` without `else` renders its child only when the branch runs" do
      assert rendered_text(optional_child_column(true)) == ["optional child"]
      assert rendered_text(optional_child_column(false)) == []
    end

    test "a block ending in a list renders every element" do
      tree =
        column style: %{gap: 1} do
          [text("first"), text("second")]
        end

      assert rendered_text(tree) == ["first", "second"]
    end
  end

  describe "layout of a container given a bare child instead of a list" do
    test "flex column renders the child" do
      assert rendered_text(Flex.column(children: text("bare child"))) ==
               ["bare child"]
    end

    test "row element renders the child" do
      tree = Raxol.View.Components.row(children: text("bare child"))
      assert rendered_text(tree) == ["bare child"]
    end
  end
end
