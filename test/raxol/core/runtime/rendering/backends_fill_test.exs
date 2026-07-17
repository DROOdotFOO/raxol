defmodule Raxol.Core.Runtime.Rendering.BackendsFillTest do
  @moduledoc """
  F0-buffer: `Backends.apply_cells_to_buffer/2` was rewritten from a
  per-cell `write_char` fold to the bulk `ScreenBuffer.fill_cells` row
  pass. This suite freezes the ORIGINAL implementation as the oracle --
  including its interleaved background inheritance, which reads the
  buffer state accumulated by earlier cells of the SAME batch -- and
  asserts the rewrite is result-identical on every semantic axis the
  old fold had: transform, sanitize, hyperlink threading, overwrite
  order, wide chars, and background inheritance chains.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.ScreenBuffer

  # --- frozen pre-F0-buffer implementation (verbatim semantics) -----------

  defp legacy_apply_cells_to_buffer(cells, state) do
    screen_buffer = ScreenBuffer.new(state.width, state.height)
    transformed_cells = legacy_transform(cells)

    Enum.reduce(transformed_cells, screen_buffer, fn {x, y, cell}, buffer ->
      style =
        cell
        |> legacy_extract_style()
        |> legacy_inherit_background(buffer, x, y)

      ScreenBuffer.write_char(buffer, x, y, cell.char || " ", style)
    end)
  end

  defp legacy_transform(cells) when is_list(cells) do
    Enum.map(cells, fn {x, y, char, fg, bg, attrs_list} ->
      {hyperlink, style_atoms} = legacy_split_hyperlink(attrs_list || [])
      attrs_map = Enum.into(style_atoms, %{}, fn atom -> {atom, true} end)

      cell_attrs =
        %{foreground: fg, background: bg}
        |> Map.merge(Map.take(attrs_map, [:bold, :underline, :italic]))
        |> legacy_put_hyperlink(hyperlink)

      cell = %Raxol.Terminal.Cell{char: legacy_sanitize(char), style: cell_attrs}
      {x, y, cell}
    end)
  end

  defp legacy_sanitize(<<c::utf8>>) when c < 0x20 or c == 0x7F, do: " "
  defp legacy_sanitize(char), do: char

  defp legacy_split_hyperlink(attrs_list) do
    Enum.reduce(attrs_list, {nil, []}, fn
      {:hyperlink, url}, {_url, atoms} -> {url, atoms}
      other, {url, atoms} -> {url, [other | atoms]}
    end)
  end

  defp legacy_put_hyperlink(style, nil), do: style
  defp legacy_put_hyperlink(style, url), do: Map.put(style, :hyperlink, url)

  defp legacy_extract_style(cell) do
    case Map.get(cell, :style) do
      nil -> %{foreground: Map.get(cell, :foreground), background: Map.get(cell, :background)}
      cell_style when is_map(cell_style) -> cell_style
      _ -> nil
    end
  end

  defp legacy_inherit_background(style, buffer, x, y) when is_map(style) do
    case Map.get(style, :background) do
      nil -> Map.put(style, :background, legacy_background_at(buffer, x, y))
      _painted -> style
    end
  end

  defp legacy_inherit_background(style, _buffer, _x, _y), do: style

  defp legacy_background_at(buffer, x, y) do
    case ScreenBuffer.get_cell(buffer, x, y) do
      %{style: %{background: bg}} -> bg
      _ -> nil
    end
  end

  defp cell_at(buffer, x, y), do: buffer.cells |> Enum.at(y) |> Enum.at(x)

  # --- targeted equivalence ------------------------------------------------

  test "plain styled cells produce the identical buffer" do
    cells = [
      {0, 0, "a", :red, nil, []},
      {1, 0, "b", :green, :black, [:bold]},
      {2, 1, "c", nil, nil, nil},
      {5, 1, "d", :white, :blue, [:underline, :italic]}
    ]

    state = %{width: 8, height: 3}

    assert Backends.apply_cells_to_buffer(cells, state) ==
             legacy_apply_cells_to_buffer(cells, state)
  end

  test "background inheritance chains through cells written earlier in the batch" do
    # parent paints a background run, child text over it has no background:
    # each child cell must inherit the parent's background (modal/button case)
    parent = for x <- 0..7, do: {x, 0, " ", nil, :magenta, []}
    child = for {ch, i} <- Enum.with_index(~w(B U T N)), do: {2 + i, 0, ch, :white, nil, []}
    cells = parent ++ child
    state = %{width: 8, height: 2}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 3, 0).style.background == :magenta
  end

  test "unpainted background over a pristine position stays nil" do
    cells = [{1, 1, "x", :red, nil, []}]
    state = %{width: 4, height: 3}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 1, 1).style.background == nil
  end

  test "control characters are sanitized to a blank" do
    cells = [{0, 0, "\t", :red, nil, []}, {1, 0, "\e", nil, nil, []}, {2, 0, <<0x7F>>, nil, nil, []}]
    state = %{width: 4, height: 1}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 0, 0).char == " "
    assert cell_at(new_buffer, 1, 0).char == " "
    assert cell_at(new_buffer, 2, 0).char == " "
  end

  test "hyperlink attrs thread into the cell style" do
    url = "https://raxol.io"
    cells = [{0, 0, "g", :cyan, nil, [:bold, {:hyperlink, url}]}, {1, 0, "o", :cyan, nil, [{:hyperlink, url}]}]
    state = %{width: 4, height: 1}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 0, 0).style.hyperlink == url
    assert cell_at(new_buffer, 0, 0).style.bold == true
  end

  test "non-bold/underline/italic attrs are dropped, as before" do
    cells = [{0, 0, "r", :red, nil, [:reverse, :bold]}]
    state = %{width: 2, height: 1}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 0, 0).style.bold == true
    assert cell_at(new_buffer, 0, 0).style.reverse == false
  end

  test "wide chars, overwrites, and out-of-bounds cells match the legacy fold" do
    cells = [
      {6, 0, "W", :red, nil, []},
      {5, 0, "字", :green, :blue, []},
      {0, 0, "x", nil, nil, []},
      {0, 0, "y", :yellow, nil, []},
      {9, 0, "o", nil, nil, []},
      {0, 5, "o", nil, nil, []}
    ]

    state = %{width: 8, height: 2}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 6, 0).wide_placeholder == true
    assert cell_at(new_buffer, 0, 0).char == "y"
  end

  test "nil char writes a blank" do
    cells = [{0, 0, nil, :red, nil, []}]
    state = %{width: 2, height: 1}

    new_buffer = Backends.apply_cells_to_buffer(cells, state)
    assert new_buffer == legacy_apply_cells_to_buffer(cells, state)
    assert cell_at(new_buffer, 0, 0).char == " "
  end

  # --- randomized equivalence ----------------------------------------------

  test "randomized cell streams produce buffers identical to the legacy fold" do
    :rand.seed(:exsss, {97, 83, 61})

    chars = ["A", "z", " ", "字", "🎉", "─", "\t", nil]
    fgs = [nil, :red, :green, :white, {255, 0, 128}]
    bgs = [nil, nil, nil, :black, :blue, {10, 20, 30}]
    attr_choices = [[], nil, [:bold], [:underline, :italic], [:reverse], [{:hyperlink, "https://x.io"}, :bold]]

    for round <- 1..10 do
      width = 4 + :rand.uniform(16)
      height = 1 + :rand.uniform(6)
      state = %{width: width, height: height}

      cells =
        for _ <- 1..(30 + :rand.uniform(250)) do
          {
            :rand.uniform(width + 2) - 1,
            :rand.uniform(height + 2) - 1,
            Enum.random(chars),
            Enum.random(fgs),
            Enum.random(bgs),
            Enum.random(attr_choices)
          }
        end

      assert Backends.apply_cells_to_buffer(cells, state) ==
               legacy_apply_cells_to_buffer(cells, state),
             "mismatch in round #{round} (#{width}x#{height})"
    end
  end
end
