defmodule Raxol.Playground.Demos.TreeDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Display.Tree` — the REAL tree view
  with expand/collapse and keyboard navigation. Keys route through
  `Tree.handle_event/3` (Event-shaped vocabulary, same as Viewport).

  Component bindings:
  - Up/Down (and j/k mapped here): move cursor through visible nodes
  - Right / Enter / Space: expand or toggle; leaf fires on_select
  - Left: collapse, or move to parent
  - Home/End: first/last visible node

  Demo-level chords (not in the component):
  - [e] expand all directories
  - [c] collapse all
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Display.Tree

  @nodes [
    %{
      id: :src,
      label: "src",
      children: [
        %{id: :app_ex, label: "app.ex", children: [], data: nil},
        %{
          id: :lib,
          label: "lib",
          children: [
            %{id: :utils_ex, label: "utils.ex", children: [], data: nil},
            %{id: :core_ex, label: "core.ex", children: [], data: nil}
          ],
          data: nil
        }
      ],
      data: nil
    },
    %{
      id: :test,
      label: "test",
      children: [
        %{id: :test_helper, label: "test_helper.exs", children: [], data: nil}
      ],
      data: nil
    },
    %{id: :mix_exs, label: "mix.exs", children: [], data: nil},
    %{id: :readme, label: "README.md", children: [], data: nil}
  ]

  @impl true
  def init(_context) do
    {:ok, tree} =
      Tree.init(
        id: :playground_tree,
        nodes: @nodes,
        expanded: MapSet.new(),
        focused: true
      )

    %{tree: tree, event_log: [], last_select: nil}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("e") ->
        expanded = all_branch_ids(@nodes)
        tree = %{model.tree | expanded: expanded}
        model = DemoHelpers.log_event(model, "expand all -> #{MapSet.size(expanded)} nodes")
        {%{model | tree: tree}, []}

      key_match("c") ->
        tree = %{model.tree | expanded: MapSet.new(), cursor: first_id(@nodes)}
        model = DemoHelpers.log_event(model, "collapse all")
        {%{model | tree: tree}, []}

      _ ->
        case tree_event(message) do
          nil ->
            {model, []}

          {event, summary} ->
            {tree, model} = apply_tree(model, event, summary)
            {%{model | tree: tree}, []}
        end
    end
  end

  # Map playground keys onto Tree's Event vocabulary. j/k are vim aliases
  # for up/down; h/l for left/right expand/collapse.
  defp tree_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: "j"} -> {event(:down), "key j/down"}
      %{key: :char, char: "k"} -> {event(:up), "key k/up"}
      %{key: :char, char: "h"} -> {event(:left), "key h/left"}
      %{key: :char, char: "l"} -> {event(:right), "key l/right"}
      %{key: :down} -> {event(:down), "key :down"}
      %{key: :up} -> {event(:up), "key :up"}
      %{key: :left} -> {event(:left), "key :left"}
      %{key: :right} -> {event(:right), "key :right"}
      %{key: :enter} -> {event(:enter), "key :enter"}
      %{key: :space} -> {event(:space), "key :space"}
      %{key: :home} -> {event(:home), "key :home"}
      %{key: :end} -> {event(:end), "key :end"}
      _ -> nil
    end
  end

  defp tree_event(_other), do: nil

  defp event(key), do: %Event{type: :key, data: %{key: key}}

  defp apply_tree(model, event, summary) do
    before = model.tree
    {tree, _cmds} = Tree.handle_event(event, before, %{})

    expanded_delta = MapSet.size(tree.expanded) - MapSet.size(before.expanded)

    outcome =
      "#{summary} -> cursor=#{inspect(tree.cursor)} " <>
        "expanded=#{MapSet.size(tree.expanded)}" <>
        if(expanded_delta != 0, do: " (#{fmt_delta(expanded_delta)})", else: "")

    {tree, DemoHelpers.log_event(model, outcome)}
  end

  defp fmt_delta(n) when n > 0, do: "+#{n}"
  defp fmt_delta(n), do: "#{n}"

  @impl true
  def view(model) do
    tree = model.tree
    visible = Tree.visible_nodes(tree)
    cursor_label = cursor_label(tree)

    column style: %{gap: 1} do
      [
        text("Tree — Raxol.UI.Components.Display.Tree", style: [:bold]),
        text(" expand/collapse via Tree.handle_event (▶ / ▼ icons)", style: [:dim]),
        text(""),
        box style: %{border: :single, padding: 1, width: 40} do
          Tree.render(tree, %{})
        end,
        text(""),
        row style: %{gap: 2} do
          [
            text("Cursor: #{cursor_label}"),
            text("Visible: #{length(visible)}"),
            text("Expanded: #{MapSet.size(tree.expanded)}")
          ]
        end,
        text(
          " [j/k ↑↓] move  [h/l ←→] collapse/expand  [enter/space] toggle  [e] expand all  [c] collapse all",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp cursor_label(%{cursor: nil}), do: "none"

  defp cursor_label(%{cursor: id, nodes: nodes}) do
    case Tree.find_node(nodes, id) do
      %{label: label} -> "#{label} (#{id})"
      _ -> inspect(id)
    end
  end

  defp first_id([%{id: id} | _]), do: id

  defp all_branch_ids(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn node, acc ->
      if node.children != [] do
        acc
        |> MapSet.put(node.id)
        |> MapSet.union(all_branch_ids(node.children))
      else
        acc
      end
    end)
  end
end
