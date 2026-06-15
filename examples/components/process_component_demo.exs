# Process Component Demo
#
# Demonstrates crash-isolated components: a "heavy" widget runs in its
# own process. If it crashes, the app keeps running and the widget
# restarts with fresh state.
#
# Usage:
#   mix run examples/components/process_component_demo.exs

defmodule FileListWidget do
  @moduledoc false

  def init(props) do
    path = Map.get(props, :path, ".")
    files = list_files(path)
    {:ok, %{path: path, files: files, error: nil}}
  end

  def update(:refresh, state) do
    %{state | files: list_files(state.path)}
  end

  def update(:crash, _state) do
    raise "Intentional crash to demonstrate isolation!"
  end

  def render(state, _context) do
    file_lines =
      state.files
      |> Enum.take(10)
      |> Enum.map(fn f -> %{type: :text, content: "  #{f}", style: %{}} end)

    %{
      type: :container,
      children:
        [
          %{
            type: :text,
            content: "Files in #{state.path}:",
            style: %{bold: true}
          }
        ] ++
          file_lines,
      style: %{border: :single, padding: 1}
    }
  end

  defp list_files(path) do
    case File.ls(path) do
      {:ok, files} -> Enum.sort(files)
      {:error, _} -> ["(unable to list directory)"]
    end
  end
end

defmodule ProcessComponentDemo do
  use Raxol.Core.Runtime.Application

  @impl true
  def init(_context) do
    %{status: "Running"}
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c"}} ->
        {%{model | status: "Widget crashed! It will restart on next render."},
         []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Process Component Demo", style: [:bold]),
        text("Status: #{model.status}"),
        process_component(FileListWidget, %{path: "."}),
        text("Press 'c' to crash the widget, 'q' to quit")
      ]
    end
  end
end

{:ok, pid} = Raxol.start_link(ProcessComponentDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
