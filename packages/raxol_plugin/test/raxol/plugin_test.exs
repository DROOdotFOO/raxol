defmodule Raxol.PluginTest do
  use ExUnit.Case, async: true

  alias Raxol.Plugin.Test.SamplePlugin
  alias Raxol.Plugin.Test.CustomPlugin

  describe "use Raxol.Plugin defaults" do
    test "init/1 must be implemented (SamplePlugin returns ok)" do
      assert {:ok, state} = SamplePlugin.init(%{key: "val"})
      assert state.config == %{key: "val"}
    end

    test "terminate/2 defaults to :ok" do
      {:ok, state} = SamplePlugin.init(%{})
      assert SamplePlugin.terminate(:normal, state) == :ok
    end

    test "enable/1 defaults to pass-through" do
      {:ok, state} = SamplePlugin.init(%{})
      assert {:ok, ^state} = SamplePlugin.enable(state)
    end

    test "disable/1 defaults to pass-through" do
      {:ok, state} = SamplePlugin.init(%{})
      assert {:ok, ^state} = SamplePlugin.disable(state)
    end

    test "filter_event/2 defaults to pass-through" do
      {:ok, state} = SamplePlugin.init(%{})
      assert {:ok, :my_event} = SamplePlugin.filter_event(:my_event, state)
    end

    test "handle_command/3 defaults to noop" do
      {:ok, state} = SamplePlugin.init(%{})
      assert {:ok, ^state, :noop} = SamplePlugin.handle_command(:cmd, [], state)
    end

    test "get_commands/0 defaults to empty list" do
      assert SamplePlugin.get_commands() == []
    end
  end

  describe "overridden callbacks" do
    test "enable/1 can be overridden" do
      {:ok, state} = CustomPlugin.init(%{})
      assert state.enabled == false
      assert {:ok, enabled} = CustomPlugin.enable(state)
      assert enabled.enabled == true
    end

    test "disable/1 can be overridden" do
      {:ok, state} = CustomPlugin.init(%{})
      {:ok, enabled} = CustomPlugin.enable(state)
      assert {:ok, disabled} = CustomPlugin.disable(enabled)
      assert disabled.enabled == false
    end

    test "filter_event/2 can halt" do
      {:ok, state} = CustomPlugin.init(%{})
      assert :halt = CustomPlugin.filter_event(:blocked, state)
    end

    test "filter_event/2 can transform events" do
      {:ok, state} = CustomPlugin.init(%{})
      assert {:ok, result} = CustomPlugin.filter_event(:ping, state)
      assert result.event == :ping
    end

    test "handle_command/3 can be overridden" do
      {:ok, state} = CustomPlugin.init(%{})

      assert {:ok, _state, "Hello, World!"} =
               CustomPlugin.handle_command(:greet, ["World"], state)
    end

    test "handle_command/3 can return errors" do
      {:ok, state} = CustomPlugin.init(%{})

      assert {:error, :intentional_failure, _state} =
               CustomPlugin.handle_command(:fail, [], state)
    end

    test "get_commands/0 can be overridden" do
      commands = CustomPlugin.get_commands()
      assert length(commands) == 2
      assert {:greet, :handle_greet, 1} in commands
    end

    test "terminate/2 can be overridden" do
      {:ok, state} = CustomPlugin.init(%{})
      assert CustomPlugin.terminate(:normal, state) == :cleaned_up
    end
  end
end
