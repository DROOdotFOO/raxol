# Table Features Test
#
# Demonstrates the table component with data and keyboard navigation.
#
# Usage:
#   mix run examples/components/displays/table_features_test.exs

defmodule TableFeaturesTestExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @data [
    %{id: 1, name: "Alice", email: "alice@example.com", role: "Admin"},
    %{id: 2, name: "Bob", email: "bob@example.com", role: "User"},
    %{id: 3, name: "Charlie", email: "charlie@example.com", role: "User"},
    %{id: 4, name: "Diana", email: "diana@example.com", role: "Moderator"}
  ]

  @impl true
  def init(_context) do
    %{selected: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        {%{model | selected: min(model.selected + 1, length(@data) - 1)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        {%{model | selected: max(model.selected - 1, 0)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    selected_row = Enum.at(@data, model.selected)

    column style: %{padding: 1, gap: 1} do
      [
        text("Table Features", style: [:bold]),
        box title: "Users", style: %{border: :single, padding: 1} do
          table(
            id: :users_table,
            data: @data,
            columns: [
              %{header: "ID", key: :id, width: 5},
              %{header: "Name", key: :name, width: 15},
              %{header: "Email", key: :email, width: 25},
              %{header: "Role", key: :role, width: 12}
            ]
          )
        end,
        box title: "Selected (row #{model.selected + 1})",
            style: %{border: :single, padding: 1} do
          if selected_row do
            column do
              [
                text("Name:  #{selected_row.name}"),
                text("Email: #{selected_row.email}"),
                text("Role:  #{selected_row.role}")
              ]
            end
          else
            text("No selection")
          end
        end,
        text("Up/Down to select | 'q' to quit")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

Raxol.Core.Runtime.Log.info("TableFeaturesTestExample: Starting...")
{:ok, pid} = Raxol.start_link(TableFeaturesTestExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
