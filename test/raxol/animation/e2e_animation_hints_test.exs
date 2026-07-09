defmodule Raxol.Animation.E2EAnimationHintsTest do
  @moduledoc """
  End-to-end tests for the animation hints pipeline.

  Tests the full flow:
  1. animate/2 attaches hints to view elements
  2. Preparer propagates hints through PreparedElement
  3. Framework applies animation state to model
  4. TerminalBridge generates CSS transitions from hints
  """
  use ExUnit.Case, async: false


  alias Raxol.Animation.{Framework, Helpers, Hint}
  alias Raxol.Core.UserPreferences
  alias Raxol.UI.Layout.{Preparer, PreparedElement}
  alias Raxol.LiveView.TerminalBridge

  setup do
    # Start EventManager
    case Raxol.Core.Events.EventManager.start_link(
           name: Raxol.Core.Events.EventManager
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    # Reset AccessibilityServer
    case Process.whereis(Raxol.Core.Accessibility.AccessibilityServer) do
      nil -> :ok
      pid ->
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
    end

    local_user_prefs_name = __MODULE__.UserPreferences
    {:ok, _} = start_supervised({UserPreferences, [name: local_user_prefs_name, test_mode?: true]})

    accessibility_name = :"accessibility_server_#{System.unique_integer([:positive])}"
    {:ok, _} = Raxol.Core.Accessibility.AccessibilityServer.start_link(name: accessibility_name)

    Framework.init(%{}, local_user_prefs_name)

    UserPreferences.set("accessibility.reduced_motion", false, local_user_prefs_name)
    assert_receive {:preferences_applied, ^local_user_prefs_name}, 500

    on_exit(fn ->
      try do
        Framework.stop()
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, %{user_prefs: local_user_prefs_name}}
  end

  describe "E2E: animate -> prepare -> render pipeline" do
    test "hints survive from view DSL through PreparedElement tree" do
      # Step 1: Build a view tree with animation hints (as a view/1 function would)
      view_tree =
        %{type: :box, id: "container", children: [
          %{type: :text, content: "Hello", id: "greeting"}
          |> Helpers.animate(property: :opacity, from: 0.0, to: 1.0, duration: 500, easing: :ease_out_cubic),

          %{type: :text, content: "World", id: "subtitle"}
          |> Helpers.animate(property: :color, to: :cyan, duration: 300)
          |> Helpers.animate(property: :opacity, to: 1.0, duration: 200, delay: 100)
        ]}

      # Step 2: Prepare the tree (text measurement phase)
      prepared = Preparer.prepare(view_tree)

      # Step 3: Verify hints propagated through the prepared tree
      assert %PreparedElement{type: :box} = prepared
      assert prepared.animation_hints == []

      [greeting, subtitle] = prepared.children

      # greeting has 1 opacity hint
      assert length(greeting.animation_hints) == 1
      [opacity_hint] = greeting.animation_hints
      assert %Hint{property: :opacity, to: 1.0, duration_ms: 500} = opacity_hint
      assert opacity_hint.from == 0.0

      # subtitle has 2 hints (opacity + color)
      assert length(subtitle.animation_hints) == 2
    end

    test "incremental prepare preserves hints on unchanged content" do
      element =
        %{type: :text, content: "stable", id: "el"}
        |> Helpers.animate(property: :opacity, to: 1.0)

      old_prepared = Preparer.prepare(element)
      new_prepared = Preparer.prepare_incremental(element, old_prepared)

      assert length(new_prepared.animation_hints) == 1
      assert hd(new_prepared.animation_hints).property == :opacity
    end
  end

  describe "E2E: animation framework -> model state mutation" do
    test "apply_animations_to_state injects interpolated values", %{user_prefs: user_prefs} do
      # Step 1: Create and start an animation
      Framework.create_animation(:fade_in, %{
        type: :fade,
        from: 0.0,
        to: 1.0,
        duration: 100,
        easing: :linear,
        target_path: [:opacity]
      })

      Framework.start_animation(:fade_in, "panel", %{}, user_prefs)
      assert_receive {:animation_started, "panel", :fade_in}, 500

      # Step 2: Wait a bit for animation progress
      Process.sleep(60)

      # Step 3: Apply animations to model (what Engine does before view/1)
      model = %{elements: %{"panel" => %{opacity: 0.0}}}
      animated_model = Framework.apply_animations_to_state(model, user_prefs)

      # Step 4: The opacity should have moved from 0.0 toward 1.0
      panel = get_in(animated_model, [:elements, "panel"])
      assert panel.opacity > 0.0
      assert panel.opacity <= 1.0
    end

    test "completed animation sets final value", %{user_prefs: user_prefs} do
      Framework.create_animation(:quick_fade, %{
        type: :fade,
        from: 0.0,
        to: 1.0,
        duration: 50,
        easing: :linear,
        target_path: [:opacity]
      })

      Framework.start_animation(:quick_fade, "box", %{}, user_prefs)
      assert_receive {:animation_started, "box", :quick_fade}, 500

      # Wait for completion
      Process.sleep(100)

      model = %{elements: %{"box" => %{opacity: 0.0}}}
      animated_model = Framework.apply_animations_to_state(model, user_prefs)

      box = get_in(animated_model, [:elements, "box"])
      assert_in_delta box.opacity, 1.0, 0.01
    end
  end

  describe "E2E: hints -> CSS generation" do
    test "full pipeline: animate helper -> element tree -> CSS output" do
      # Step 1: Build view with hints
      elements = [
        %{type: :box, id: "header", children: [
          %{type: :text, content: "Title", id: "title"}
          |> Helpers.animate(property: :opacity, from: 0.0, to: 1.0, duration: 400, easing: :ease_out_cubic)
        ]}
        |> Helpers.animate(property: :bg, to: :blue, duration: 300, easing: :ease_in_out_cubic, delay: 50),

        %{type: :text, content: "Body", id: "body"}
        |> Helpers.animate(property: :color, to: :cyan, duration: 200)
      ]

      # Step 2: Generate CSS from element tree
      css = TerminalBridge.animation_css(elements)

      # Step 3: Verify CSS output
      assert css =~ "<style>"
      assert css =~ "</style>"

      # header has bg transition with delay
      assert css =~ ~s([data-raxol-id="header"])
      assert css =~ "background-color 300ms"
      assert css =~ "50ms"

      # title (nested child) has opacity transition
      assert css =~ ~s([data-raxol-id="title"])
      assert css =~ "opacity 400ms"
      assert css =~ "cubic-bezier(0.215, 0.61, 0.355, 1)"

      # body has color transition
      assert css =~ ~s([data-raxol-id="body"])
      assert css =~ "color 200ms"

      # Always includes reduced motion query
      assert css =~ "@media (prefers-reduced-motion: reduce)"
    end

    test "elements without id are skipped in CSS" do
      elements = [
        %{type: :box, children: []}
        |> Helpers.animate(property: :opacity, to: 1.0)
      ]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "elements without hints produce no CSS" do
      elements = [
        %{type: :box, id: "plain", children: []}
      ]

      assert TerminalBridge.animation_css(elements) == ""
    end

    test "Hint struct CSS mapping matches TerminalBridge CSS mapping" do
      # Verify that both Hint module and TerminalBridge produce consistent CSS
      # for the same easing/property values
      hint = %Hint{
        property: :opacity,
        from: 0.0,
        to: 1.0,
        duration_ms: 300,
        easing: :ease_out_cubic,
        delay_ms: 0
      }

      # Hint module mapping
      hint_css_prop = Hint.to_css_property(:opacity)
      hint_css_timing = Hint.to_css_timing(:ease_out_cubic)

      # Generate via TerminalBridge
      elements = [%{id: "el", type: :box, animation_hints: [hint]}]
      css = TerminalBridge.animation_css(elements)

      # Both should agree
      assert css =~ hint_css_prop
      assert css =~ hint_css_timing
    end
  end

  describe "E2E: animate -> prepare -> CSS (full chain)" do
    test "complete roundtrip from DSL to CSS output" do
      # Step 1: Build view with animate helper
      view =
        %{type: :box, id: "card", children: [
          %{type: :text, content: "Loading...", id: "spinner"}
          |> Helpers.animate(property: :opacity, from: 0.0, to: 1.0, duration: 600, easing: :ease_in_out_sine)
        ]}
        |> Helpers.animate(property: :bg, to: :black, duration: 400, easing: :ease_out_expo, delay: 200)

      # Step 2: Prepare (simulates render pipeline)
      prepared = Preparer.prepare(view)

      # Step 3: Extract original elements from prepared tree for CSS generation
      # (In production, positioned elements from LayoutEngine would be used)
      original_elements = extract_elements_with_hints(prepared)

      # Step 4: Generate CSS
      css = TerminalBridge.animation_css(original_elements)

      # Step 5: Verify full chain
      assert css =~ "<style>"

      # card: background-color with delay
      assert css =~ ~s([data-raxol-id="card"])
      assert css =~ "background-color 400ms"
      assert css =~ "200ms"

      # spinner: opacity
      assert css =~ ~s([data-raxol-id="spinner"])
      assert css =~ "opacity 600ms"
      assert css =~ "cubic-bezier(0.445, 0.05, 0.55, 0.95)"

      assert css =~ "@media (prefers-reduced-motion: reduce)"
    end
  end

  # Helper to reconstruct element maps from PreparedElement tree
  defp extract_elements_with_hints(%PreparedElement{} = pe) do
    element =
      pe.element
      |> Map.put(:animation_hints, pe.animation_hints)

    children =
      case pe.children do
        nil -> []
        children -> Enum.flat_map(children, &extract_elements_with_hints/1)
      end

    element = Map.put(element, :children, children)
    [element]
  end
end
