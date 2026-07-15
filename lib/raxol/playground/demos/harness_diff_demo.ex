defmodule Raxol.Playground.Demos.HarnessDiffDemo do
  @moduledoc """
  Playground demo: pre-apply diff viewer for a proposed file edit.

  Exercises `Raxol.UI.Components.Harness.DiffViewer` with a realistic
  before/after edit -- unchanged context lines, a couple of lines removed,
  a couple of lines added. `[m]` toggles between unified and split
  rendering.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.DiffViewer

  @path "lib/orders/total.ex"

  @old_code """
  defmodule Orders.Total do
    def calculate(items) do
      IO.inspect(items, label: "items")

      items
      |> Enum.map(& &1.price)
      |> Enum.sum()
    end
  end
  """

  @new_code """
  defmodule Orders.Total do
    def calculate(items) do
      items
      |> Enum.reject(&is_nil(&1.price))
      |> Enum.map(& &1.price)
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sum()
    end
  end
  """

  @impl true
  def init(_context) do
    %{mode: :unified}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("m") -> {%{model | mode: toggle_mode(model.mode)}, []}
      _ -> {model, []}
    end
  end

  defp toggle_mode(:unified), do: :split
  defp toggle_mode(:split), do: :unified

  @impl true
  def view(model) do
    {:ok, diff_state} =
      DiffViewer.init(
        path: @path,
        old: @old_code,
        new: @new_code,
        mode: model.mode
      )

    column style: %{gap: 1} do
      [
        text("Harness Diff Viewer Demo", style: [:bold]),
        divider(),
        DiffViewer.render(diff_state, %{}),
        divider(),
        text(
          "Mode: #{model.mode}  |  [m] toggle unified/split",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
