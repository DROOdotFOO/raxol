defmodule Raxol.Playground.Demos.RadioGroupDemo do
  @moduledoc """
  Playground demo: hand-rolled radio-group *technique* — there is no
  `Raxol.UI.Components.RadioGroup` (or similar) Component yet.

  `Raxol.View.Components.radio_group/1` exists as a declarative view-node
  shape (`type: :radio_group`), but this demo does not mount that node or
  any component lifecycle. Selection lives in the TEA model; options render
  as plain `text/1` rows with `(o)` / `( )` marks.

  Keys: j/k move selection in the active group, h/l switch group focus.
  """
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context) do
    %{
      groups: [
        %{name: "Theme", options: ["Light", "Dark", "Auto"], selected: 0},
        %{name: "Size", options: ["Small", "Medium", "Large"], selected: 0},
        %{name: "Speed", options: ["Slow", "Normal", "Fast"], selected: 0}
      ],
      active_group: 0
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("j") -> {move_selection(model, 1), []}
      key_match("k") -> {move_selection(model, -1), []}
      key_match("h") -> {switch_group(model, -1), []}
      key_match("l") -> {switch_group(model, 1), []}
      _ -> {model, []}
    end
  end

  defp move_selection(model, delta) do
    group = Enum.at(model.groups, model.active_group)
    max_idx = length(group.options) - 1

    new_selected =
      Raxol.Core.Utils.Math.clamp(group.selected + delta, 0, max_idx)

    new_group = %{group | selected: new_selected}
    groups = List.replace_at(model.groups, model.active_group, new_group)
    %{model | groups: groups}
  end

  defp switch_group(model, delta) do
    count = length(model.groups)
    next = rem(model.active_group + delta + count, count)
    %{model | active_group: next}
  end

  @impl true
  def view(model) do
    group_views =
      model.groups
      |> Enum.with_index()
      |> Enum.map(&render_group(&1, model.active_group))

    summary =
      Enum.map_join(model.groups, "  ", fn g ->
        "#{g.name}: #{Enum.at(g.options, g.selected)}"
      end)

    column style: %{gap: 1} do
      [
        text("Radio Group (technique) — no Component yet", style: [:bold]),
        text(" hand-rolled TEA selection + (o)/( ) marks", style: [:dim]),
        divider(),
        row(style: %{gap: 4}, do: group_views),
        divider(),
        text(summary, style: [:bold]),
        text("[j/k] navigate  [h/l] switch group", style: [:dim])
      ]
    end
  end

  defp render_group({group, gi}, active_group) do
    active? = gi == active_group
    title_style = if active?, do: [:bold], else: [:dim]

    options =
      group.options
      |> Enum.with_index()
      |> Enum.map(&render_option(&1, group.selected, active?))

    column style: %{gap: 0} do
      [text(group.name, style: title_style) | options]
    end
  end

  defp render_option({opt, oi}, selected, active?) do
    mark = if oi == selected, do: "(o)", else: "( )"
    prefix = if active? and oi == selected, do: "> ", else: "  "
    text("#{prefix}#{mark} #{opt}")
  end

  @impl true
  def subscribe(_model), do: []
end
