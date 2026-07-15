defmodule Raxol.Playground.Demos.HarnessDiffDemo do
  @moduledoc """
  Playground demo: pre-apply diff viewer for a proposed file edit.

  Exercises `Raxol.UI.Components.Harness.DiffViewer`'s Pierre-style
  rendering with a realistic before/after edit -- syntax-highlighted
  Elixir, a long unchanged run (so hunk folding visibly kicks in with the
  default `context: 3`), a couple of lines removed, a couple added.

  `[m]` cycles auto -> unified -> split. `[w]` toggles the simulated
  available width so `:auto` visibly flips between side-by-side (wide)
  and unified (narrow). `[f]` toggles folding: `context: 3` <-> `:all`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.DiffViewer

  @path "lib/orders/total.ex"

  @old_code """
  defmodule Orders.Total do
    @moduledoc "Order total calculation and formatting."

    @vat_rate 0.20

    def format(amount) do
      :erlang.float_to_binary(amount / 1, decimals: 2)
    end

    def currency_symbol(:usd), do: "$"
    def currency_symbol(:eur), do: "€"
    def currency_symbol(:gbp), do: "£"

    def calculate(items) do
      IO.inspect(items, label: "items")

      items
      |> Enum.map(& &1.price)
      |> Enum.sum()
    end

    def with_vat(total) do
      total * (1 + @vat_rate)
    end
  end
  """

  @new_code """
  defmodule Orders.Total do
    @moduledoc "Order total calculation and formatting."

    @vat_rate 0.20

    def format(amount) do
      :erlang.float_to_binary(amount / 1, decimals: 2)
    end

    def currency_symbol(:usd), do: "$"
    def currency_symbol(:eur), do: "€"
    def currency_symbol(:gbp), do: "£"

    def calculate(items) do
      items
      |> Enum.reject(&is_nil(&1.price))
      |> Enum.map(& &1.price)
      |> Enum.filter(&(&1 >= 0))
      |> Enum.sum()
    end

    def with_vat(total) do
      total * (1 + @vat_rate)
    end
  end
  """

  @wide_width 140
  @narrow_width 60

  @impl true
  def init(_context) do
    %{mode: :auto, width: @wide_width, context: 3}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("m") -> {%{model | mode: cycle_mode(model.mode)}, []}
      key_match("w") -> {%{model | width: toggle_width(model.width)}, []}
      key_match("f") -> {%{model | context: toggle_context(model.context)}, []}
      _ -> {model, []}
    end
  end

  defp cycle_mode(:auto), do: :unified
  defp cycle_mode(:unified), do: :split
  defp cycle_mode(:split), do: :auto

  defp toggle_width(@wide_width), do: @narrow_width
  defp toggle_width(@narrow_width), do: @wide_width

  defp toggle_context(:all), do: 3
  defp toggle_context(_context), do: :all

  @impl true
  def view(model) do
    {:ok, diff_state} =
      DiffViewer.init(
        path: @path,
        old: @old_code,
        new: @new_code,
        mode: model.mode,
        width: model.width,
        language: "elixir",
        context: model.context
      )

    effective = DiffViewer.effective_mode(diff_state, %{})

    column style: %{gap: 1} do
      [
        text("Harness Diff Viewer Demo (Pierre-style)", style: [:bold]),
        divider(),
        DiffViewer.render(diff_state, %{}),
        divider(),
        text(
          "Mode: #{model.mode} (rendering: #{effective})  |  " <>
            "Width: #{model.width} cols  |  Fold: #{model.context}  |  " <>
            "[m] cycle mode  [w] toggle width  [f] toggle fold",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end
