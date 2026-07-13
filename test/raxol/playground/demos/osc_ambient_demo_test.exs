defmodule Raxol.Playground.Demos.OscAmbientDemoTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Directive.Spawn
  alias Raxol.Playground.Demos.OscAmbientDemo

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  # A returned Spawn directive's fun is only invoked by the runtime executor,
  # never by these tests, so asserting its shape (and never calling `.fun`)
  # is what keeps this suite from writing real OSC escape sequences to stdout.
  defp assert_spawn_commands(commands, count) do
    assert length(commands) == count
    assert Enum.all?(commands, &match?(%Spawn{fun: fun} when is_function(fun, 0), &1))
  end

  describe "init/1" do
    test "starts idle at zero progress" do
      model = OscAmbientDemo.init(nil)
      assert model.status == :idle
      assert model.progress == 0
      assert model.pointer_idx == 0
    end
  end

  describe "start/pause" do
    test "space starts the task and emits a progress command" do
      model = OscAmbientDemo.init(nil)
      {model, commands} = OscAmbientDemo.update(key_event(" "), model)
      assert model.status == :running
      assert_spawn_commands(commands, 1)
    end

    test "space again pauses without emitting a command" do
      model = %{OscAmbientDemo.init(nil) | status: :running}
      {model, []} = OscAmbientDemo.update(key_event(" "), model)
      assert model.status == :paused
    end

    test "space is a no-op once done" do
      model = %{OscAmbientDemo.init(nil) | status: :done, progress: 100}
      {result, []} = OscAmbientDemo.update(key_event(" "), model)
      assert result == model
    end
  end

  describe "error/warning" do
    test "e sets error status and emits a progress command" do
      model = %{OscAmbientDemo.init(nil) | status: :running, progress: 40}
      {model, commands} = OscAmbientDemo.update(key_event("e"), model)
      assert model.status == :error
      assert_spawn_commands(commands, 1)
    end

    test "w sets warning status and emits a progress command" do
      model = %{OscAmbientDemo.init(nil) | status: :running, progress: 40}
      {model, commands} = OscAmbientDemo.update(key_event("w"), model)
      assert model.status == :warning
      assert_spawn_commands(commands, 1)
    end

    test "e/w are no-ops once done" do
      model = %{OscAmbientDemo.init(nil) | status: :done, progress: 100}
      {result, []} = OscAmbientDemo.update(key_event("e"), model)
      assert result == model
    end
  end

  describe "pointer shape" do
    test "c cycles the pointer index and emits a command" do
      model = OscAmbientDemo.init(nil)
      {model, commands} = OscAmbientDemo.update(key_event("c"), model)
      assert model.pointer_idx == 1
      assert_spawn_commands(commands, 1)
    end

    test "c wraps around" do
      model = %{OscAmbientDemo.init(nil) | pointer_idx: 4}
      {model, _commands} = OscAmbientDemo.update(key_event("c"), model)
      assert model.pointer_idx == 0
    end
  end

  describe "reset" do
    test "r resets status and progress and clears taskbar progress" do
      model = %{status: :error, progress: 88, pointer_idx: 2}
      {model, commands} = OscAmbientDemo.update(key_event("r"), model)
      assert model.status == :idle
      assert model.progress == 0
      assert model.pointer_idx == 2
      assert_spawn_commands(commands, 1)
    end
  end

  describe "tick" do
    test "tick advances progress while running" do
      model = %{OscAmbientDemo.init(nil) | status: :running, progress: 0}
      {model, commands} = OscAmbientDemo.update(:tick, model)
      assert model.progress == 4
      assert model.status == :running
      assert_spawn_commands(commands, 1)
    end

    test "tick reaching 100 marks done and fires notify + progress commands" do
      model = %{OscAmbientDemo.init(nil) | status: :running, progress: 98}
      {model, commands} = OscAmbientDemo.update(:tick, model)
      assert model.progress == 100
      assert model.status == :done
      assert_spawn_commands(commands, 2)
    end

    test "tick is ignored when not running" do
      model = OscAmbientDemo.init(nil)
      {result, []} = OscAmbientDemo.update(:tick, model)
      assert result == model
    end
  end

  describe "subscribe/1" do
    test "subscribes to tick only while running" do
      running = %{OscAmbientDemo.init(nil) | status: :running}
      assert [_ | _] = OscAmbientDemo.subscribe(running)
      assert OscAmbientDemo.subscribe(OscAmbientDemo.init(nil)) == []
    end
  end

  describe "view/1" do
    test "returns element tree" do
      model = OscAmbientDemo.init(nil)
      assert is_map(OscAmbientDemo.view(model))
    end
  end

  describe "unknown events" do
    test "unknown events pass through" do
      model = OscAmbientDemo.init(nil)
      {result, []} = OscAmbientDemo.update(:unknown, model)
      assert result == model
    end
  end
end
