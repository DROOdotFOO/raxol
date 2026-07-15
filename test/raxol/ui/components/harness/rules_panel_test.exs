defmodule Raxol.UI.Components.Harness.RulesPanelTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.RulesPanel

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp sample_rules do
    [
      %{
        when: "approval_requested is pending",
        then: "block until approval_decision arrives",
        hard: true
      },
      %{
        when: "turn_completed carries usage",
        then: "refresh the cost readout",
        hard: false
      }
    ]
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = RulesPanel.init(id: :rp1)
      assert state.id == :rp1
      assert state.title == "Rules"
      assert state.rules == []
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      rules = sample_rules()

      assert {:ok, state} =
               RulesPanel.init(
                 id: :rp2,
                 title: "Active Rules",
                 rules: rules,
                 style: %{fg: :cyan},
                 theme: %{bg: :blue}
               )

      assert state.id == :rp2
      assert state.title == "Active Rules"
      assert state.rules == rules
      assert state.style == %{fg: :cyan}
      assert state.theme == %{bg: :blue}
    end

    test "defaults id to a unique generated string" do
      assert {:ok, state} = RulesPanel.init([])
      assert state.id =~ ~r/^rules-panel-\d+$/
    end
  end

  describe "render/2" do
    test "renders an empty-state message when rules is empty" do
      {:ok, state} = RulesPanel.init(id: :rp_empty)
      rendered = RulesPanel.render(state, default_context())

      assert rendered.type == :box
      assert rendered.id == :rp_empty
      assert rendered.style == %{border: :single, padding: 1}

      [column] = rendered.children
      assert [title_el, empty_el] = column.children
      assert title_el.content == "Rules"
      assert empty_el.content == "No active rules."
      assert empty_el.style == %{dim: true}
    end

    test "renders hard rules bold+yellow with a filled marker" do
      {:ok, state} = RulesPanel.init(id: :rp_hard, rules: sample_rules())
      rendered = RulesPanel.render(state, default_context())

      [column] = rendered.children
      [_title_el, hard_el, _soft_el] = column.children

      assert hard_el.id == "rp_hard-rule-0"
      assert hard_el.style == %{bold: true, fg: :yellow}

      assert hard_el.content ==
               "● HARD  when approval_requested is pending → then block until approval_decision arrives"
    end

    test "renders soft rules dimmed with a hollow marker" do
      {:ok, state} = RulesPanel.init(id: :rp_soft, rules: sample_rules())
      rendered = RulesPanel.render(state, default_context())

      [column] = rendered.children
      [_title_el, _hard_el, soft_el] = column.children

      assert soft_el.id == "rp_soft-rule-1"
      assert soft_el.style == %{dim: true}

      assert soft_el.content ==
               "○ soft  when turn_completed carries usage → then refresh the cost readout"
    end

    test "hard rule styling is visually stronger than soft (bold vs dim, distinct markers)" do
      {:ok, state} = RulesPanel.init(id: :rp_contrast, rules: sample_rules())
      rendered = RulesPanel.render(state, default_context())

      [column] = rendered.children
      [_title_el, hard_el, soft_el] = column.children

      assert Map.get(hard_el.style, :bold) == true
      refute Map.get(soft_el.style, :bold)
      assert Map.get(soft_el.style, :dim) == true
      refute Map.get(hard_el.style, :dim)
      assert String.starts_with?(hard_el.content, "●")
      assert String.starts_with?(soft_el.content, "○")
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = RulesPanel.init(id: :rp_evt, rules: sample_rules())

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, []} = RulesPanel.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
