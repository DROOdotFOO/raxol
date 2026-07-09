defmodule Raxol.Playground.Demos.EasingDemoTest do
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.EasingDemo

  # Mirror demo constants so tests break at compile time if they change.
  @last_easing_index 7
  @cycle_ticks 40

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp special_key(key) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: key}}
  end

  describe "init/1" do
    test "starts at first easing with zero progress" do
      model = EasingDemo.init(nil)
      assert model.easing_index == 0
      assert model.progress == 0.0
      assert model.tick == 0
    end
  end

  describe "easing navigation" do
    test "right cycles to next easing" do
      model = EasingDemo.init(nil)
      {model, []} = EasingDemo.update(special_key(:right), model)
      assert model.easing_index == 1
      assert model.progress == 0.0
    end

    test "left cycles to previous easing" do
      model = %{easing_index: 3, progress: 0.5, tick: 10}
      {model, []} = EasingDemo.update(special_key(:left), model)
      assert model.easing_index == 2
      assert model.progress == 0.0
    end

    test "left clamps at 0" do
      model = EasingDemo.init(nil)
      {model, []} = EasingDemo.update(special_key(:left), model)
      assert model.easing_index == 0
    end

    test "right clamps at last easing" do
      model = %{easing_index: @last_easing_index, progress: 0.0, tick: 0}
      {model, []} = EasingDemo.update(special_key(:right), model)
      assert model.easing_index == @last_easing_index
    end
  end

  describe "tick" do
    test "tick advances progress" do
      model = EasingDemo.init(nil)
      {model, []} = EasingDemo.update(:tick, model)
      assert model.tick == 1
      assert model.progress > 0.0
    end

    test "progress cycles back to 0" do
      model = %{easing_index: 0, progress: 0.0, tick: @cycle_ticks - 1}
      {model, []} = EasingDemo.update(:tick, model)
      assert model.progress == 0.0
    end
  end

  describe "reset" do
    test "r resets progress and tick" do
      model = %{easing_index: 2, progress: 0.7, tick: 28}
      {model, []} = EasingDemo.update(key_event("r"), model)
      assert model.progress == 0.0
      assert model.tick == 0
      assert model.easing_index == 2
    end
  end

  describe "subscribe/1" do
    test "returns interval subscription" do
      model = EasingDemo.init(nil)
      assert [_ | _] = EasingDemo.subscribe(model)
    end
  end

  describe "view/1" do
    test "returns element tree" do
      model = EasingDemo.init(nil)
      view = EasingDemo.view(model)
      assert is_map(view)
    end
  end

  describe "unknown events" do
    test "unknown events pass through" do
      model = EasingDemo.init(nil)
      {result, []} = EasingDemo.update(:unknown, model)
      assert result == model
    end
  end
end
