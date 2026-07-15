defmodule Raxol.Test.CrossTerminal.RenderOracle do
  @moduledoc """
  Reference implementation of the R1 incremental-render emit (proposal v3) plus
  the autonomous grid oracle. Prototypes the design so its ALGORITHM can be
  property-tested before the production code exists: emit bytes, replay through
  the reference emulator, compare grids.

  One emit vocabulary:

      keyframe (prev == nil or dims differ): "\\e[2J" + every row, CUP-addressed
      diff:                                  changed rows only, CUP-addressed
      per row y:  "\\e[{y+1};1H\\e[0m\\e[2K" <> render_row(buffer, y)

  `render_row/2` renders a single row in isolation, prototyping the G1
  `Renderer.render_rows/1` the proposal calls for.
  """

  alias Raxol.Terminal.{Renderer, ScreenBuffer}
  alias Raxol.Terminal.Buffer.Queries
  alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer

  @doc "Render one row in isolation, style-batched (prototypes G1)."
  def render_row(buffer, y) do
    row = Enum.at(buffer.cells, y)

    %{buffer | cells: [row], height: 1}
    |> Renderer.new(%{}, %{}, true)
    |> Renderer.render()
  end

  @doc "Row indices where prev and next differ (all rows when prev is nil / dims differ)."
  def changed_rows(nil, next), do: Enum.to_list(0..(next.height - 1))

  def changed_rows(prev, next) do
    if dims_differ?(prev, next) do
      Enum.to_list(0..(next.height - 1))
    else
      Enum.filter(0..(next.height - 1), fn y ->
        Enum.at(prev.cells, y) != Enum.at(next.cells, y)
      end)
    end
  end

  defp dims_differ?(prev, next),
    do: prev.width != next.width or prev.height != next.height

  defp keyframe?(nil, _next), do: true
  defp keyframe?(prev, next), do: dims_differ?(prev, next)

  @doc "The v3 emit for going from prev (or nil) to next."
  def emit(prev, next) do
    body =
      Enum.map_join(changed_rows(prev, next), "", fn y ->
        "\e[#{y + 1};1H\e[0m\e[2K" <> render_row(next, y)
      end)

    if keyframe?(prev, next), do: "\e[2J" <> body, else: body
  end

  @doc "Grid after replaying keyframe(next) into a fresh emulator (the 'full' path)."
  def grid_full(next), do: replay_grid(emit(nil, next), next)

  @doc "Grid after replaying keyframe(prev) then diff(prev, next) (the 'diff' path)."
  def grid_diff(prev, next),
    do: replay_grid(emit(nil, prev) <> emit(prev, next), next)

  @doc "The buffer's own text, independent of any emit (ground truth for oracle 1)."
  def buffer_text(buffer), do: Queries.get_text(buffer)

  defp replay_grid(bytes, ref) do
    bytes
    |> Replayer.replay(width: ref.width, height: ref.height)
    |> Replayer.grid_text()
  end

  @doc "Build a test buffer. writes = [{x, y, char} | {x, y, char, style}]."
  def build(w, h, writes) do
    Enum.reduce(writes, ScreenBuffer.new(w, h), fn
      {x, y, ch}, buf -> ScreenBuffer.write_char(buf, x, y, ch)
      {x, y, ch, style}, buf -> ScreenBuffer.write_char(buf, x, y, ch, style)
    end)
  end

  @doc "A full WxH buffer whose every cell is `char_fn.(x, y)`."
  def grid(w, h, char_fn) do
    writes = for y <- 0..(h - 1), x <- 0..(w - 1), do: {x, y, char_fn.(x, y)}
    build(w, h, writes)
  end
end
