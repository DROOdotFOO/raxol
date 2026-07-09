defmodule Raxol.Playground.Demos.CursorTrailDemoTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.CursorTrailDemo

  # Derive initial cursor from demo's grid dimensions so tests stay in sync.
  @init_x div(40, 2)
  @init_y div(14, 2)

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp special_key(key) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
  end

  describe "init/1" do
    test "returns initial state with rainbow preset" do
      model = CursorTrailDemo.init(nil)
      assert model.cursor == {@init_x, @init_y}
      assert model.mode == :manual
      assert model.preset == :rainbow
      assert model.tick == 0
      assert model.trail.points == []
    end
  end

  describe "cursor movement" do
    test "arrow keys move cursor" do
      model = CursorTrailDemo.init(nil)
      {model, []} = CursorTrailDemo.update(special_key(:right), model)
      assert model.cursor == {@init_x + 1, @init_y}

      {model, []} = CursorTrailDemo.update(special_key(:down), model)
      assert model.cursor == {@init_x + 1, @init_y + 1}

      {model, []} = CursorTrailDemo.update(special_key(:left), model)
      assert model.cursor == {@init_x, @init_y + 1}

      {model, []} = CursorTrailDemo.update(special_key(:up), model)
      assert model.cursor == {@init_x, @init_y}
    end

    test "cursor clamps to grid bounds" do
      model = %{CursorTrailDemo.init(nil) | cursor: {0, 0}}
      {model, []} = CursorTrailDemo.update(special_key(:left), model)
      assert model.cursor == {0, 0}

      {model, []} = CursorTrailDemo.update(special_key(:up), model)
      assert model.cursor == {0, 0}
    end

    test "movement adds trail points" do
      model = CursorTrailDemo.init(nil)
      {model, []} = CursorTrailDemo.update(special_key(:right), model)
      assert model.trail.points != []
    end
  end

  describe "mode toggle" do
    test "space toggles manual/auto mode" do
      model = CursorTrailDemo.init(nil)
      assert model.mode == :manual

      {model, []} = CursorTrailDemo.update(key_event(" "), model)
      assert model.mode == :auto

      {model, []} = CursorTrailDemo.update(key_event(" "), model)
      assert model.mode == :manual
    end
  end

  describe "preset switching" do
    test "1/2/3 keys switch presets" do
      model = CursorTrailDemo.init(nil)

      {model, []} = CursorTrailDemo.update(key_event("2"), model)
      assert model.preset == :minimal

      {model, []} = CursorTrailDemo.update(key_event("3"), model)
      assert model.preset == :comet

      {model, []} = CursorTrailDemo.update(key_event("1"), model)
      assert model.preset == :rainbow
    end
  end

  describe "tick" do
    test "tick in auto mode moves cursor" do
      model = %{CursorTrailDemo.init(nil) | mode: :auto}
      {model, []} = CursorTrailDemo.update(:tick, model)
      assert model.tick == 1
      assert model.cursor != {@init_x, @init_y}
    end

    test "tick in manual mode increments tick" do
      model = CursorTrailDemo.init(nil)
      {model, []} = CursorTrailDemo.update(:tick, model)
      assert model.tick == 1
      assert model.cursor == {@init_x, @init_y}
    end
  end

  describe "subscribe/1" do
    test "returns interval subscription" do
      model = CursorTrailDemo.init(nil)
      assert [_ | _] = CursorTrailDemo.subscribe(model)
    end
  end

  describe "view/1" do
    test "returns element tree" do
      model = CursorTrailDemo.init(nil)
      view = CursorTrailDemo.view(model)
      assert is_map(view)
    end
  end

  describe "unknown events" do
    test "unknown events pass through" do
      model = CursorTrailDemo.init(nil)
      {result, []} = CursorTrailDemo.update(:unknown, model)
      assert result == model
    end
  end
end
