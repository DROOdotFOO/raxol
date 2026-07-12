defmodule Raxol.Property.UIComponentTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Components.Input.Button
  alias Raxol.UI.Components.Input.TextInput
  alias Raxol.UI.Layout.{Flexbox, Grid}

  describe "Button component properties" do
    property "button initializes with any valid label" do
      check all(
              label <- string(:printable, min_length: 1, max_length: 50),
              enabled <- boolean(),
              max_runs: 500
            ) do
        {:ok, button} = Button.init(%{label: label, disabled: !enabled})

        assert button.label == label
        assert button.disabled == !enabled
      end
    end

    property "button state is consistent after init" do
      check all(
              label <- string(:printable, min_length: 1, max_length: 50),
              role <-
                member_of([:primary, :secondary, :danger, :success, :default]),
              max_runs: 500
            ) do
        {:ok, button} = Button.init(%{label: label, role: role})

        assert button.label == label
        assert button.role == role
        refute button.focused
        refute button.pressed
      end
    end
  end

  describe "TextInput component properties" do
    property "text input initializes with any valid value" do
      check all(
              initial <- string(:printable, max_length: 100),
              max_runs: 500
            ) do
        {:ok, state} = TextInput.init(%{value: initial})

        assert state.value == initial
        assert state.cursor_pos == 0
      end
    end

    property "text input respects max_length on init" do
      check all(
              max_length <- integer(1..100),
              max_runs: 500
            ) do
        {:ok, state} = TextInput.init(%{max_length: max_length})

        assert state.max_length == max_length
      end
    end

    property "text input focus/blur toggles state" do
      check all(
              initial <- string(:printable, max_length: 50),
              max_runs: 500
            ) do
        {:ok, state} = TextInput.init(%{value: initial})
        refute state.focused

        {focused_state, []} =
          TextInput.handle_event(%{type: :focus}, state, %{})

        assert focused_state.focused

        {blurred_state, []} =
          TextInput.handle_event(%{type: :blur}, focused_state, %{})

        refute blurred_state.focused
      end
    end
  end

  # Flex layout properties live in test/property/flex_layout_property_test.exs.

  describe "Grid layout properties" do
    property "grid places items in correct cells" do
      check all(
              rows <- integer(1..10),
              cols <- integer(1..10),
              items <-
                list_of(grid_item_generator(rows, cols),
                  max_length: rows * cols
                ),
              max_runs: 500
            ) do
        grid =
          Grid.new(
            rows: rows,
            columns: cols,
            children: items
          )

        {:ok, rendered} = Grid.render(grid)

        # Each item should be in valid cell
        Enum.each(rendered.children, fn child ->
          assert child.row in 1..rows
          assert child.column in 1..cols
        end)
      end
    end

    property "grid respects gap spacing" do
      check all(
              gap <- integer(0..20),
              rows <- integer(2..5),
              cols <- integer(2..5),
              max_runs: 500
            ) do
        grid =
          Grid.new(
            rows: rows,
            columns: cols,
            gap: gap
          )

        {:ok, layout} = Grid.calculate_spacing(grid)

        # Total gaps should be correct
        horizontal_gaps = (cols - 1) * gap
        vertical_gaps = (rows - 1) * gap

        assert layout.total_gap_width == horizontal_gaps
        assert layout.total_gap_height == vertical_gaps
      end
    end
  end

  # State Store property tests removed -- Store module is not planned.
  # If a Store GenServer is added in the future, re-add property tests for
  # atomic updates, subscriptions, and concurrent safety.

  describe "Component composition properties" do
    property "nested components maintain hierarchy" do
      check all(
              depth <- integer(1..5),
              breadth <- integer(1..5),
              max_runs: 200
            ) do
        root = create_nested_component(depth, breadth)

        # Verify depth
        actual_depth = measure_depth(root)
        assert actual_depth == depth

        # Verify total nodes
        total_nodes = count_nodes(root)
        expected = calculate_tree_size(depth, breadth)
        assert total_nodes == expected
      end
    end

    property "component lifecycle hooks execute in order" do
      check all(
              hook_count <- integer(1..10),
              max_runs: 200
            ) do
        order = :ets.new(:order, [:ordered_set, :public])

        hooks =
          for i <- 1..hook_count do
            fn -> :ets.insert(order, {i, :executed}) end
          end

        component = %{
          mount: Enum.take(hooks, div(hook_count, 3)),
          update: Enum.slice(hooks, div(hook_count, 3), div(hook_count, 3)),
          unmount: Enum.drop(hooks, 2 * div(hook_count, 3))
        }

        # Execute lifecycle
        execute_lifecycle(component)

        # Verify order
        executed = :ets.tab2list(order) |> Enum.map(&elem(&1, 0))
        assert executed == Enum.sort(executed)
      end
    end
  end

  # Generator helpers

  defp grid_item_generator(max_row, max_col) do
    gen all(
          row <- integer(1..max_row),
          col <- integer(1..max_col)
        ) do
      %{row: row, column: col, content: "Item"}
    end
  end

  # Helper functions

  defp create_test_component(id) do
    %{id: id, type: :test_component}
  end

  defp create_nested_component(1, _breadth), do: %{children: []}

  defp create_nested_component(depth, breadth) do
    children =
      for _ <- 1..breadth do
        create_nested_component(depth - 1, breadth)
      end

    %{children: children}
  end

  defp measure_depth(%{children: []}), do: 1

  defp measure_depth(%{children: children}) do
    1 + Enum.max(Enum.map(children, &measure_depth/1))
  end

  defp count_nodes(%{children: []}), do: 1

  defp count_nodes(%{children: children}) do
    1 + Enum.sum(Enum.map(children, &count_nodes/1))
  end

  defp calculate_tree_size(depth, breadth) do
    # Geometric series: (breadth^depth - 1) / (breadth - 1)
    if breadth == 1 do
      depth
    else
      # Use proper integer arithmetic - convert float result to integer
      numerator = round(:math.pow(breadth, depth)) - 1
      div(numerator, breadth - 1)
    end
  end

  defp execute_lifecycle(component) do
    Enum.each(component.mount || [], & &1.())
    Enum.each(component.update || [], & &1.())
    Enum.each(component.unmount || [], & &1.())
  end
end
