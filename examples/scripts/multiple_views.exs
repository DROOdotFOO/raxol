# An example of how to implement navigation between multiple views.
#
# Usage:
#   elixir examples/snippets/basic/multiple_views.exs

defmodule MultipleViewsDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    Raxol.Core.Runtime.Log.debug("MultipleViewsDemo: init/1")
    %{selected_tab: 1}
  end

  @impl true
  def update(message, model) do
    Raxol.Core.Runtime.Log.debug(
      "MultipleViewsDemo: update/2 received message: \#{inspect(message)}"
    )

    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: key_char}}
      when key_char in ["1", "2", "3"] ->
        {%{model | selected_tab: String.to_integer(key_char)}, []}

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
    Raxol.Core.Runtime.Log.debug("MultipleViewsDemo: view/1")

    view do
      column style: %{gap: 1, padding: 1} do
        title_bar()

        box style: [[:border, :single], [:height, :fill], [:width, :fill]] do
          case model.selected_tab do
            1 ->
              box(
                title: "View 1",
                style: %{padding: 1},
                content: "Content for View 1"
              )

            2 ->
              box(
                title: "View 2",
                style: %{padding: 1},
                content: "Content for View 2"
              )

            3 ->
              box(
                title: "View 3",
                style: %{padding: 1},
                content: "Content for View 3"
              )
          end
        end

        status_bar(model.selected_tab)
      end
    end
  end

  defp title_bar do
    box style: %{width: :fill, padding: [0, 1]} do
      text(
        content: "Multiple Views Demo (Press 1, 2 or 3, or q/Ctrl+C to quit)"
      )
    end
  end

  defp status_bar(selected_tab) do
    box style: %{width: :fill, padding: [0, 1]} do
      text(content: "Selected: \#{selected_tab}")
    end
  end
end

Raxol.Core.Runtime.Log.info("MultipleViewsDemo: Starting Raxol...")
{:ok, _pid} = Raxol.start_link(MultipleViewsDemo, [])
Raxol.Core.Runtime.Log.info("MultipleViewsDemo: Raxol started. Running...")
