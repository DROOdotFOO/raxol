defmodule Raxol.Test.PropertyGenerators do
  @moduledoc """
  Shared StreamData generators for property-based tests.

  Extracted from style_preservation_property_test.exs and extended
  for element, box, flex, and headless property tests.
  """
  use ExUnitProperties

  @named_colors [:red, :green, :blue, :yellow, :cyan, :magenta, :white, :black]
  @text_attrs [:bold, :italic, :underline, :strikethrough, :reverse, :dim]
  @border_types [:single, :double, :rounded, :ascii, :none]
  @divider_chars ["-", "=", "*", "~", "_"]
  @directions [:vertical, :horizontal]

  def named_colors, do: @named_colors

  def color_gen do
    one_of([
      member_of(@named_colors),
      tuple({integer(0..255), integer(0..255), integer(0..255)}),
      integer(0..255)
    ])
  end

  def text_attr_subset_gen do
    list_of(member_of(@text_attrs), min_length: 1, max_length: 3)
    |> map(&Enum.uniq/1)
  end

  def printable_text_gen do
    string(:printable, min_length: 1, max_length: 20)
    |> filter(fn s -> String.trim(s) != "" end)
  end

  def layout_space(overrides \\ %{}) do
    Map.merge(%{x: 0, y: 0, width: 80, height: 24}, overrides)
  end

  def style_map_gen do
    gen all(
          fg <- color_gen(),
          bg <- color_gen(),
          attrs <- list_of(member_of(@text_attrs), max_length: 2)
        ) do
      Enum.reduce(attrs, %{fg: fg, bg: bg}, fn attr, acc ->
        Map.put(acc, attr, true)
      end)
    end
  end

  def divider_gen do
    gen all(
          fg <- color_gen(),
          bg <- color_gen(),
          char <- member_of(@divider_chars)
        ) do
      %{type: :divider, style: %{fg: fg, bg: bg}, char: char}
    end
  end

  def spacer_gen do
    gen all(
          fg <- color_gen(),
          bg <- color_gen(),
          size <- integer(1..5),
          direction <- member_of(@directions)
        ) do
      %{
        type: :spacer,
        style: %{fg: fg, bg: bg},
        size: size,
        direction: direction
      }
    end
  end

  def box_style_gen do
    gen all(
          fg <- color_gen(),
          bg <- color_gen(),
          border_fg <- color_gen(),
          border_bg <- color_gen()
        ) do
      %{fg: fg, bg: bg, border_fg: border_fg, border_bg: border_bg}
    end
  end

  def box_gen do
    gen all(
          style <- box_style_gen(),
          border <- member_of(@border_types),
          padding <- integer(0..2),
          content <- printable_text_gen()
        ) do
      %{
        type: :box,
        children: [
          %{type: :text, content: content, fg: nil, bg: nil, style: []}
        ],
        style: style,
        border: border,
        padding: padding
      }
    end
  end

  def flex_children_gen(min \\ 2, max \\ 5) do
    list_of(
      gen all(content <- printable_text_gen()) do
        %{type: :text, content: content, fg: nil, bg: nil, style: []}
      end,
      min_length: min,
      max_length: max
    )
  end

  def border_type_gen do
    member_of(@border_types)
  end

  # OTP exit reasons for process crash isolation tests
  def crash_reason_gen do
    one_of([
      constant(:normal),
      constant(:shutdown),
      constant(:kill),
      constant(:noproc),
      constant({:shutdown, :timeout}),
      constant({:shutdown, :brutal_kill}),
      tuple({constant(:error), atom(:alphanumeric)}),
      tuple({constant(:exit), atom(:alphanumeric)})
    ])
  end

  @session_ids for i <- 0..99, do: "test_session_#{i}"

  def session_id_gen do
    member_of(@session_ids)
  end

  def unique_session_ids_gen(min \\ 1, max \\ 5) do
    list_of(session_id_gen(), min_length: min, max_length: max)
    |> map(&Enum.uniq/1)
    |> filter(fn ids -> length(ids) >= min end)
  end
end
