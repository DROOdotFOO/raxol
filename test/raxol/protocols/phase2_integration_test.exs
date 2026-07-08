# Mock plugin for testing
defmodule MockPlugin do
  def render(_plugin, _opts) do
    "Mock Plugin Rendered"
  end

  def apply_style(plugin, style) do
    Map.put(plugin, :applied_style, style)
  end

  def get_style(plugin) do
    Map.get(plugin, :applied_style, %{})
  end

  def handle_event(_plugin, event, state) do
    {:ok, :mock_handled, Map.put(state, :last_event, event.type)}
  end

  def can_handle?(_plugin, _event), do: true

  def get_event_listeners(_plugin), do: [:all]

  def serialize(plugin, :json) do
    Jason.encode!(%{mock_plugin: true, data: plugin})
  end

  def serialize(plugin, :binary) do
    :erlang.term_to_binary(plugin)
  end

  def serializable?(_plugin, format) when format in [:json, :binary], do: true
  def serializable?(_plugin, _format), do: false
end

defmodule Raxol.Protocols.Phase2IntegrationTest do
  use ExUnit.Case, async: true

  alias Raxol.Protocols.{
    ComponentFramework,
    EventSystemIntegration,
    PluginSystemIntegration
  }

  alias Raxol.Protocols.{EventHandler, Renderable, Serializable, Styleable}
  alias Raxol.Style.Colors.Color
  alias Raxol.UI.Components.Table
  alias Raxol.UI.Theming.Theme

  describe "ComponentFramework" do
    test "creates components with protocol support" do
      component = ComponentFramework.component(
        __MODULE__,
        :test_component,
        %{title: "Test", count: 42},
        style: %{color: :red},
        theme: %{background: :blue}
      )

      assert component.type == :test_component
      assert component.props.title == "Test"
      assert component.style.color == :red
      assert component.theme.background == :blue
    end

    test "renders components using Renderable protocol" do
      component = ComponentFramework.component(__MODULE__, :button, %{text: "Click me"})
      rendered = Renderable.render(component, [])

      assert String.contains?(rendered, "button Component")
      assert String.contains?(rendered, "text: \"Click me\"")
    end

    test "applies styles using Styleable protocol" do
      component = ComponentFramework.component(__MODULE__, :widget, %{})
      styled = Styleable.apply_style(component, %{bold: true, color: :green})

      assert styled.style.bold == true
      assert styled.style.color == :green
    end

    test "handles events using EventHandler protocol" do
      handler = fn _comp, event, state ->
        {:ok, :updated, Map.put(state, :handled, event.type)}
      end

      component = ComponentFramework.component(__MODULE__, :interactive, %{})
      |> ComponentFramework.on_event(:click, handler)

      event = %{type: :click, data: %{x: 10, y: 20}}
      {:ok, _updated, new_state} = EventHandler.handle_event(component, event, %{})

      assert new_state.handled == :click
    end

    test "manages component children" do
      parent = ComponentFramework.component(__MODULE__, :container, %{})
      child1 = ComponentFramework.component(__MODULE__, :item, %{id: 1})
      child2 = ComponentFramework.component(__MODULE__, :item, %{id: 2})

      parent_with_children = parent
      |> ComponentFramework.add_child(child1)
      |> ComponentFramework.add_child(child2)

      assert length(parent_with_children.children) == 2
      assert Enum.at(parent_with_children.children, 0).props.id == 1
      assert Enum.at(parent_with_children.children, 1).props.id == 2
    end

    test "serializes components" do
      component = ComponentFramework.component(__MODULE__, :data, %{value: "test"})
      json = Serializable.serialize(component, :json)

      assert String.contains?(json, "\"type\":\"data\"")
      assert String.contains?(json, "\"value\":\"test\"")
    end
  end

  describe "PluginSystemIntegration" do
    test "creates protocol-aware plugins" do
      plugin = PluginSystemIntegration.ProtocolPlugin.new(
        MockPlugin,
        id: :test_plugin,
        name: "Test Plugin",
        version: "1.0.0"
      )

      assert plugin.id == :test_plugin
      assert plugin.name == "Test Plugin"
      assert plugin.version == "1.0.0"
      assert MapSet.member?(plugin.capabilities, :renderable)
    end

    test "plugin registry manages plugins" do
      {:ok, registry} = PluginSystemIntegration.PluginRegistry.start_link()

      {:ok, plugin_id} = PluginSystemIntegration.PluginRegistry.register_plugin(
        registry,
        MockPlugin,
        id: :mock,
        name: "Mock Plugin"
      )

      plugin = PluginSystemIntegration.PluginRegistry.get_plugin(registry, plugin_id)
      assert plugin.name == "Mock Plugin"

      plugins = PluginSystemIntegration.PluginRegistry.list_plugins(registry)
      assert length(plugins) == 1

      :ok = PluginSystemIntegration.PluginRegistry.unregister_plugin(registry, plugin_id)
      empty_list = PluginSystemIntegration.PluginRegistry.list_plugins(registry)
      assert Enum.empty?(empty_list)
    end

    test "finds plugins by capability" do
      {:ok, registry} = PluginSystemIntegration.PluginRegistry.start_link()

      PluginSystemIntegration.PluginRegistry.register_plugin(
        registry,
        MockPlugin,
        id: :renderable_plugin
      )

      renderable_plugins = PluginSystemIntegration.PluginRegistry.find_plugins_by_capability(
        registry,
        :renderable
      )

      assert length(renderable_plugins) == 1
      assert hd(renderable_plugins).id == :renderable_plugin
    end
  end

  describe "EventSystemIntegration" do
    test "creates protocol events" do
      event = EventSystemIntegration.ProtocolEvent.new(:test_event, %{key: "value"})

      assert event.type == :test_event
      assert event.data.key == "value"
      assert is_integer(event.timestamp)
      refute event.propagation_stopped
    end

    test "stops event propagation" do
      event = EventSystemIntegration.ProtocolEvent.new(:test_event)
      stopped = EventSystemIntegration.ProtocolEvent.stop_propagation(event)

      assert stopped.propagation_stopped == true
      refute EventSystemIntegration.ProtocolEvent.should_propagate?(stopped)
    end

    test "creates event bus" do
      bus = EventSystemIntegration.create_event_bus()
      handler = fn _comp, _event, state -> {:ok, :handled, state} end

      updated_bus = EventSystemIntegration.add_handler(bus, :click, handler)
      event = EventSystemIntegration.ProtocolEvent.new(:click)

      results = EventSystemIntegration.dispatch_through_bus(updated_bus, event)
      assert length(results) == 1
    end

    test "event bus with middleware" do
      middleware = fn _event, results ->
        Enum.map(results, fn result -> {:middleware_processed, result} end)
      end

      bus = EventSystemIntegration.create_event_bus(middleware: [middleware])
      handler = fn _comp, _event, state -> {:ok, :handled, state} end

      updated_bus = EventSystemIntegration.add_handler(bus, :test, handler)
      event = EventSystemIntegration.ProtocolEvent.new(:test)

      results = EventSystemIntegration.dispatch_through_bus(updated_bus, event)
      assert match?([{:middleware_processed, _}], results)
    end
  end

  describe "UIComponentImplementations" do
    test "renders table component" do
      columns = [
        %{id: :name, label: "Name"},
        %{id: :age, label: "Age"}
      ]

      data = [
        %{name: "Alice", age: 30},
        %{name: "Bob", age: 25}
      ]

      table = %Table{
        id: :test_table,
        columns: columns,
        data: data,
        options: %{paginate: false, searchable: false, sortable: false}
      }

      rendered = Renderable.render(table, width: 40)

      assert String.contains?(rendered, "Name")
      assert String.contains?(rendered, "Age")
      assert String.contains?(rendered, "Alice")
      assert String.contains?(rendered, "Bob")
    end

    test "table handles keyboard events" do
      table = %Table{
        id: :nav_table,
        data: [%{id: 1}, %{id: 2}, %{id: 3}],
        selected_row: 0
      }

      event = %{type: :key_press, data: %{key: :arrow_down}}
      {:ok, updated_table, _state} = EventHandler.handle_event(table, event, %{})

      assert updated_table.selected_row == 1
    end

    test "table applies styles" do
      table = %Table{id: :styled_table}
      styled = Styleable.apply_style(table, %{border_color: :blue})

      assert styled.style.border_color == :blue
    end
  end

  describe "ThemeImplementations" do
    test "renders theme preview" do
      theme = Theme.new(%{
        name: "Test Theme",
        colors: %{primary: "#FF0000", secondary: "#00FF00"},
        dark_mode: true
      })

      rendered = Renderable.render(theme, format: :preview, width: 50)

      assert String.contains?(rendered, "Test Theme")
      assert String.contains?(rendered, "Dark Mode: Yes")
    end

    test "renders color palette" do
      theme = Theme.new(%{
        name: "Color Theme",
        colors: %{red: "#FF0000", green: "#00FF00", blue: "#0000FF"}
      })

      rendered = Renderable.render(theme, format: :palette, width: 60)

      assert String.contains?(rendered, "Color Palette")
      assert String.contains?(rendered, "red")
      assert String.contains?(rendered, "#FF0000")
    end

    test "applies styles to theme" do
      theme = Theme.new(%{name: "Base Theme"})
      styled = Styleable.apply_style(theme, %{button: %{color: :red}})

      component_styles = styled.component_styles || %{}
      assert component_styles[:button][:color] == :red
    end

    test "serializes theme to JSON" do
      theme = Theme.new(%{
        name: "JSON Theme",
        colors: %{primary: "#FFFFFF"},
        dark_mode: false
      })

      json = Serializable.serialize(theme, :json)
      decoded = Jason.decode!(json)

      assert decoded["name"] == "JSON Theme"
      assert decoded["dark_mode"] == false
      assert decoded["colors"]["primary"] == "#FFFFFF"
    end

    test "color renders with different formats" do
      color = Color.from_rgb(255, 128, 0)

      swatch = Renderable.render(color, format: :swatch)
      hex = Renderable.render(color, format: :hex)
      rgb = Renderable.render(color, format: :rgb)
      ansi = Renderable.render(color, format: :ansi)

      assert String.contains?(swatch, "\e[48;2;255;128;0m")
      assert hex == "#FF8000"
      assert rgb == "rgb(255, 128, 0)"
      assert String.contains?(ansi, "SAMPLE TEXT")
    end
  end

  describe "Protocol Composition" do
    test "data structure implements multiple protocols" do
      data = %{
        content: "Multi-protocol test",
        style: %{bold: true, color: :blue},
        event_handlers: %{
          click: fn _self, _event, state -> {:ok, :clicked, state} end
        }
      }

      # Test Renderable
      rendered = Renderable.render(data, [])
      assert String.contains?(rendered, "Multi-protocol test")

      # Test Styleable
      styled = Styleable.apply_style(data, %{italic: true})
      assert styled.style.italic == true
      assert styled.style.bold == true

      # Test EventHandler
      event = %{type: :click, data: %{}}
      {:ok, :clicked, _state} = EventHandler.handle_event(data, event, %{})

      # Test Serializable
      json = Serializable.serialize(data, :json)
      assert String.contains?(json, "Multi-protocol test")
    end

    test "protocol chaining works correctly" do
      component = ComponentFramework.component(__MODULE__, :chain_test, %{value: 1})

      result = component
      |> Styleable.apply_style(%{color: :red})
      |> Styleable.merge_styles(%{bold: true})
      |> ComponentFramework.set_props(%{value: 2})
      |> ComponentFramework.set_state(%{active: true})

      assert result.style.color == :red
      assert result.style.bold == true
      assert result.props.value == 2
      assert result.state.active == true
    end
  end
end
