defmodule Raxol.Core.Runtime.Plugins.EventFilterTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.{EventFilter, PluginSupervisor}

  setup do
    start_supervised!(PluginSupervisor)
    :ok
  end

  # Fixture modules

  defmodule PassthroughPlugin do
    def filter_event(event, _state), do: {:ok, event}
  end

  defmodule ModifyPlugin do
    def filter_event(event, _state) do
      {:ok, Map.put(event, :modified, true)}
    end
  end

  defmodule AddTagPlugin do
    def filter_event(event, _state) do
      {:ok, Map.put(event, :tagged, true)}
    end
  end

  defmodule HaltPlugin do
    def filter_event(_event, _state), do: :halt
  end

  defmodule ErrorPlugin do
    def filter_event(_event, _state), do: {:error, :broken}
  end

  defmodule NoFilterPlugin do
    def hello, do: :world
  end

  defmodule CrashPlugin do
    def filter_event(_event, _state), do: raise("filter crash")
  end

  defp build_state(plugin_list) do
    %{
      load_order: Enum.map(plugin_list, &elem(&1, 0)),
      metadata:
        Map.new(plugin_list, fn {id, _, enabled} ->
          {id, %{enabled: enabled}}
        end),
      plugins:
        Map.new(plugin_list, fn {id, mod, _} ->
          {id, mod}
        end),
      plugin_states:
        Map.new(plugin_list, fn {id, _, _} ->
          {id, %{}}
        end)
    }
  end

  defp make_event(type \\ :key_press) do
    %{type: type, data: "test"}
  end

  describe "filter_event/2 with single plugin" do
    test "passthrough plugin returns event unchanged" do
      state = build_state([{:pass, PassthroughPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end

    test "modifier plugin adds key to event" do
      state = build_state([{:mod, ModifyPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result.modified == true
      assert result.type == :key_press
    end

    test "halt plugin returns :halt" do
      state = build_state([{:halt, HaltPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == :halt
    end

    test "plugin without filter_event/2 passes event through" do
      state = build_state([{:no_filter, NoFilterPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end

    test "error plugin logs warning and passes event through" do
      state = build_state([{:err, ErrorPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end

    test "crashing plugin is handled gracefully" do
      state = build_state([{:crash, CrashPlugin, true}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end
  end

  describe "filter_event/2 with disabled plugins" do
    test "disabled plugin is skipped" do
      state = build_state([{:halt, HaltPlugin, false}])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end

    test "only enabled plugins in chain are applied" do
      state =
        build_state([
          {:mod, ModifyPlugin, true},
          {:halt, HaltPlugin, false},
          {:tag, AddTagPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result.modified == true
      assert result.tagged == true
    end
  end

  describe "filter_event/2 with plugin chains" do
    test "modify then passthrough returns modified event" do
      state =
        build_state([
          {:mod, ModifyPlugin, true},
          {:pass, PassthroughPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result.modified == true
    end

    test "passthrough then halt returns :halt" do
      state =
        build_state([
          {:pass, PassthroughPlugin, true},
          {:halt, HaltPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result == :halt
    end

    test "halt stops further processing" do
      state =
        build_state([
          {:halt, HaltPlugin, true},
          {:mod, ModifyPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      # ModifyPlugin never runs because HaltPlugin halted
      assert result == :halt
    end

    test "multiple modifiers accumulate changes" do
      state =
        build_state([
          {:mod, ModifyPlugin, true},
          {:tag, AddTagPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result.modified == true
      assert result.tagged == true
    end

    test "error plugin in chain does not stop processing" do
      state =
        build_state([
          {:err, ErrorPlugin, true},
          {:mod, ModifyPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result.modified == true
    end

    test "crash plugin in chain does not stop processing" do
      state =
        build_state([
          {:crash, CrashPlugin, true},
          {:mod, ModifyPlugin, true}
        ])

      event = make_event()
      result = EventFilter.filter_event(state, event)
      assert result.modified == true
    end
  end

  describe "filter_event/2 edge cases" do
    test "empty load_order returns event unchanged" do
      state = build_state([])
      event = make_event()

      result = EventFilter.filter_event(state, event)
      assert result == event
    end

    test "plugin not found in plugins map logs error and continues" do
      state = %{
        load_order: [:missing],
        metadata: %{missing: %{enabled: true}},
        plugins: %{},
        plugin_states: %{}
      }

      event = make_event()
      result = EventFilter.filter_event(state, event)
      # Should continue past the missing plugin
      assert result == event
    end
  end
end
