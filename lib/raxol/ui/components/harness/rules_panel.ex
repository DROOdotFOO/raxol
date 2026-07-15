defmodule Raxol.UI.Components.Harness.RulesPanel do
  @moduledoc """
  A read-only panel over the harness's active when->then rules projection.

  Renders the materialized view folded from `extract{class: :rules, op, item}`
  meta events (source `:probe_c2_rules`). `hard: true` rules are ENFORCED
  constraints -- the gate blocks on them -- rather than mere reminders, so
  they render with a filled marker and bold weight; soft rules render dimmed
  with a hollow marker. The distinction never relies on color alone (weight +
  glyph both carry it), and avoids red/alarm styling since a rule is a
  standing constraint, not an error.
  """

  alias Raxol.UI.StyleHelper
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type rule :: %{when: String.t(), then: String.t(), hard: boolean()}

  @type t :: %{
          id: String.t() | atom(),
          title: String.t(),
          rules: [rule()],
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "rules-panel-#{:erlang.unique_integer([:positive])}"
        ),
      title: Keyword.get(props, :title, "Rules"),
      rules: Keyword.get(props, :rules, []),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :rules_panel)

    Components.box(
      id: state.id,
      style: Map.merge(%{border: :single, padding: 1}, base_style),
      children: [
        Components.column(
          style: %{gap: 0},
          children: [
            Components.text(
              id: "#{state.id}-title",
              content: state.title,
              style: %{bold: true}
            )
            | rule_rows(state)
          ]
        )
      ]
    )
  end

  defp rule_rows(%{rules: []}) do
    [Components.text(content: "No active rules.", style: %{dim: true})]
  end

  defp rule_rows(%{id: id, rules: rules}) do
    rules
    |> Enum.with_index()
    |> Enum.map(fn {rule, index} -> rule_row(id, rule, index) end)
  end

  defp rule_row(id, %{when: when_clause, then: then_clause, hard: true}, index) do
    Components.text(
      id: "#{id}-rule-#{index}",
      content: "● HARD  when #{when_clause} → then #{then_clause}",
      style: %{bold: true, fg: :yellow}
    )
  end

  defp rule_row(id, %{when: when_clause, then: then_clause}, index) do
    Components.text(
      id: "#{id}-rule-#{index}",
      content: "○ soft  when #{when_clause} → then #{then_clause}",
      style: %{dim: true}
    )
  end
end
