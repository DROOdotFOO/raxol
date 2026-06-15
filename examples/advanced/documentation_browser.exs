# Documentation Browser
#
# Browse Elixir module documentation with scrolling and navigation.
#
# Usage:
#   mix run examples/advanced/documentation_browser.exs

defmodule DocBrowser do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    modules =
      :code.all_available()
      |> Enum.map(fn {mod, _, _} -> List.to_atom(mod) end)
      |> Enum.filter(&String.starts_with?(Atom.to_string(&1), "Elixir."))
      |> Enum.sort()
      |> Enum.take(100)

    content = fetch_docs(List.first(modules))

    %{
      modules: modules,
      cursor: 0,
      scroll: 0,
      content_lines: String.split(content, "\n"),
      view_height: 20
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Module navigation
      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        new_cursor = max(0, model.cursor - 1)
        content = fetch_docs(Enum.at(model.modules, new_cursor))

        {%{
           model
           | cursor: new_cursor,
             scroll: 0,
             content_lines: String.split(content, "\n")
         }, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        new_cursor = min(length(model.modules) - 1, model.cursor + 1)
        content = fetch_docs(Enum.at(model.modules, new_cursor))

        {%{
           model
           | cursor: new_cursor,
             scroll: 0,
             content_lines: String.split(content, "\n")
         }, []}

      # Content scrolling
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "j"}} ->
        max_scroll = max(0, length(model.content_lines) - model.view_height)
        {%{model | scroll: min(model.scroll + 1, max_scroll)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "k"}} ->
        {%{model | scroll: max(model.scroll - 1, 0)}, []}

      # Quit
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      # Resize
      %Raxol.Core.Events.Event{type: :resize, data: %{height: h}} ->
        {%{model | view_height: max(1, h - 4)}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    selected_name = inspect(Enum.at(model.modules, model.cursor))
    visible = Enum.slice(model.content_lines, model.scroll, model.view_height)

    row do
      [
        box title: "Modules", style: %{border: :single, width: 30} do
          column do
            model.modules
            |> Enum.with_index()
            |> Enum.slice(max(0, model.cursor - 10), 20)
            |> Enum.map(fn {mod, idx} ->
              prefix = if idx == model.cursor, do: "> ", else: "  "
              style = if idx == model.cursor, do: [:bold], else: []
              text(prefix <> inspect(mod), style: style)
            end)
          end
        end,
        box title: selected_name, style: %{border: :single} do
          column do
            Enum.map(visible, fn line -> text(line) end)
          end
        end
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp fetch_docs(nil), do: "(no module selected)"

  defp fetch_docs(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, :elixir, _, %{"en" => doc}, _} ->
        doc

      {:docs_v1, _, :elixir, _, :none, _} ->
        "(No module documentation for #{inspect(module)})"

      {:error, _} ->
        "(Documentation not available for #{inspect(module)})"

      _ ->
        "(Could not parse docs for #{inspect(module)})"
    end
  rescue
    _ -> "(Error loading docs for #{inspect(module)})"
  end
end

Raxol.Core.Runtime.Log.info("DocBrowser: Starting...")
{:ok, pid} = Raxol.start_link(DocBrowser, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
