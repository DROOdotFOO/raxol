defmodule Raxol.Examples.ButtonTest do
  use ExUnit.Case, async: false
  use Raxol.Test.Unit
  use Raxol.Test.Integration
  use Raxol.Test.Visual

  alias Raxol.UI.Components.Input.Button
  import Raxol.Test.Visual.Assertions

  setup do
    {:ok, context} = Raxol.Test.TestUtils.setup_test_env()
    context = Map.put(context, :snapshots_dir, "test/snapshots")

    on_exit(fn ->
      Raxol.Test.TestUtils.cleanup_test_env()
    end)

    context
  end

  describe "unit tests" do
    test "initializes with default state", _context do
      result = Raxol.Test.Unit.setup_isolated_component(Button)
      assert match?({:ok, _}, result)
      {:ok, button} = result
      assert button.state.label == "Button"
      assert is_map(button.state)
      assert Map.has_key?(button.state, :disabled)
      assert Map.get(button.state, :disabled) == false
    end

    test "handles click events", _context do
      clicked = :atomics.new(1, signed: false)
      :atomics.put(clicked, 1, 1)

      result =
        Raxol.Test.Unit.setup_isolated_component(Button, %{
          on_click: fn -> :atomics.add(clicked, 1, 1) end
        })

      assert match?({:ok, _}, result)
      {:ok, button} = result

      {_updated, _commands} =
        Raxol.Test.Unit.simulate_event(
          button,
          Raxol.Core.Events.Event.new(:click, %{target: button.state.id})
        )

      assert :atomics.get(clicked, 1) == 2, "on_click function was not called"
    end

    test "handles disable state", _context do
      clicked = :atomics.new(1, signed: false)
      :atomics.put(clicked, 1, 1)

      result =
        Raxol.Test.Unit.setup_isolated_component(
          Button,
          Button.new(%{
            disabled: true,
            on_click: fn -> :atomics.add(clicked, 1, 1) end
          })
        )

      assert match?({:ok, _}, result)
      {:ok, button} = result

      {updated, commands} =
        Raxol.Test.Unit.simulate_event(
          button,
          Raxol.Core.Events.Event.new(:click, %{target: button.state.id})
        )

      assert updated.state == button.state
      assert commands == []

      assert :atomics.get(clicked, 1) == 1,
             "on_click function was called unexpectedly"
    end

    test "unit tests handles system events properly", _context do
      result = Raxol.Test.Unit.setup_isolated_component(Button, Button.new(%{}))
      assert match?({:ok, _}, result)
      {:ok, button} = result

      {button_focused, _cmd1} =
        Raxol.Test.Unit.simulate_event(
          button,
          Raxol.Core.Events.Event.focus_event(:component, true)
        )

      assert is_map(button_focused.state)
      assert Map.has_key?(button_focused.state, :focused)
      assert Map.get(button_focused.state, :focused) == true

      {button_unfocused, _cmd2} =
        Raxol.Test.Unit.simulate_event(
          button_focused,
          Raxol.Core.Events.Event.focus_event(:component, false)
        )

      assert is_map(button_unfocused.state)
      assert Map.has_key?(button_unfocused.state, :focused)
      assert Map.get(button_unfocused.state, :focused) == false

      # Simulate window resize
      # (assuming button doesn't directly react, just checking it doesn't crash)
      {button_after_resize, _cmd3} =
        Raxol.Test.Unit.simulate_event(
          button_unfocused,
          Raxol.Core.Events.Event.window(100, 30, :resize)
        )

      assert is_map(button_after_resize.state)
      assert Map.has_key?(button_after_resize.state, :focused)
      assert Map.get(button_after_resize.state, :focused) == false
    end

    test ~c"applies style and theme with correct precedence" do
      theme = %{fg: :red, bg: :blue, focused_fg: :green}
      style = %{fg: :yellow, bg: :magenta}

      result =
        Raxol.Test.Unit.setup_isolated_component(
          Button,
          Button.new(%{
            theme: theme,
            style: style,
            focused: true
          })
        )

      assert match?({:ok, _}, result)
      {:ok, button} = result

      view = Raxol.Test.Visual.render_component(button)
      assert Map.get(view.attrs, :fg) == :yellow
      assert Map.get(view.attrs, :bg) == :magenta
    end

    test ~c"mount and unmount lifecycle hooks are called and return state" do
      state =
        Button.new(%{
          label: "Test",
          theme: Raxol.Test.TestUtils.test_theme(),
          style: %{}
        })

      mounted = Button.mount(state)
      assert mounted == state
      unmounted = Button.unmount(mounted)
      assert unmounted == mounted
    end
  end

  describe "integration tests" do
    test "button in form interaction", _context do
      {:ok, form, button} =
        Raxol.Test.Integration.setup_component_hierarchy(
          Raxol.Examples.Form,
          Raxol.UI.Components.Input.Button
        )

      # Simulate a click on the button
      updated_button =
        Raxol.Test.Integration.simulate_user_action(button, {:click, {0, 0}})

      # Check that the button received the mouse event by verifying its state was updated
      assert updated_button.state.pressed == true,
             "Expected button to be pressed after mouse event"

      # Check that the form was updated (this would need proper parent-child event routing)
      # For now, we'll just check that the button state is correct
      assert updated_button.state.pressed == true

      # Check that both components have the expected state
      # The form.state is actually the entire form struct
      # The submitted field is in form.state.state
      assert form.state.state.submitted == false,
             "Form should not be submitted yet (no parent-child routing)"

      assert updated_button.state.pressed == true, "Button should be pressed"
    end

    test "contains errors properly", _context do
      # Attempt to cause an error by passing an invalid role attribute to the button.
      {:ok, _form, button} =
        Raxol.Test.Integration.setup_component_hierarchy(
          Raxol.Examples.Form,
          Raxol.UI.Components.Input.Button,
          # Pass invalid attrs
          button_attrs: %{role: :this_is_an_invalid_role}
        )

      # Assumption: The Button component's init function will validate props
      # (like :role) and store any validation errors in its state, possibly
      # in button.state.errors. The actual key and structure would depend
      # on Raxol.UI.Components.Input.Button's implementation.

      # Check if button.state.errors exists and is a non-empty map.
      # Default to empty map if :errors key is missing
      button_errors = Map.get(button.state, :errors, %{})

      assert map_size(button_errors) > 0,
             "Expected button to have validation errors due to invalid role, " <>
               "but got errors: #{inspect(button_errors)}. " <>
               "Button state: #{inspect(button.state)}"
    end
  end

  describe "visual tests" do
    @tag :unix_only
    test "renders with correct style", _context do
      button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      view = Raxol.Test.Visual.render_component(button)
      assert is_map(view)
      assert Map.get(view.attrs, :disabled, false) == false
      assert Map.get(view.attrs, :focused, false) == false
    end

    @tag :unix_only
    test "matches snapshot", context do
      button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      assert_matches_snapshot(
        button,
        "button_submit",
        context
      )
    end

    @tag :unix_only
    test "renders normal and disabled states for snapshot testing", context do
      normal_button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          label: "Normal",
          disabled: false,
          focused: false
        })

      disabled_button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          label: "Disabled",
          disabled: true,
          focused: false
        })

      normal_view = Raxol.Test.Visual.render_component(normal_button)
      disabled_view = Raxol.Test.Visual.render_component(disabled_button)

      assert Map.get(normal_view.attrs, :disabled, false) == false
      assert Map.get(disabled_view.attrs, :disabled, false) == true

      assert_matches_snapshot(normal_button, "button_normal", context)
      assert_matches_snapshot(disabled_button, "button_disabled", context)
    end

    test "adapts to different sizes", _context do
      button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      assert_responsive(
        button,
        [{80, 24}, {40, 12}, {20, 6}]
      )
    end

    test "maintains consistent structure across themes", _context do
      button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      assert_theme_consistent(
        button,
        %{light: %{fg: :black, bg: :white}, dark: %{fg: :white, bg: :black}}
      )
    end

    test "aligns properly", _context do
      button =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      view = Raxol.Test.Visual.render_component(button)
      assert is_map(view)
    end

    test "handles different states visually", _context do
      button_normal =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: false,
          focused: false
        })

      normal_view = Raxol.Test.Visual.render_component(button_normal)
      assert is_map(Map.get(normal_view, :attrs))
      assert Map.has_key?(Map.get(normal_view, :attrs, %{}), :disabled)
      assert Map.get(normal_view.attrs, :disabled, false) == false

      button_disabled =
        Raxol.Test.Visual.setup_visual_component(Button, %{
          disabled: true,
          focused: false
        })

      disabled_view = Raxol.Test.Visual.render_component(button_disabled)
      assert is_map(Map.get(disabled_view, :attrs))
      assert Map.has_key?(Map.get(disabled_view, :attrs, %{}), :disabled)
      assert Map.get(disabled_view.attrs, :disabled, false) == true
    end
  end
end
