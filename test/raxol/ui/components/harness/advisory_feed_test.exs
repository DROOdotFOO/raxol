defmodule Raxol.UI.Components.Harness.AdvisoryFeedTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.AdvisoryFeed

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = AdvisoryFeed.init(id: :af1)
      assert state.entries == []
    end

    test "initializes with provided entries" do
      entries = [
        %{source: "probe:lint", kind: :verdict, text: "ok", score: 0.9}
      ]

      assert {:ok, state} = AdvisoryFeed.init(id: :af2, entries: entries)
      assert state.entries == entries
    end
  end

  describe "render/2" do
    test "renders a boxed, single-bordered column with an ADVISORY header" do
      {:ok, state} = AdvisoryFeed.init(id: :af)
      rendered = AdvisoryFeed.render(state, default_context())

      assert rendered.type == :box
      assert rendered.style.border == :single

      [column] = rendered.children
      assert column.type == :column

      header = Enum.at(column.children, 0)
      assert header.content == "ADVISORY"
      assert header.style == %{bold: true, dim: true}
    end

    test "shows a placeholder line when there are no entries" do
      {:ok, state} = AdvisoryFeed.init(id: :af, entries: [])
      rendered = AdvisoryFeed.render(state, default_context())
      [column] = rendered.children

      assert length(column.children) == 2
      assert Enum.at(column.children, 1).content == "no advisories"
    end

    test "renders one dim entry line per advisory, source/kind/text/score" do
      entries = [
        %{
          source: "probe:lint",
          kind: :verdict,
          text: "no unused aliases",
          score: 0.98
        },
        %{
          source: "probe:research",
          kind: :research,
          text: "similar fix in #521",
          score: nil
        }
      ]

      {:ok, state} = AdvisoryFeed.init(id: :af, entries: entries)
      rendered = AdvisoryFeed.render(state, default_context())
      [column] = rendered.children

      first = Enum.at(column.children, 1)
      assert first.content == "[verdict] probe:lint: no unused aliases (0.98)"
      assert first.style == %{dim: true}

      second = Enum.at(column.children, 2)
      assert second.content == "[research] probe:research: similar fix in #521"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = AdvisoryFeed.init(id: :af)
      {new_state, []} = AdvisoryFeed.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
