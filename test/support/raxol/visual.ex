defmodule Raxol.Test.Visual do
  @moduledoc """
  Provides utilities for visual testing of Raxol components.

  This module handles:
  - Component rendering verification
  - Layout testing
  - Style validation
  - Terminal output comparison
  - Cross-terminal compatibility testing

  ## Example

      defmodule MyComponent.VisualTest do
        use ExUnit.Case
        use Raxol.Test.Visual

        test 'renders correctly' do
          component = setup_visual_component(MyComponent)

          assert_renders_as component, fn output ->
            assert output =~ "Expected Content"
            assert_layout_matches output, width: 10, height: 5
          end
        end
      end
  """

  alias Raxol.Terminal.ScreenBuffer.Operations
  alias Raxol.Test.TestHelper

  defmacro __using__(_opts) do
    quote do
      import Raxol.Test.Visual
      import Raxol.Test.Visual.Matchers
    end
  end

  @doc """
  Sets up a component for visual testing.

  This function:
  1. Initializes the component
  2. Sets up the render context
  3. Configures the test terminal
  4. Prepares snapshot directories
  """
  def setup_visual_component(module, props \\ %{}) do
    {:ok, component} = Raxol.Test.Unit.setup_isolated_component(module, props)

    # Defensive check: ensure component is a map with :module and :state
    validate_component_structure!(component)

    # Set up render context
    terminal = TestHelper.setup_test_terminal()
    theme = Raxol.UI.Theming.Theme.default_theme()
    initial_width = 80
    initial_height = 24

    render_context = %{
      terminal: terminal,
      viewport: %{width: initial_width, height: initial_height},
      max_width: initial_width,
      max_height: initial_height,
      theme: theme
    }

    Map.merge(component, %{render_context: render_context})
  end

  @doc """
  Captures the rendered output of a component using a direct rendering pipeline.
  Ensures that the component is rendered in a controlled environment suitable for visual testing.

  The `component_struct` argument is expected to be a Raxol component map, potentially
  containing a `:render_context` key with `:width`, `:height`, and `:theme` information.
  If `:render_context` or its keys are missing, defaults will be applied.

  Returns the terminal output as a string for comparison.
  """
  @spec capture_render(map() | term(), map() | list()) ::
          String.t()
  def capture_render(component_or_map_or_view, opts \\ %{}) do
    opts =
      case opts do
        opts when is_list(opts) -> Enum.into(opts, %{})
        opts when is_map(opts) -> opts
        _ -> %{}
      end

    {view_map, width, height, theme} =
      extract_render_context(component_or_map_or_view, opts)

    elements_to_layout = ensure_list(view_map)

    layout_elements = apply_layout(elements_to_layout, width, height)
    raw_cells = render_to_cells(layout_elements, theme)
    cells_list = ensure_list(raw_cells)

    final_buffer = populate_buffer(cells_list, width, height)
    render_to_string(final_buffer, theme, opts)
  end

  defp extract_render_context(component_or_map_or_view, opts) do
    handle_render_context_extraction(
      view_is_map(component_or_map_or_view),
      component_or_map_or_view,
      opts
    )
  end

  defp handle_render_context_extraction(true, component_or_map_or_view, opts) do
    extract_render_details_from_view_map(component_or_map_or_view, opts)
  end

  defp handle_render_context_extraction(false, component_or_map_or_view, _opts) do
    extract_render_details(component_or_map_or_view)
  end

  defp view_is_map(map) when is_map(map), do: Map.has_key?(map, :type)
  defp view_is_map(_), do: false

  defp ensure_list(item) when is_list(item), do: item
  defp ensure_list(item), do: [item]

  # Re-pointed from the legacy layout stack (zero production callers) to
  # the live engine, the pipeline production actually renders through.
  # `apply_layout/3` takes a single element and recurses via
  # `:view`/`:children`, so wrap the top-level list the same way `view/1`
  # callbacks do -- every element in `elements` is laid out against the
  # same full available space.
  #
  # The live engine returns flat `:type`/`:x`/`:y`(/`:width`/`:height`)
  # maps instead of the legacy `:position`/`:size` tuples -- this is the
  # shape `Raxol.UI.Renderer.render_to_cells/2` (below) actually expects.
  defp apply_layout(elements, width, height) do
    Raxol.UI.Layout.Engine.apply_layout(
      %{type: :view, children: elements},
      %{width: width, height: height}
    )
  end

  defp render_to_cells(layout_elements, theme) do
    Raxol.UI.Renderer.render_to_cells(layout_elements, theme)
  end

  defp populate_buffer(cells_list, width, height) do
    initial_buffer = Raxol.Terminal.ScreenBuffer.new(width, height)

    Enum.reduce(cells_list, initial_buffer, &write_cell_to_buffer/2)
  end

  defp write_cell_to_buffer({x, y, char, fg, bg, attrs}, buffer) do
    actual_char =
      case char do
        nil -> ~c" "
        char -> char
      end

    Operations.write_char(buffer, x, y, actual_char, %{
      foreground: fg,
      background: bg,
      attrs: attrs
    })
  end

  defp write_cell_to_buffer(_unexpected_cell_data, buffer), do: buffer

  defp render_to_string(buffer, theme, opts) do
    # Check if we need HTML output (for snapshots) or plain text (for responsive tests)
    output_format = Map.get(opts, :output_format, :html)

    case output_format do
      :plain_text ->
        buffer.cells
        |> Enum.map_join("\n", &format_row/1)

      :html ->
        renderer_instance = Raxol.Terminal.Renderer.new(buffer, theme)
        Raxol.Terminal.Renderer.render(renderer_instance)
    end
  end

  defp format_row(row) do
    row
    |> Enum.map_join("", fn cell ->
      cell.char || " "
    end)
  end

  defp extract_render_details_from_view_map(view_map, _opts) do
    extract_render_details_from_view_map(view_map)
  end

  defp extract_render_details_from_view_map(view_map) do
    default_ctx = default_render_context()
    render_context_from_view_map = Map.get(view_map, :render_context)

    width =
      extract_dimension(
        render_context_from_view_map,
        view_map,
        :width,
        default_ctx.max_width
      )

    height =
      extract_dimension(
        render_context_from_view_map,
        view_map,
        :height,
        default_ctx.max_height
      )

    theme =
      extract_theme(render_context_from_view_map, view_map, default_ctx.theme)

    {view_map, width, height, theme}
  end

  defp extract_dimension(render_context, view_map, dimension, default) do
    [
      get_in(render_context, [:"max_#{dimension}"]),
      get_in(render_context, [:terminal, dimension]),
      Map.get(view_map, :"max_#{dimension}"),
      Map.get(view_map, dimension),
      default
    ]
    |> Enum.find(&(&1 != nil))
  end

  defp extract_theme(render_context, view_map, default) do
    [
      get_in(render_context, [:theme]),
      Map.get(view_map, :theme),
      default
    ]
    |> Enum.find(&(&1 != nil))
  end

  defp extract_render_details(component_or_map) when is_map(component_or_map) do
    render_context_from_component = Map.get(component_or_map, :render_context)
    default_ctx = default_render_context()

    width =
      extract_dimension(
        render_context_from_component,
        :width,
        default_ctx.max_width
      )

    height =
      extract_dimension(
        render_context_from_component,
        :height,
        default_ctx.max_height
      )

    theme = get_in(render_context_from_component, [:theme]) || default_ctx.theme

    current_context_for_render =
      build_render_context(
        default_ctx,
        render_context_from_component,
        width,
        height,
        theme
      )

    view_map = render_component(component_or_map, current_context_for_render)

    {view_map, width, height, theme}
  end

  defp extract_dimension(render_context, dimension, default) do
    [
      get_in(render_context, [:"max_#{dimension}"]),
      get_in(render_context, [:terminal, dimension]),
      default
    ]
    |> Enum.find(&(&1 != nil))
  end

  defp build_render_context(
         default_ctx,
         render_context_from_component,
         width,
         height,
         theme
       ) do
    base_context = Map.merge(default_ctx, render_context_from_component || %{})

    base_context
    |> Map.put(:max_width, width)
    |> Map.put(:max_height, height)
    |> Map.put(:theme, theme)
    |> update_terminal_dimensions(width, height)
    |> update_viewport_dimensions(width, height)
  end

  defp update_terminal_dimensions(context, width, height) do
    Map.update(context, :terminal, %{}, fn terminal_map ->
      terminal_map
      |> Map.put(:width, width)
      |> Map.put(:height, height)
    end)
  end

  defp update_viewport_dimensions(context, width, height) do
    Map.update(context, :viewport, %{}, fn viewport_map ->
      viewport_map
      |> Map.put(:width, width)
      |> Map.put(:height, height)
    end)
  end

  @doc """
  Verifies that a component renders as expected.

  Takes a function that can make assertions about the rendered output.
  """
  def assert_renders_as(component, assertions)
      when is_function(assertions, 1) do
    output = capture_render(component)
    assertions.(output)
  end

  @doc """
  Creates or updates a snapshot of the component's rendered output.

  Used for visual regression testing.
  """
  def snapshot_component(component, name, context) do
    output = capture_render(component)
    snapshot_path = Path.join([context.snapshots_dir, "#{name}.snap"])

    File.mkdir_p!(Path.dirname(snapshot_path))
    File.write!(snapshot_path, output)

    output
  end

  @doc """
  Compares a component's current render with its snapshot.

  Returns a detailed diff if there are differences.
  """
  def compare_with_snapshot(component, name, context) do
    current = capture_render(component)
    snapshot_path = Path.join([context.snapshots_dir, "#{name}.snap"])

    case File.read(snapshot_path) do
      {:ok, expected} ->
        compare_render_output(current, expected)

      {:error, :enoent} ->
        {:error, :no_snapshot}
    end
  end

  @doc """
  Tests a component's rendering across different terminal sizes.

  Verifies responsive behavior and layout adaptability.
  """
  def test_responsive_rendering(component, sizes) when is_list(sizes) do
    Enum.map(sizes, fn {width, height} ->
      # Create an updated render_context for this specific size
      updated_render_context =
        Map.merge(component.render_context, %{
          viewport: %{width: width, height: height},
          max_width: width,
          max_height: height
        })

      # Create a component instance with this specific render_context for capture_render
      component_for_size = %{component | render_context: updated_render_context}

      # Capture render at this size with plain text output format
      output = capture_render(component_for_size, %{output_format: :plain_text})

      # Return as a map for verification
      %{width: width, height: height, output: output}
    end)
  end

  @doc """
  Tests a component's rendering with different style themes.

  Verifies proper style application and theme switching.
  """
  def test_themed_rendering(component, themes) when is_map(themes) do
    Enum.map(themes, fn {name, partial_theme_map} ->
      # Get the original full theme struct from the component's render_context
      original_full_theme_struct = component.render_context.theme

      # Merge the partial_theme_map into the original_full_theme_struct
      # This ensures that :component_styles and other essential keys from the
      # original struct are preserved.
      updated_theme_struct =
        Map.merge(original_full_theme_struct, partial_theme_map)

      # Create a new component state with this updated theme struct for rendering
      component_for_this_theme =
        put_in(component.render_context.theme, updated_theme_struct)

      # Capture themed render
      output = capture_render(component_for_this_theme)

      # Return theme and output for verification
      {name, output}
    end)
  end

  # @doc """
  # Verifies that a component's layout adapts correctly to its container.
  #
  # Tests proper sizing, positioning, and constraint handling.
  # """
  # def verify_layout_constraints(component, constraints) do
  #   # Get current layout
  #   layout = get_component_layout(component)
  #
  #   # Verify each constraint
  #   Enum.reduce_while(constraints, :ok, fn
  #     {:min_width, min}, :ok ->
  #       if layout.width >= min, do: {:cont, :ok}, else: {:halt, {:error, :min_width}}
  #     {:max_width, max}, :ok ->
  #       if layout.width <= max, do: {:cont, :ok}, else: {:halt, {:error, :max_width}}
  #     {:min_height, min}, :ok ->
  #       if layout.height >= min, do: {:cont, :ok}, else: {:halt, {:error, :min_height}}
  #     {:max_height, max}, :ok ->
  #       if layout.height <= max, do: {:cont, :ok}, else: {:halt, {:error, :max_height}}
  #     {key, value}, :ok ->
  #       if layout[key] == value, do: {:cont, :ok}, else: {:halt, {:error, key}}
  #   end)
  # end

  # Private Helpers

  defp validate_component_structure!(component) when is_map(component) do
    validate_component_keys!(component)
  end

  defp validate_component_keys!(%{module: _, state: _}), do: :ok

  defp validate_render_component_structure!(component_map)
       when is_map(component_map) do
    validate_render_component_keys!(component_map)
  end

  defp validate_render_component_structure!(component_map) do
    raise ArgumentError,
          "render_component/2 expected a map with :module and :state keys, got: #{inspect(component_map)}"
  end

  defp validate_render_component_keys!(%{state: _}), do: :ok

  defp validate_render_component_keys!(component_map) do
    raise ArgumentError,
          "render_component/2 expected a map with :module and :state keys, got: #{inspect(component_map)}"
  end

  defp compare_render_output(current, expected) when current == expected,
    do: :ok

  defp compare_render_output(current, expected) do
    {:diff, compute_visual_diff(expected, current)}
  end

  @doc """
  Renders a component state within a controlled test environment.
  Accepts an optional context map.
  """
  def render_component(component_map, context \\ default_render_context()) do
    validate_render_component_structure!(component_map)

    # Extract the actual state and module from the component map
    state = component_map.state
    module = component_map.module

    # Pass the *actual* state and the *provided* context to the component's render/2 function
    rendered_view = module.render(state, context)

    # Return the raw view structure
    rendered_view
  end

  defp default_render_context do
    %{
      terminal: %{output: [], width: 80, cursor: {0, 0}, height: 24},
      theme: Raxol.UI.Theming.Theme.default_theme(),
      viewport: %{width: 80, height: 24},
      max_width: 80,
      max_height: 24,
      errors: %{},
      focused_component: nil,
      # Match typical full context structure
      terminal_size: {80, 24},
      # Add component_styles to fix button component test
      component_styles: %{
        button: %{
          active: "#3A8CC5",
          background: "#4A9CD5",
          foreground: "#FFFFFF",
          hover: "#5FB0E8"
        }
      }
    }
  end

  defp compute_visual_diff(expected, actual) do
    expected_lines = String.split(expected, "\n")
    actual_lines = String.split(actual, "\n")
    max_lines = max(length(expected_lines), length(actual_lines))

    expected_padded =
      expected_lines ++ List.duplicate("", max_lines - length(expected_lines))

    actual_padded =
      actual_lines ++ List.duplicate("", max_lines - length(actual_lines))

    Enum.zip(expected_padded, actual_padded)
    |> Enum.flat_map(fn
      {same, same} ->
        [{:eq, same <> "\n"}]

      {exp, act} ->
        [{:del, exp <> "\n"}, {:ins, act <> "\n"}]
    end)
  end
end
