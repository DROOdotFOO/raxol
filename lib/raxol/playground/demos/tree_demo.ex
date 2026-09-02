defmodule Raxol.Playground.Demos.TreeDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Display.Tree` — the real component.
  Arrow keys and Enter route into `Tree.handle_event/3`; the demo keeps only
  the expand-all / collapse-all conveniences, which it applies to the
  component's own `expanded` set.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Display.Tree

  @impl true
  def init(_context) do
    # snippet:start
    {:ok, tree} =
      Tree.init(
        id: :playground_tree,
        nodes: [
          node(:src, "src", [
            node(:app, "app.ex"),
            node(:lib, "lib", [
              node(:utils, "utils.ex"),
              node(:core, "core.ex")
            ])
          ]),
          node(:test, "test", [node(:helper, "test_helper.exs")]),
          node(:mix, "mix.exs"),
          node(:readme, "README.md")
        ]
      )

    # Keys route through Tree.handle_event/3; Tree.render/2 draws it.
    # snippet:end
    %{tree: tree}
  end

  defp node(id, label, children \\ []) do
    %{id: id, label: label, children: children, data: nil}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("e") ->
        {%{model | tree: %{model.tree | expanded: all_dir_ids(model.tree)}}, []}

      key_match("c") ->
        {%{model | tree: %{model.tree | expanded: MapSet.new()}}, []}

      %Event{type: :key} = event ->
        {tree, _commands} = Tree.handle_event(event, model.tree, %{})
        {%{model | tree: tree}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    visible = Tree.visible_nodes(model.tree)

    column style: %{gap: 1} do
      [
        text("Tree Demo", style: [:bold]),
        divider(),
        Tree.render(model.tree, %{}),
        divider(),
        text(
          "Nodes: #{length(visible)}  Expanded: #{MapSet.size(model.tree.expanded)}"
        ),
        text(
          "[up/down] navigate  [left/right] collapse/expand  [e] expand all  [c] collapse all",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp all_dir_ids(%{nodes: nodes}), do: collect_dir_ids(nodes)

  defp collect_dir_ids(nodes) do
    Enum.reduce(nodes, MapSet.new(), fn n, acc ->
      if n.children != [] do
        acc |> MapSet.put(n.id) |> MapSet.union(collect_dir_ids(n.children))
      else
        acc
      end
    end)
  end
end
