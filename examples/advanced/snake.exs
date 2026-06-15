# Snake
#
# A classic snake game rendered with text characters.
# Head = @, body = o, food = X
#
# Usage:
#   mix run examples/advanced/snake.exs

defmodule SnakeGame do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @width 30
  @height 15
  @initial_length 4
  @tick_interval_ms 120
  @initial_food {7, 7}

  @impl true
  def init(_context) do
    %{
      direction: :right,
      chain: Enum.map(@initial_length..1//-1, fn x -> {x, 0} end),
      food: @initial_food,
      alive: true
    }
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_up}} ->
        {%{model | direction: next_dir(model.direction, :up)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_down}} ->
        {%{model | direction: next_dir(model.direction, :down)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_left}} ->
        {%{model | direction: next_dir(model.direction, :left)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :key_right}} ->
        {%{model | direction: next_dir(model.direction, :right)}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      :tick ->
        {move_snake(model), []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    score = length(model.chain) - @initial_length

    column style: %{padding: 1, gap: 1} do
      [
        box title: "Snake | Score: #{score} | Arrows to move | q to quit",
            style: %{border: :single, padding: 0} do
          column do
            if model.alive do
              render_board(model)
            else
              [text("Game Over! Final score: #{score}", style: [:bold])]
            end
          end
        end
      ]
    end
  end

  @impl true
  def subscribe(%{alive: true}) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end

  def subscribe(_model), do: []

  # -- Board rendering --

  defp render_board(%{chain: [head | tail], food: food}) do
    for y <- 0..(@height - 1) do
      line =
        for x <- 0..(@width - 1), into: "" do
          cond do
            {x, y} == head -> "@"
            {x, y} in tail -> "o"
            {x, y} == food -> "X"
            true -> " "
          end
        end

      text(line)
    end
  end

  # -- Game logic --

  defp move_snake(model) do
    [head | _] = model.chain
    next = next_pos(head, model.direction)

    cond do
      not in_bounds?(next) or next in model.chain ->
        %{model | alive: false}

      next == model.food ->
        new_food = random_food([next | model.chain])
        %{model | chain: [next | model.chain], food: new_food}

      true ->
        %{model | chain: [next | Enum.drop(model.chain, -1)]}
    end
  end

  defp in_bounds?({x, y}), do: x >= 0 and x < @width and y >= 0 and y < @height

  defp random_food(occupied) do
    food = {Enum.random(0..(@width - 1)), Enum.random(0..(@height - 1))}
    if food in occupied, do: random_food(occupied), else: food
  end

  defp next_pos({x, y}, :up), do: {x, y - 1}
  defp next_pos({x, y}, :down), do: {x, y + 1}
  defp next_pos({x, y}, :left), do: {x - 1, y}
  defp next_pos({x, y}, :right), do: {x + 1, y}

  defp next_dir(:up, :down), do: :up
  defp next_dir(:down, :up), do: :down
  defp next_dir(:left, :right), do: :left
  defp next_dir(:right, :left), do: :right
  defp next_dir(_current, new), do: new
end

Raxol.Core.Runtime.Log.info("SnakeGame: Starting...")
{:ok, pid} = Raxol.start_link(SnakeGame, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
