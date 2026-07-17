defmodule Raxol.UI.Components.Harness.NoticeTest do
  @moduledoc """
  The footer's honest report channels as Components (harness TEA migration
  §4, unit U2): `Notice` (refusal/degradation) and `LaneNotice` (the
  live-session channel that shares Notice's line vocabulary). Both are the
  re-hosting of `Surface.notice_line/2`.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.LaneNotice
  alias Raxol.UI.Components.Harness.Notice

  defp content(lines), do: Enum.map(lines, & &1.content)

  describe "Notice.lines/2 (verbatim Surface.notice_line/2)" do
    test "nil renders no rows" do
      assert Notice.lines(nil, 40) == []
    end

    test "a single string renders one row" do
      assert content(Notice.lines("no block focused", 40)) == [
               "no block focused"
             ]
    end

    test "a LIST renders one row per notice (a long first can't hide a later)" do
      assert content(Notice.lines(["line one", "line two"], 40)) ==
               ["line one", "line two"]
    end

    test "an embedded newline splits into physical rows" do
      assert content(Notice.lines("a\nb", 40)) == ["a", "b"]
    end

    test "each row is truncated to the display width with an ellipsis" do
      assert content(Notice.lines("abcdefghij", 5)) == ["abcd…"]
    end

    test "a non-positive width yields empty content, never a crash" do
      assert content(Notice.lines("anything", 0)) == [""]
    end

    test "returns Raxol.View.Components.text nodes (one physical row each)" do
      assert [%{type: :text, content: "x"}] = Notice.lines("x", 40)
    end
  end

  describe "Notice.render/2 (controlled stamp)" do
    test "stamps a column with the :notice kind and its rows" do
      {:ok, state} =
        Notice.init(id: "notice", notice: "degraded resume", width: 40)

      view = Notice.render(state, %{})

      assert view.type == :column
      assert view.id == "notice"
      assert view.attrs.kind == :notice
      assert view.attrs.component_module == Notice
      assert content(view.children) == ["degraded resume"]
    end

    test "a nil notice renders an empty column" do
      {:ok, state} = Notice.init(id: "notice", notice: nil, width: 40)
      assert %{children: []} = Notice.render(state, %{})
    end
  end

  describe "LaneNotice (the live-session channel)" do
    test "lines/2 shares Notice's vocabulary exactly (no drift)" do
      for notice <- [nil, "reconnecting", ["a", "b"], "x\ny"] do
        assert LaneNotice.lines(notice, 40) == Notice.lines(notice, 40)
      end
    end

    test "render/2 stamps the :lane kind" do
      {:ok, state} =
        LaneNotice.init(
          id: "lane",
          notice: "reconnecting to session",
          width: 40
        )

      view = LaneNotice.render(state, %{})
      assert view.attrs.kind == :lane
      assert view.attrs.component_module == LaneNotice
      assert content(view.children) == ["reconnecting to session"]
    end
  end

  describe "handle_event/3 (report channels have nothing to click)" do
    test "both return state unchanged with no commands" do
      {:ok, n} = Notice.init([])
      {:ok, l} = LaneNotice.init([])
      assert {^n, []} = Notice.handle_event(:x, n, %{})
      assert {^l, []} = LaneNotice.handle_event(:x, l, %{})
    end
  end
end
