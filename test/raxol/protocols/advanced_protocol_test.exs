defmodule Raxol.Protocols.AdvancedProtocolTest do
  use ExUnit.Case, async: true

  alias Raxol.Protocols.{BehaviourAdapter, EventHandler, Styleable}
  alias Raxol.Terminal.{Renderer, ScreenBuffer}

  describe "Styleable protocol" do
    test "applies styles to maps" do
      data = %{content: "test"}
      style = %{foreground: {255, 0, 0}, bold: true}

      styled = Styleable.apply_style(data, style)
      assert styled.style == style
    end

    test "merges styles correctly" do
      data = %{style: %{bold: true}}
      new_style = %{italic: true, foreground: {0, 255, 0}}

      merged = Styleable.merge_styles(data, new_style)
      assert merged.style.bold == true
      assert merged.style.italic == true
      assert merged.style.foreground == {0, 255, 0}
    end

    test "converts styles to ANSI codes" do
      data = %{style: %{bold: true, foreground: {255, 0, 0}}}
      ansi = Styleable.to_ansi(data)

      assert ansi =~ "\e["
      assert ansi =~ "1"  # bold
      assert ansi =~ "38;2;255;0;0"  # RGB foreground
    end

    test "resets styles" do
      data = %{style: %{bold: true, italic: true}}
      reset = Styleable.reset_style(data)

      assert Map.get(reset, :style) == nil
    end

    test "handles color names" do
      data = %{style: %{foreground: :red, background: :blue}}
      ansi = Styleable.to_ansi(data)

      assert ansi =~ "31"  # red foreground
      assert ansi =~ "44"  # blue background
    end
  end

  describe "EventHandler protocol" do
    test "handles events with map handlers" do
      handler = %{
        event_handlers: %{
          click: fn _map, event, state ->
            {:ok, %{clicked: true}, Map.put(state, :last_event, event.type)}
          end
        }
      }

      event = %{type: :click, target: nil, timestamp: 123, data: %{}}
      {:ok, _updated, new_state} = EventHandler.handle_event(handler, event, %{})

      assert new_state.last_event == :click
    end

    test "returns unhandled for unknown events" do
      handler = %{event_handlers: %{}}
      event = %{type: :unknown, target: nil, timestamp: 123, data: %{}}

      result = EventHandler.handle_event(handler, event, %{})
      assert {:unhandled, _, _} = result
    end

    test "checks if handler can handle event" do
      handler = %{event_handlers: %{click: fn _, _, _ -> :ok end}}

      assert EventHandler.can_handle?(handler, %{type: :click})
      refute EventHandler.can_handle?(handler, %{type: :keypress})
    end

    test "gets event listeners" do
      handler = %{
        event_handlers: %{
          click: fn _, _, _ -> :ok end,
          keypress: fn _, _, _ -> :ok end
        }
      }

      listeners = EventHandler.get_event_listeners(handler)
      assert :click in listeners
      assert :keypress in listeners
    end

    test "subscribes to events" do
      handler = %{}
      subscribed = EventHandler.subscribe(handler, [:click, :keypress])

      assert subscribed.subscribed_events == [:click, :keypress]
    end

    test "unsubscribes from events" do
      handler = %{subscribed_events: [:click, :keypress, :focus]}
      unsubscribed = EventHandler.unsubscribe(handler, [:click])

      assert unsubscribed.subscribed_events == [:keypress, :focus]
    end

    test "handles function event handlers" do
      handler = fn self, event, state ->
        {:ok, self, Map.put(state, :handled, event.type)}
      end

      event = %{type: :test, target: nil, timestamp: 123, data: %{}}
      {:ok, _handler, new_state} = EventHandler.handle_event(handler, event, %{})

      assert new_state.handled == :test
    end
  end

  describe "BehaviourAdapter" do
    test "wraps renderer for protocol dispatch" do
      buffer = ScreenBuffer.new(10, 5)
      renderer = Renderer.new(buffer)
      wrapped = BehaviourAdapter.wrap_renderer(renderer)

      assert %BehaviourAdapter.RendererWrapper{module: ^renderer} = wrapped
    end

    test "wraps buffer for protocol dispatch" do
      buffer = ScreenBuffer.new(10, 5)
      wrapped = BehaviourAdapter.wrap_buffer(buffer)

      assert %BehaviourAdapter.BufferWrapper{module: ^buffer} = wrapped
    end

    test "wraps event handler for protocol dispatch" do
      handler = %{handle_event: fn _, _, _ -> :ok end}
      wrapped = BehaviourAdapter.wrap_event_handler(handler)

      assert %BehaviourAdapter.EventHandlerWrapper{module: ^handler} = wrapped
    end
  end

  describe "Renderer protocol implementations" do
    setup do
      buffer = ScreenBuffer.new(10, 5)
      renderer = Renderer.new(buffer, %{foreground: %{default: "#FFFFFF"}})
      {:ok, renderer: renderer}
    end

    test "renderer implements Styleable", %{renderer: renderer} do
      style = %{background: %{default: "#000000"}}
      styled = Styleable.apply_style(renderer, style)

      assert styled.theme.background == %{default: "#000000"}
      assert styled.theme.foreground == %{default: "#FFFFFF"}
    end

    test "renderer style can be reset", %{renderer: renderer} do
      reset = Styleable.reset_style(renderer)
      assert reset.theme == %{}
    end

    test "renderer converts to ANSI", %{renderer: renderer} do
      ansi = Styleable.to_ansi(renderer)
      assert is_binary(ansi)
    end
  end

  describe "Protocol composition" do
    test "data can implement multiple protocols" do
      # Map implements all our protocols
      data = %{content: "test", style: %{bold: true}}

      # Renderable
      rendered = Raxol.Protocols.Renderable.render(data, [])
      assert is_binary(rendered)

      # Styleable
      styled = Styleable.apply_style(data, %{italic: true})
      assert styled.style.italic == true

      # Serializable
      json = Raxol.Protocols.Serializable.serialize(data, :json)
      assert is_binary(json)

      # EventHandler
      with_handler = Map.put(data, :event_handlers, %{})
      can_handle = EventHandler.can_handle?(with_handler, %{type: :test})
      assert can_handle == false
    end
  end
end
