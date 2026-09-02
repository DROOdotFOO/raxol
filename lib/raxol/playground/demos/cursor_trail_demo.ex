defmodule Raxol.Playground.Demos.CursorTrailDemo do
  @moduledoc "Playground demo: animated cursor trail with presets."
  use Raxol.Core.Runtime.Application

  alias Raxol.Effects.CursorTrail

  @width 40
  @height 14
  @tick_interval_ms 50
  @decay_rate 0.15
  @presets [:rainbow, :minimal, :comet]

  @impl true
  def init(_context) do
    %{
      trail: CursorTrail.rainbow(),
      cursor: {div(@width, 2), div(@height, 2)},
      mode: :manual,
      preset: :rainbow,
      tick: 0,
      dx: 1,
      dy: 1
    }
  end

  @impl true
  def update(message, model) do
    case message do
      key_match(:up) ->
        {move_cursor(model, 0, -1), []}

      key_match(:down) ->
        {move_cursor(model, 0, 1), []}

      key_match(:left) ->
        {move_cursor(model, -1, 0), []}

      key_match(:right) ->
        {move_cursor(model, 1, 0), []}

      key_match(" ") ->
        {toggle_mode(model), []}

      key_match(:char, char: ch)
      when ch in ["1", "2", "3"] ->
        {switch_preset(model, ch), []}

      :tick ->
        {tick_model(model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    mode_label = if model.mode == :manual, do: "MANUAL", else: "AUTO"
    preset_label = model.preset |> to_string() |> String.upcase()
    grid_lines = build_grid(model)

    column style: %{gap: 0} do
      [
        text("Cursor Trail Demo", style: [:bold]),
        text("Preset: #{preset_label}  Mode: #{mode_label}", style: [:dim]),
        text(""),
        render_grid(grid_lines),
        text(""),
        text("Trail points: #{Kernel.length(model.trail.points)}",
          style: [:dim]
        ),
        text("[arrows] move  [space] auto/manual  [1/2/3] preset",
          style: [:dim]
        )
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end

  defp build_grid(model) do
    {cx, cy} = model.cursor

    for y <- 0..(@height - 1) do
      for x <- 0..(@width - 1) do
        grid_char(model.trail, x, y, cx, cy)
      end
      |> Enum.join()
    end
  end

  defp grid_char(_trail, cx, cy, cx, cy), do: "@"

  defp grid_char(trail, x, y, _cx, _cy) do
    case find_point(trail, x, y) do
      nil -> "."
      point -> trail_char(point, trail.config)
    end
  end

  defp render_grid(lines) do
    column style: %{gap: 0} do
      Enum.map(lines, fn line -> text(line, fg: :cyan) end)
    end
  end

  defp find_point(trail, x, y) do
    Enum.find(trail.points, fn %{position: {px, py}} -> px == x and py == y end)
  end

  defp trail_char(point, config) do
    idx = point.age
    chars = config.chars
    char_idx = rem(idx, Kernel.length(chars))
    Enum.at(chars, char_idx)
  end

  defp toggle_mode(model) do
    new_mode = if model.mode == :manual, do: :auto, else: :manual
    %{model | mode: new_mode}
  end

  defp switch_preset(model, ch) do
    idx = String.to_integer(ch) - 1
    preset = Enum.at(@presets, idx)
    trail = make_trail(preset)
    %{model | preset: preset, trail: trail}
  end

  # snippet:start
  defp move_cursor(model, dx, dy) do
    {cx, cy} = model.cursor
    nx = Raxol.Core.Utils.Math.clamp(cx + dx, 0, @width - 1)
    ny = Raxol.Core.Utils.Math.clamp(cy + dy, 0, @height - 1)
    trail = CursorTrail.update(model.trail, {nx, ny})
    %{model | cursor: {nx, ny}, trail: trail}
  end

  # snippet:end

  defp tick_model(%{mode: :auto} = model) do
    {cx, cy} = model.cursor
    {nx, new_dx} = bounce(cx + model.dx, model.dx, @width)
    {ny, new_dy} = bounce(cy + model.dy, model.dy, @height)
    trail = CursorTrail.update(model.trail, {nx, ny})

    %{
      model
      | cursor: {nx, ny},
        dx: new_dx,
        dy: new_dy,
        trail: trail,
        tick: model.tick + 1
    }
  end

  defp tick_model(model) do
    # In manual mode, just age existing points
    trail = %{model.trail | points: age_and_filter(model.trail)}
    %{model | trail: trail, tick: model.tick + 1}
  end

  defp age_and_filter(trail) do
    trail.points
    |> Enum.map(fn point ->
      new_age = point.age + 1
      opacity = :math.exp(-new_age * @decay_rate)
      %{point | age: new_age, opacity: opacity}
    end)
    |> Enum.filter(&(&1.opacity >= trail.config.min_opacity))
  end

  defp bounce(pos, _vel, limit) when pos >= limit, do: {limit - 1, -1}
  defp bounce(pos, _vel, _limit) when pos < 0, do: {0, 1}
  defp bounce(pos, vel, _limit), do: {pos, vel}

  defp make_trail(:rainbow), do: CursorTrail.rainbow()
  defp make_trail(:minimal), do: CursorTrail.minimal()
  defp make_trail(:comet), do: CursorTrail.comet()
end
