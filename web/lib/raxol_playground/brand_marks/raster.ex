defmodule RaxolPlayground.BrandMarks.Raster do
  @moduledoc """
  Renders one of the brand-mark paths as terminal cells.

  The integrations row inlines a mark as SVG, which a browser scales freely.
  A terminal has no such freedom: the smallest thing it can draw is a cell,
  so a mark reaching a terminal surface has to be resampled onto a grid of
  them. Braille carries the most detail per cell of any glyph block a
  monospace font reliably has (two by four dots), which is what makes a mark
  legible at three rows rather than at eight.

  This is a rendering of the artwork, not a redrawing of it. The path comes
  from the same official file `RaxolPlayground.BrandMarks` extracts for the
  page, it is scaled uniformly, and nothing is added to it. Choosing the grid
  is the caller's job and the only place proportion can be lost: a terminal
  cell is taller than it is wide, so an undistorted mark that is `rows` tall
  needs `aspect * rows * cell_aspect` columns, and rounding that to a whole
  number is what a caller has to keep small. `aspect/1` reports the number so
  the caller can check rather than guess.

  Only `M`, `L`, `H`, `V`, `C` and `Z` are understood, in both cases. An arc
  or a smooth-curve shorthand raises: its control points do not survive a
  naive coordinate scale, and a quietly wrong glyph is worse than a build
  error. The one mark this module is asked for uses `M`, `L`, `C` and `Z`,
  which is the same reason the refit that produced that file could be exact.
  """

  import Bitwise, only: [|||: 2]

  # Points per cubic segment. The curve is flattened before scaling rather
  # than after, so the sampled polyline is the curve's own shape at whatever
  # size it lands on.
  @flatten 32

  # Scanlines per pixel row. Four is where the mark's thin inner loop stops
  # dropping out at three rows; the cost is four crossing solves per row.
  @supersample 4

  @dot_cols 2
  @dot_rows 4
  @braille_blank 0x2800

  # Half-blocks: one cell carries a top and a bottom pixel, so a mark set in
  # them is solid where braille is dotted. That is the difference between a
  # mark that reads as a shape and one that reads as texture, which matters
  # when the thing AROUND it is texture -- see `Raxol.Effects.Halo`.
  @half %{{0, 0} => " ", {1, 0} => "▀", {0, 1} => "▄", {1, 1} => "█"}

  # Dot to bit, in the order Unicode assigns rather than in reading order:
  # the fourth row of a braille cell was added after the first three, so its
  # two dots carry the high bits instead of following on from the sixth.
  @braille_bits %{
    {0, 0} => 0x01,
    {0, 1} => 0x02,
    {0, 2} => 0x04,
    {1, 0} => 0x08,
    {1, 1} => 0x10,
    {1, 2} => 0x20,
    {0, 3} => 0x40,
    {1, 3} => 0x80
  }

  @commands ~w(M m L l H h V v C c)
  @closes ~w(Z z)

  @token ~r/[A-Za-z]|-?\d*\.?\d+(?:[eE][-+]?\d+)?/

  @typedoc "Rows of braille, every one exactly `cols` graphemes wide."
  @type cells :: [String.t()]

  @doc """
  Rasterize `path` onto a `cols` by `rows` grid of braille cells.

  Options:

    * `:cols`, `:rows` -- the cell grid, required. See the module doc on
      picking a pair that does not distort the mark.
    * `:fill_rule` -- `"evenodd"` or `nil` for SVG's `nonzero` default. A
      mark whose counter is wound the same way as its outer contour fills in
      solid under the wrong rule, which is a redrawn logo.
    * `:glyphs` -- `:braille` (default, two by four dots per cell, the most
      detail available) or `:half_block` (one by two, solid). Braille reads
      better alone; half-blocks read better set in a textured field, where a
      dotted mark and dotted texture blur into each other.
    * `:threshold` -- coverage a pixel must reach to be set. Defaults to
      `0.3` for braille and `0.42` for half-blocks: a half-block pixel is
      four times the area of a braille dot, so the same threshold fattens the
      mark rather than merely rendering it.

  Every returned row is padded to `cols`, so the caller gets a rectangle it
  can place in a layout rather than ragged lines.
  """
  @spec cells(String.t(), keyword()) :: cells()
  def cells(path, opts) when is_binary(path) do
    cols = Keyword.fetch!(opts, :cols)
    rows = Keyword.fetch!(opts, :rows)
    glyphs = Keyword.get(opts, :glyphs, :braille)
    threshold = Keyword.get(opts, :threshold, default_threshold(glyphs))

    rule =
      case Keyword.get(opts, :fill_rule) do
        "evenodd" -> :evenodd
        nil -> :nonzero
        other -> raise ArgumentError, "unsupported fill-rule #{inspect(other)}"
      end

    {sub_cols, sub_rows} = subdivision(glyphs)

    path
    |> subpaths()
    |> coverage(cols * sub_cols, rows * sub_rows, rule)
    |> pack(glyphs, cols, rows, threshold)
  end

  defp default_threshold(:braille), do: 0.3
  defp default_threshold(:half_block), do: 0.42

  defp subdivision(:braille), do: {@dot_cols, @dot_rows}
  defp subdivision(:half_block), do: {1, 2}

  @doc """
  Width over height of `path`'s artwork, ignoring the canvas around it.

  The canvas is not the mark: `virtuals.svg` sits in a square viewBox and is
  half again as wide as it is tall, so fitting the viewBox would leave a
  third of the grid empty and the mark smaller than the row it sits in.
  """
  @spec aspect(String.t()) :: float()
  def aspect(path) when is_binary(path) do
    {x0, y0, x1, y1} = path |> subpaths() |> bbox()
    (x1 - x0) / (y1 - y0)
  end

  # --- path to polylines -----------------------------------------------------

  defp subpaths(path) do
    @token
    |> Regex.scan(path)
    |> List.flatten()
    |> walk(%{cmd: nil, x: 0.0, y: 0.0, sx: 0.0, sy: 0.0, cur: [], out: []})
  end

  defp walk([], state),
    do: state |> close() |> Map.fetch!(:out) |> Enum.reverse()

  defp walk([token | rest], state) when token in @closes do
    state = close(state)
    walk(rest, %{state | x: state.sx, y: state.sy})
  end

  defp walk([token | rest], state) when token in @commands do
    walk(rest, %{state | cmd: token})
  end

  defp walk([token | _rest], _state)
       when byte_size(token) == 1 and token not in @commands do
    case Integer.parse(token) do
      :error ->
        raise ArgumentError, "unsupported path command #{inspect(token)}"

      _ ->
        raise ArgumentError, "path data begins with a number"
    end
  end

  defp walk(_tokens, %{cmd: nil}) do
    raise ArgumentError, "path data begins with a number"
  end

  defp walk(tokens, state) do
    arity = arity(state.cmd)
    {args, rest} = Enum.split(tokens, arity)

    if length(args) < arity do
      raise ArgumentError, "path ends mid-#{state.cmd}"
    end

    state = step(state, state.cmd, Enum.map(args, &to_float/1))

    # A repeated coordinate set continues the previous command, and after a
    # moveto it continues as a lineto rather than as a second moveto -- which
    # is why a subpath with several points does not become several subpaths.
    walk(rest, %{state | cmd: repeat(state.cmd)})
  end

  defp arity(cmd) when cmd in ~w(M m L l), do: 2
  defp arity(cmd) when cmd in ~w(H h V v), do: 1
  defp arity(cmd) when cmd in ~w(C c), do: 6

  defp repeat("M"), do: "L"
  defp repeat("m"), do: "l"
  defp repeat(cmd), do: cmd

  defp step(state, cmd, [x, y]) when cmd in ~w(M m) do
    {ax, ay} = point(state, cmd, x, y)
    state = close(state)
    %{state | cur: [{ax, ay}], x: ax, y: ay, sx: ax, sy: ay}
  end

  defp step(state, cmd, [x, y]) when cmd in ~w(L l) do
    {ax, ay} = point(state, cmd, x, y)
    %{state | cur: [{ax, ay} | state.cur], x: ax, y: ay}
  end

  defp step(state, cmd, [x]) when cmd in ~w(H h) do
    ax = if cmd == "h", do: state.x + x, else: x
    %{state | cur: [{ax, state.y} | state.cur], x: ax}
  end

  defp step(state, cmd, [y]) when cmd in ~w(V v) do
    ay = if cmd == "v", do: state.y + y, else: y
    %{state | cur: [{state.x, ay} | state.cur], y: ay}
  end

  defp step(state, cmd, [x1, y1, x2, y2, x, y]) when cmd in ~w(C c) do
    # All three pairs of a relative curve are relative to the same start
    # point, so they are resolved before the pen moves.
    c1 = point(state, cmd, x1, y1)
    c2 = point(state, cmd, x2, y2)
    {ax, ay} = to = point(state, cmd, x, y)

    flattened = cubic({state.x, state.y}, c1, c2, to)
    %{state | cur: Enum.reverse(flattened) ++ state.cur, x: ax, y: ay}
  end

  defp point(state, cmd, x, y) do
    if lowercase?(cmd), do: {state.x + x, state.y + y}, else: {x, y}
  end

  defp lowercase?(<<c>>), do: c in ?a..?z

  defp cubic(from, control_1, control_2, to) do
    for step <- 1..@flatten do
      cubic_point(from, control_1, control_2, to, step / @flatten)
    end
  end

  defp cubic_point({x0, y0}, {x1, y1}, {x2, y2}, {x3, y3}, t) do
    u = 1 - t
    u2 = u * u
    t2 = t * t
    weights = {u2 * u, 3 * u2 * t, 3 * u * t2, t2 * t}

    {weighted(x0, x1, x2, x3, weights), weighted(y0, y1, y2, y3, weights)}
  end

  defp weighted(v0, v1, v2, v3, {a, b, c, d}) do
    a * v0 + b * v1 + c * v2 + d * v3
  end

  defp close(%{cur: []} = state), do: state

  defp close(%{cur: cur, out: out} = state) do
    %{state | cur: [], out: [Enum.reverse(cur) | out]}
  end

  defp to_float(token) do
    case Float.parse(token) do
      {f, ""} -> f
      _ -> raise ArgumentError, "bad number #{inspect(token)} in path data"
    end
  end

  # --- polylines to coverage -------------------------------------------------

  defp bbox(subpaths) do
    points = List.flatten(subpaths)
    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))
    {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
  end

  # Scaled to FILL the grid on both axes independently. The caller has
  # already chosen a grid whose physical shape matches the mark's, so the
  # anisotropy here is the terminal cell's, and cancelling it is what keeps
  # the rendered mark square with the original.
  defp coverage(subpaths, width, height, rule) do
    {x0, y0, x1, y1} = bbox(subpaths)
    scale = {width / (x1 - x0), height / (y1 - y0)}
    edges = Enum.flat_map(subpaths, &scaled_edges(&1, {x0, y0}, scale))

    coverage_grid(edges, width, height, rule)
  end

  defp scaled_edges(subpath, {x0, y0}, {scale_x, scale_y}) do
    subpath
    |> Enum.map(fn {x, y} -> {(x - x0) * scale_x, (y - y0) * scale_y} end)
    |> polygon_edges()
  end

  defp polygon_edges([]), do: []
  defp polygon_edges([first | rest]), do: polygon_edges(rest, first, first, [])

  defp polygon_edges([], first, previous, edges) do
    add_edge(previous, first, edges)
  end

  defp polygon_edges([point | rest], first, previous, edges) do
    polygon_edges(rest, first, point, add_edge(previous, point, edges))
  end

  defp add_edge({_, y}, {_, y}, edges), do: edges
  defp add_edge({ax, ay}, {bx, by}, edges), do: [{ax, ay, bx, by} | edges]

  defp coverage_grid(edges, width, height, rule) do
    for row <- 0..(height - 1),
        {col, covered} <- row_coverage(edges, row, width, rule),
        into: %{},
        do: {{col, row}, covered}
  end

  defp row_coverage(edges, row, width, rule) do
    Enum.reduce(0..(@supersample - 1), %{}, fn slice, acc ->
      y = row + (slice + 0.5) / @supersample

      edges
      |> crossings(y)
      |> Enum.sort()
      |> spans(rule)
      |> Enum.reduce(acc, &span(&2, &1, width))
    end)
  end

  defp crossings(edges, y) do
    Enum.flat_map(edges, &crossing(&1, y))
  end

  defp crossing({ax, ay, bx, by}, y)
       when (ay <= y and y < by) or (by <= y and y < ay) do
    [{ax + (y - ay) / (by - ay) * (bx - ax), if(by > ay, do: 1, else: -1)}]
  end

  defp crossing(_edge, _y), do: []

  defp spans(crossings, :evenodd) do
    crossings
    |> Enum.map(&elem(&1, 0))
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn [from, to] -> {from, to} end)
  end

  defp spans(crossings, :nonzero) do
    {_winding, _open, spans} =
      Enum.reduce(crossings, {0, nil, []}, &advance_winding/2)

    Enum.reverse(spans)
  end

  defp advance_winding({x, direction}, {winding, open, spans}) do
    winding_transition(x, winding, winding + direction, open, spans)
  end

  defp winding_transition(x, 0, next, _open, spans) when next != 0 do
    {next, x, spans}
  end

  defp winding_transition(x, _winding, 0, open, spans) do
    {0, nil, [{open, x} | spans]}
  end

  defp winding_transition(_x, _winding, next, open, spans) do
    {next, open, spans}
  end

  defp span(acc, {from, to}, width) do
    first = max(0, floor(from))
    last = min(width - 1, floor(to))

    Enum.reduce(first..last//1, acc, fn col, acc ->
      covered = min(col + 1, to) - max(col, from)

      if covered > 0 do
        Map.update(
          acc,
          col,
          covered / @supersample,
          &(&1 + covered / @supersample)
        )
      else
        acc
      end
    end)
  end

  # --- coverage to braille ---------------------------------------------------

  defp pack(grid, :braille, cols, rows, threshold) do
    for row <- 0..(rows - 1) do
      for col <- 0..(cols - 1), into: "" do
        braille_char(grid, col, row, threshold)
      end
    end
  end

  defp pack(grid, :half_block, cols, rows, threshold) do
    for row <- 0..(rows - 1) do
      for col <- 0..(cols - 1), into: "" do
        top = set?(grid, col, row * 2, threshold)
        bottom = set?(grid, col, row * 2 + 1, threshold)
        Map.fetch!(@half, {top, bottom})
      end
    end
  end

  defp braille_char(grid, col, row, threshold) do
    bits =
      Enum.reduce(@braille_bits, 0, fn {{dx, dy}, bit}, bits ->
        key = {col * @dot_cols + dx, row * @dot_rows + dy}

        if Map.get(grid, key, 0.0) >= threshold,
          do: bits ||| bit,
          else: bits
      end)

    <<@braille_blank + bits::utf8>>
  end

  defp set?(grid, x, y, threshold) do
    if Map.get(grid, {x, y}, 0.0) >= threshold, do: 1, else: 0
  end
end
