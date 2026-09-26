defmodule Raxol.Core.Renderer.ViewDefaultStyleRenderTest do
  @moduledoc """
  Views written without a `style:` map must render (#1122). `box`/`panel`
  defaulted `style` to `[]`, which the cell renderer merged as a map and
  crashed on, and `container/1` emitted a `:container` type the layout
  engine dropped. Either way the screen stayed blank.

  Each view is built with the DSL an app gets from
  `use Raxol.Core.Runtime.Application` and rendered by a headless session.
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless

  defmodule FormApp do
    @moduledoc false
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{form: :none}

    @impl true
    def update({:show, form}, model), do: {%{model | form: form}, []}
    def update(_message, model), do: {model, []}

    @impl true
    def view(%{form: form}), do: form_view(form)

    @impl true
    def subscriptions(_model), do: []

    defp form_view(:none), do: text("")

    defp form_view(:box_padding) do
      box padding: 1 do
        text("x")
      end
    end

    defp form_view(:box_border) do
      box border: :single do
        text("x")
      end
    end

    defp form_view(:box_function),
      do: box(border: :single, children: [text("x")])

    defp form_view(:box_bg),
      do: box(border: :single, bg: :blue, children: [text("x")])

    defp form_view(:box_keyword_style),
      do: box(style: [border: :single], children: [text("x")])

    defp form_view(:panel) do
      panel do
        text("x")
      end
    end

    defp form_view(:panel_function), do: panel(children: [text("x")])

    defp form_view(:container), do: container(children: [text("x"), text("y")])

    defp form_view(:row_keyword_style),
      do: row(style: [gap: 2], children: [text("x"), text("y")])

    defp form_view(:element_map_keyword_style),
      do: %{type: :box, style: [border: :single], children: [text("x")]}

    defp form_view(:element_map_nil_style),
      do: %{type: :box, style: nil, children: [text("x")]}
  end

  setup do
    case Process.whereis(Headless) do
      nil -> start_supervised!({Headless, [name: Headless]})
      _pid -> :ok
    end

    :ok
  end

  defp start(form) do
    id = :"view_default_style_#{form}"
    {:ok, ^id} = Headless.start(FormApp, id: id, width: 12, height: 5)
    :ok = Headless.send_message(id, {:show, form})
    id
  end

  defp screen_lines(form) do
    id = start(form)
    {:ok, screen} = Headless.screenshot(id)
    :ok = Headless.stop(id)
    screen |> String.split("\n") |> Enum.map(&String.trim_trailing/1)
  end

  describe "box" do
    test "top-level padding insets the child" do
      assert [_, " x" | _] = screen_lines(:box_padding)
    end

    test "top-level border in a do block frames the child" do
      assert ["┌──────────┐", "│x         │" | _] = screen_lines(:box_border)
    end

    test "top-level border in a function call frames the child" do
      assert ["┌──────────┐", "│x         │" | _] = screen_lines(:box_function)
    end

    test "a keyword style frames the child" do
      assert ["┌──────────┐", "│x         │" | _] =
               screen_lines(:box_keyword_style)
    end

    test "top-level bg fills the box" do
      id = start(:box_bg)
      {:ok, buffer} = Headless.get_buffer(id)
      :ok = Headless.stop(id)

      interior = buffer.cells |> Enum.at(2) |> Enum.at(5)
      assert interior.style.background == :blue
    end
  end

  describe "panel" do
    test "do block renders a bordered, padded child" do
      assert ["┌──────────┐", "│          │", "│ x        │" | _] =
               screen_lines(:panel)
    end

    test "function call renders a bordered, padded child" do
      assert ["┌──────────┐", "│          │", "│ x        │" | _] =
               screen_lines(:panel_function)
    end
  end

  describe "container" do
    test "stacks its children" do
      assert ["x", "y" | _] = screen_lines(:container)
    end
  end

  describe "row" do
    test "a keyword style gap spaces the children" do
      assert ["x  y" | _] = screen_lines(:row_keyword_style)
    end
  end

  describe "hand-built element maps" do
    test "a keyword style renders" do
      assert ["┌──────────┐", "│x         │" | _] =
               screen_lines(:element_map_keyword_style)
    end

    test "a nil style renders" do
      assert ["x" | _] = screen_lines(:element_map_nil_style)
    end
  end
end
