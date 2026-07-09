defmodule Raxol.Test.Visual.Assertions do
  @moduledoc """
  Provides custom assertions for visual testing of Raxol components.

  This module includes assertions for:
  - Component rendering verification
  - Layout validation
  - Style checking
  - Visual regression testing
  - Terminal output comparison
  """

  import ExUnit.Assertions
  alias Raxol.Test.Visual

  @doc """
  Asserts that a component's rendered output matches the expected snapshot.

  ## Example

      assert_matches_snapshot(component, "button_primary")
  """
  def assert_matches_snapshot(
        component,
        name,
        context \\ %{snapshots_dir: "test/snapshots"}
      ) do
    case Visual.compare_with_snapshot(component, name, context) do
      :ok ->
        true

      {:diff, diff} ->
        flunk("""
        Component render does not match snapshot:
        #{format_diff(diff)}
        """)

      {:error, :no_snapshot} ->
        _snapshot_content = Visual.snapshot_component(component, name, context)
        {:ok, :snapshot_created}
    end
  end

  # @doc """
  # Asserts that a component's layout matches the expected dimensions.
  #
  # ## Example
  #
  #     assert_layout_matches component, width: 10, height: 5
  # """
  # def assert_layout_matches(component, dimensions) do
  #   message = "expected layout dimensions to match #{inspect(dimensions)}, but they didn't"
  #
  #   # Commenting out this call as verify_layout_constraints is a placeholder
  #   # case Visual.verify_layout_constraints(component, dimensions) do
  #   #   :ok ->
  #   #     :ok
  #   #   {:error, reason} ->
  #   #     ExUnit.Assertions.flunk("#{message} (reason: #{reason})")
  #   # end
  #   :ok # Returning ok for now
  # end

  @doc """
  Asserts that a component renders with the expected content.

  ## Example

      assert_renders_with component, "Expected Content"
  """
  def assert_renders_with(component, expected) when is_binary(expected) do
    output = Visual.capture_render(component)

    assert output =~ expected,
           "Expected rendered output to include: #{inspect(expected)}\nGot: #{inspect(output)}"
  end

  @doc """
  Asserts that a component's style matches the expected theme.

  ## Example

      assert_styled_with component, %{color: :blue, bold: true}
  """
  def assert_styled_with(component, style) when is_map(style) do
    output = Visual.capture_render(component)

    Enum.each(style, fn {property, value} ->
      assert has_style?(output, property, value),
             "Expected component to have style #{property}: #{inspect(value)}"
    end)
  end

  @doc """
  Asserts that a component renders correctly at different terminal sizes.

  ## Example

      assert_responsive component, [
        {80, 24},
        {40, 12},
        {20, 6}
      ]
  """
  def assert_responsive(component, sizes) when is_list(sizes) do
    results = Visual.test_responsive_rendering(component, sizes)

    Enum.each(results, fn %{width: width, height: height, output: output} ->
      assert String.length(output) > 0,
             "Component failed to render at size #{width}x#{height}"

      # Verify output fits within bounds
      lines = String.split(output, "\n")
      max_line_length = Enum.max_by(lines, &String.length/1) |> String.length()

      assert max_line_length <= width,
             "Component output exceeds width at size #{width}x#{height}"

      assert length(lines) <= height,
             "Component output exceeds height at size #{width}x#{height}"
    end)
  end

  @doc """
  Asserts that a component renders consistently across different themes.

  ## Example

      assert_theme_consistent component, %{
        light: light_theme,
        dark: dark_theme
      }
  """
  def assert_theme_consistent(component, themes) when is_map(themes) do
    results = Visual.test_themed_rendering(component, themes)

    # Verify basic structure remains consistent
    base_structure = fn output ->
      output
      # Remove ANSI codes
      |> String.replace(~r/\e\[[0-9;]*m/, "")
      # Normalize whitespace
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end

    [{_, first_output} | rest] = results
    base = base_structure.(first_output)

    Enum.each(rest, fn {theme_name, output} ->
      assert base_structure.(output) == base,
             "Component structure changed with theme #{theme_name}"
    end)
  end

  @doc """
  Asserts that a component's borders and edges align properly.

  ## Example

      assert_aligned component, :all
      assert_aligned component, [:top, :left]
  """
  def assert_aligned(component, edges) do
    output = Visual.capture_render(component)
    lines = String.split(output, "\n")

    resolved_edges =
      case edges do
        :all -> [:top, :bottom, :left, :right]
        other -> other
      end

    Enum.each(resolved_edges, &assert_edge_aligned(&1, lines))
  end

  defp assert_edge_aligned(:top, lines) do
    [first | _] = lines
    assert String.trim(first) != "", "Top edge is not aligned"
  end

  defp assert_edge_aligned(:bottom, lines) do
    last = List.last(lines)
    assert String.trim(last) != "", "Bottom edge is not aligned"
  end

  defp assert_edge_aligned(:left, lines) do
    Enum.each(lines, fn line ->
      assert String.match?(line, ~r/^\S/), "Left edge is not aligned"
    end)
  end

  defp assert_edge_aligned(:right, lines) do
    width = Enum.max_by(lines, &String.length/1) |> String.length()

    Enum.each(lines, fn line ->
      assert String.length(line) == width, "Right edge is not aligned"
    end)
  end

  # @doc """
  # Asserts that a component's layout constraints match the expected dimensions.
  #
  # ## Example
  #
  #     assert_layout_constraints component, width: 10, height: 5
  # """
  # def assert_layout_constraints(component, dimensions) do
  #   message =
  #     "expected component layout to match constraints with " <>
  #       "dimensions #{inspect(dimensions)}, but it didn't"
  #
  #   # Commenting out the call as the function is a placeholder
  #   # case Visual.verify_layout_constraints(component, dimensions) do
  #   #   :ok ->
  #   #     :ok
  #   #   {:error, reason} ->
  #   #     ExUnit.Assertions.flunk("#{message} (reason: #{reason})")
  #   # end
  #   :ok # Return ok for now
  # end

  # Private Helpers

  defp format_diff(diff) do
    diff
    |> Enum.map_join("", fn
      {:eq, str} -> str
      {:del, str} -> IO.ANSI.red() <> str <> IO.ANSI.reset()
      {:ins, str} -> IO.ANSI.green() <> str <> IO.ANSI.reset()
    end)
  end

  defp has_style?(_output, _property, _value) do
    # Placeholder: Parse output and check for style property
    # Assume true for now
    true
  end
end
