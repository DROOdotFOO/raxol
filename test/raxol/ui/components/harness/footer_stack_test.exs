defmodule Raxol.UI.Components.Harness.FooterStackTest do
  @moduledoc """
  The crown-jewel fit law (harness TEA migration §5 law 3), ported to
  `FooterStack` and pinned as pure `fit/3` / `lines/3` falsifiers -- the
  same law the surface's `fit_footer_groups/3` byte-tests
  (`diff_expand_surface_test`, `full_viewport_surface_test`) enforce against
  the shelved substrate, restated buffer-agnostically here.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.FooterStack

  # The canonical inline-footer drop order (verbatim from
  # `Surface.footer_frame/1`). Protected = its complement: lane, submitting,
  # notice.
  @drop_order [:composer_sep, :preview, :divider, :composer, :overlay, :status]

  # The full inline footer, one distinguishable line per row. Total = 12.
  defp full_groups do
    [
      status: ["status"],
      lane: ["lane"],
      submitting: ["submitting"],
      overlay: ["overlay1", "overlay2"],
      divider: ["divider"],
      preview: ["preview1", "preview2"],
      composer_sep: [""],
      composer: ["comp1", "comp2"],
      notice: ["notice"]
    ]
  end

  # The refusal footer: no lane/submitting, so a 1-row budget's head-take
  # keeps the notice (the diff-expansion honest-notice configuration).
  defp refusal_groups do
    [
      status: ["status"],
      divider: ["divider"],
      preview: ["preview1", "preview2"],
      composer_sep: [""],
      composer: ["comp1", "comp2"],
      notice: ["notice"]
    ]
  end

  defp keys_present(fitted) do
    for {k, lines} <- fitted, lines != [], do: k
  end

  describe "fit/3 -- the drop order (discretionary groups shed most-first)" do
    test "at exactly the budget nothing is shed" do
      groups = full_groups()
      assert FooterStack.fit(groups, @drop_order, 12) == groups
    end

    test "a budget above the total leaves every group intact" do
      groups = full_groups()
      assert FooterStack.fit(groups, @drop_order, 100) == groups
    end

    test "composer_sep (the above-composer blank) yields FIRST" do
      fitted = FooterStack.fit(full_groups(), @drop_order, 11)
      assert Keyword.get(fitted, :composer_sep) == []
      # nothing else has moved yet
      assert Keyword.get(fitted, :preview) == ["preview1", "preview2"]
      assert Keyword.get(fitted, :composer) == ["comp1", "comp2"]
    end

    test "after composer_sep, the preview yields (from its tail)" do
      fitted = FooterStack.fit(full_groups(), @drop_order, 10)
      assert Keyword.get(fitted, :composer_sep) == []
      # tail-trim: the preview's LEADING line survives, the tail drops
      assert Keyword.get(fitted, :preview) == ["preview1"]
      assert Keyword.get(fitted, :divider) == ["divider"]
    end

    test "the full drop order, in sequence, matches the surface's priority" do
      # Budget stepping down from the total records the order groups empty.
      order =
        11..0//-1
        |> Enum.map(fn budget ->
          FooterStack.fit(full_groups(), @drop_order, budget) |> keys_present()
        end)

      # At the full budget every group is present (composer_sep is a blank
      # `[""]` -- one row, not empty); shedding starts one below.
      assert [
               :status,
               :lane,
               :submitting,
               :overlay,
               :divider,
               :preview,
               :composer_sep,
               :composer,
               :notice
             ] ==
               keys_present(FooterStack.fit(full_groups(), @drop_order, 12))

      # composer_sep is the first to empty, at budget 11.
      refute :composer_sep in keys_present(
               FooterStack.fit(full_groups(), @drop_order, 11)
             )

      # Every step keeps the three protected channels.
      assert Enum.all?(order, fn present ->
               :lane in present and :submitting in present and
                 :notice in present
             end)
    end
  end

  describe "fit/3 -- protected channels are never shed" do
    test "lane / submitting / notice survive even when all droppables are gone" do
      # Budget 3 = exactly the three protected rows; every discretionary
      # group is shed to nothing.
      fitted = FooterStack.fit(full_groups(), @drop_order, 3)

      assert Keyword.get(fitted, :lane) == ["lane"]
      assert Keyword.get(fitted, :submitting) == ["submitting"]
      assert Keyword.get(fitted, :notice) == ["notice"]

      assert Keyword.get(fitted, :status) == []
      assert Keyword.get(fitted, :composer) == []
      assert Keyword.get(fitted, :overlay) == []
      assert Keyword.get(fitted, :preview) == []
    end

    test "status (the last droppable) yields before any protected channel" do
      # Budget 4 leaves room for one droppable after the three protected;
      # status is the least-droppable, so it is the one that survives.
      fitted = FooterStack.fit(full_groups(), @drop_order, 4)
      assert Keyword.get(fitted, :status) == ["status"]
    end
  end

  describe "fit/3 -- tail-trim keeps a group's leading line" do
    test "a partially-shed group drops from its tail, never its head" do
      groups = [composer: ["prompt", "cont1", "cont2"], notice: ["notice"]]
      # overflow 2 -> composer trimmed from the tail to just its prompt row
      fitted = FooterStack.fit(groups, [:composer], 2)
      assert Keyword.get(fitted, :composer) == ["prompt"]
    end
  end

  describe "fit/3 -- absent drop_order keys are a no-op (partial group sets)" do
    test "a drop_order naming a group not in `groups` never crashes" do
      groups = [status: ["status"], notice: ["notice"]]
      # :composer_sep and :overlay are absent; :status is present.
      fitted = FooterStack.fit(groups, @drop_order, 1)
      assert Keyword.get(fitted, :status) == []
      assert Keyword.get(fitted, :notice) == ["notice"]
    end
  end

  describe "lines/3 -- flatten in display order + head-take last resort" do
    test "flattens the fitted groups in display order" do
      assert FooterStack.lines(refusal_groups(), @drop_order, 8) ==
               [
                 "status",
                 "divider",
                 "preview1",
                 "preview2",
                 "",
                 "comp1",
                 "comp2",
                 "notice"
               ]
    end

    test "budget-1: the notice wins (no lane/submitting competing)" do
      assert FooterStack.lines(refusal_groups(), @drop_order, 1) == ["notice"]
    end

    test "budget-1 with lane present: the EARLIEST protected wins (head-take)" do
      # Full footer: lane/submitting/notice all protected; the head-take
      # keeps the earliest in display order.
      assert FooterStack.lines(full_groups(), @drop_order, 1) == ["lane"]
    end

    test "budget 0 renders nothing" do
      assert FooterStack.lines(full_groups(), @drop_order, 0) == []
    end
  end

  describe "group_offset/4 -- the composer cursor-park offset (§5 law 6)" do
    test "rows above the composer in the fitted footer" do
      # status(1)+lane(1)+submitting(1)+overlay(2)+divider(1)+preview(2)+composer_sep(1) = 9
      assert FooterStack.group_offset(full_groups(), @drop_order, 12, :composer) ==
               9
    end

    test "nil when the group was shed to nothing" do
      assert FooterStack.group_offset(full_groups(), @drop_order, 3, :composer) ==
               nil
    end

    test "nil for a group absent from the set" do
      assert FooterStack.group_offset(full_groups(), @drop_order, 12, :nope) ==
               nil
    end
  end

  describe "total_height/1" do
    test "sums every group's line count before any fit" do
      assert FooterStack.total_height(full_groups()) == 12
      assert FooterStack.total_height([]) == 0
    end
  end

  describe "render/2 (controlled stamp)" do
    test "emits a stamped column whose children are the fitted lines" do
      {:ok, state} =
        FooterStack.init(
          id: "footer",
          groups: refusal_groups(),
          drop_order: @drop_order,
          budget: 1
        )

      view = FooterStack.render(state, %{})

      assert view.type == :column
      assert view.id == "footer"
      assert view.attrs.component_module == FooterStack
      assert view.attrs.kind == :footer_stack
      assert view.children == ["notice"]
    end
  end

  describe "handle_event/3 (a container has no events of its own)" do
    test "returns the state unchanged with no commands" do
      {:ok, state} = FooterStack.init([])
      assert {^state, []} = FooterStack.handle_event(:anything, state, %{})
    end
  end
end
