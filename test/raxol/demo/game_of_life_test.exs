defmodule Raxol.Demo.GameOfLifeTest do
  use ExUnit.Case, async: true

  alias Raxol.Demo.GameOfLife

  describe "create_grid/3" do
    test "creates grid with correct dimensions" do
      grid = GameOfLife.create_grid(10, 5)

      assert map_size(grid) == 50

      for x <- 0..9, y <- 0..4 do
        assert Map.has_key?(grid, {x, y})
      end
    end

    test "respects density parameter" do
      high_density = GameOfLife.create_grid(100, 100, 1.0)
      low_density = GameOfLife.create_grid(100, 100, 0.0)

      high_pop = GameOfLife.population(high_density)
      low_pop = GameOfLife.population(low_density)

      assert high_pop == 10_000
      assert low_pop == 0
    end
  end

  describe "create_r_pentomino/2" do
    test "creates R-pentomino pattern in center" do
      grid = GameOfLife.create_r_pentomino(20, 20)
      pop = GameOfLife.population(grid)

      assert pop == 5
    end
  end

  describe "step/3" do
    test "evolves grid according to rules" do
      # Create a simple blinker (horizontal line of 3)
      grid = %{
        {4, 5} => 1,
        {5, 5} => 1,
        {6, 5} => 1
      }

      # Fill in zeros for the rest
      grid =
        for x <- 0..9, y <- 0..9, into: grid do
          if Map.has_key?(grid, {x, y}) do
            {{x, y}, Map.get(grid, {x, y})}
          else
            {{x, y}, 0}
          end
        end

      # After one step, blinker should become vertical
      new_grid = GameOfLife.step(grid, 10, 10)

      assert Map.get(new_grid, {5, 4}) > 0
      assert Map.get(new_grid, {5, 5}) > 0
      assert Map.get(new_grid, {5, 6}) > 0
      assert Map.get(new_grid, {4, 5}) == 0
      assert Map.get(new_grid, {6, 5}) == 0
    end

    test "increases age of surviving cells" do
      grid = %{
        {5, 5} => 1,
        {6, 5} => 1,
        {5, 6} => 1,
        {6, 6} => 1
      }

      grid =
        for x <- 0..9, y <- 0..9, into: grid do
          if Map.has_key?(grid, {x, y}) do
            {{x, y}, Map.get(grid, {x, y})}
          else
            {{x, y}, 0}
          end
        end

      new_grid = GameOfLife.step(grid, 10, 10)

      # Block pattern should survive and age
      assert Map.get(new_grid, {5, 5}) == 2
      assert Map.get(new_grid, {6, 5}) == 2
    end
  end

  describe "render/3" do
    test "returns ANSI-formatted string" do
      # Live cells (age >= 1) emit ANSI; a random grid can come up all-dead.
      # Build an all-live grid so the escape assertion is deterministic.
      grid =
        for x <- 0..4, y <- 0..2, into: %{} do
          {{x, y}, 1}
        end

      output = GameOfLife.render(grid, 5, 3)

      assert is_binary(output)
      assert output =~ "\e["
    end

    test "renders dead cells as spaces" do
      grid =
        for x <- 0..4, y <- 0..2, into: %{} do
          {{x, y}, 0}
        end

      output = GameOfLife.render(grid, 5, 3)
      lines = String.split(output, "\r\n")

      assert length(lines) == 3
    end
  end

  describe "live_cells/1" do
    test "returns positions of all live cells" do
      grid = %{
        {1, 1} => 1,
        {2, 2} => 5,
        {3, 3} => 0
      }

      cells = GameOfLife.live_cells(grid)

      assert length(cells) == 2
      assert {1, 1} in cells
      assert {2, 2} in cells
      refute {3, 3} in cells
    end
  end

  describe "population/1" do
    test "counts live cells" do
      grid = %{
        {0, 0} => 1,
        {1, 0} => 3,
        {0, 1} => 0,
        {1, 1} => 10
      }

      assert GameOfLife.population(grid) == 3
    end
  end
end
