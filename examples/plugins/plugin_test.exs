defmodule MyPluginTest do
  use ExUnit.Case, async: true

  alias Raxol.Plugins.MyPlugin

  describe "plugin manifest" do
    test "returns valid manifest structure" do
      manifest = MyPlugin.manifest()

      assert is_binary(manifest.id)
      assert is_binary(manifest.name)
      assert is_binary(manifest.version)
      assert is_binary(manifest.author)
      assert is_atom(manifest.module)
      assert is_list(manifest.provides)
      assert is_list(manifest.depends_on)
    end
  end

  describe "plugin lifecycle" do
    test "initializes with valid config" do
      config = %{enabled: true, debug: false}

      assert {:ok, state} = MyPlugin.init(config)
      assert state.config == config
      assert is_boolean(state.enabled)
    end

    test "handles enable/disable cycle" do
      config = %{enabled: true}
      {:ok, initial_state} = MyPlugin.init(config)

      assert {:ok, enabled_state} = MyPlugin.enable(initial_state)
      assert enabled_state.enabled == true

      assert {:ok, disabled_state} = MyPlugin.disable(enabled_state)
      assert disabled_state.enabled == false
    end

    test "terminates cleanly" do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)

      assert :ok = MyPlugin.terminate(:normal, state)
    end
  end

  describe "command handling" do
    setup do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)
      {:ok, enabled_state} = MyPlugin.enable(state)

      {:ok, state: enabled_state}
    end

    test "handles hello command", %{state: state} do
      assert {:ok, new_state, result} =
               MyPlugin.handle_command(:hello, [], state)

      assert is_binary(result)
      assert String.contains?(result, "Hello")
      assert new_state.enabled == true
    end

    test "returns error for unknown command", %{state: state} do
      assert {:error, reason, _state} =
               MyPlugin.handle_command(:unknown, [], state)

      assert String.contains?(reason, "Unknown command")
    end

    test "declares available commands" do
      commands = MyPlugin.get_commands()
      assert is_list(commands)
      assert {:hello, :handle_command, 3} in commands
    end
  end

  describe "event filtering" do
    setup do
      config = %{enabled: true}
      {:ok, state} = MyPlugin.init(config)
      {:ok, state: state}
    end

    test "passes through events by default", %{state: state} do
      event = {:key_press, "a"}
      assert {:ok, ^event} = MyPlugin.filter_event(event, state)
    end

    test "can modify events", %{state: state} do
      event = {:test_event, "data"}
      assert {:ok, filtered_event} = MyPlugin.filter_event(event, state)
      # Add assertions based on your plugin's behavior
    end
  end
end

# Integration test template
defmodule MyPluginIntegrationTest do
  use ExUnit.Case

  @moduletag :integration

  setup do
    config = %{enabled: true, debug: true}
    {:ok, config: config}
  end

  test "plugin integrates with plugin system", %{config: config} do
    assert {:ok, _state} = MyPlugin.init(config)
  end

  test "plugin commands are accessible" do
    commands = MyPlugin.get_commands()

    Enum.each(commands, fn {name, function, arity} ->
      assert is_atom(name)
      assert is_atom(function)
      assert is_integer(arity)
      assert arity >= 0
    end)
  end
end
