defmodule Raxol.UI.Components.Display.ProgressTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Display.Progress

  defp default_context,
    do: %{
      theme: %{progress: %{fg: :red, bg: :black, border: :white, text: :yellow}}
    }

  defp init_component(props \\ %{}) do
    {:ok, state} = Progress.init(props)
    state = Map.put_new(state, :style, %{})
    Map.put_new(state, :type, :progress)
  end

  describe "init/1" do
    test "initializes with default props" do
      state = init_component()
      assert state.progress == 0.0
      assert state.width == 20
      assert state.label == nil
      assert state.show_percentage == false
      assert state.animated == false
      assert state.style == %{}
      assert state.theme == %{}
      assert state.aria_label == nil
      assert state.tooltip == nil
    end

    test "initializes with custom props" do
      props = %{
        progress: 0.5,
        width: 30,
        label: "Loading",
        show_percentage: true,
        animated: true,
        style: %{fg: :green},
        theme: %{progress: %{fg: :blue}},
        aria_label: "progress-bar",
        tooltip: "progress info"
      }

      state = init_component(props)
      assert state.progress == 0.5
      assert state.width == 30
      assert state.label == "Loading"
      assert state.show_percentage == true
      assert state.animated == true
      assert state.style == %{fg: :green}
      assert state.theme == %{progress: %{fg: :blue}}
      assert state.aria_label == "progress-bar"
      assert state.tooltip == "progress info"
    end

    test "init/1 clamps progress value to valid range" do
      {:ok, below_state} = Progress.init(%{progress: -0.5})
      assert below_state.progress == 0.0

      {:ok, above_state} = Progress.init(%{progress: 1.5})
      assert above_state.progress == 1.0

      {:ok, within_state} = Progress.init(%{progress: 0.5})
      assert within_state.progress == 0.5
    end

    test "init/1 applies default values" do
      {:ok, state} = Progress.init(%{})
      assert state.progress == 0.0
      assert state.width == 20
      assert state.label == nil
      assert state.show_percentage == false
      assert state.animated == false
    end
  end

  describe "lifecycle: mount/1 and unmount/1" do
    test "mount returns state and []" do
      state = init_component(%{progress: 0.1})
      {mounted, cmds} = Progress.mount(state)
      assert mounted == state
      assert cmds == []
    end

    test "unmount returns state (no side effects)" do
      state = init_component(%{progress: 0.1})
      assert Progress.unmount(state) == state
    end
  end

  describe "style/theme merging and override precedence" do
    defp themed_context(theme), do: %{theme: theme}

    test "instance style overrides theme style" do
      theme = %{
        progress: %{fg: :red, bg: :black, border: :white, text: :yellow}
      }

      style = %{fg: :green, bold: true}
      state = init_component(%{style: style})
      context = themed_context(theme)
      [_, bar_fill | _] = Progress.render(state, context)
      assert bar_fill.style.fg == :green
      assert bar_fill.style.bg == :black
    end

    test "theme prop overrides context theme, instance style overrides both" do
      context_theme = %{progress: %{fg: :red, bg: :black}}
      theme_prop = %{progress: %{fg: :blue, bg: :yellow}}
      style = %{fg: :green}
      state = init_component(%{theme: theme_prop, style: style})
      context = themed_context(context_theme)
      [_, bar_fill | _] = Progress.render(state, context)
      assert bar_fill.style.fg == :green
      assert bar_fill.style.bg == :yellow
    end
  end

  describe "accessibility and extra props" do
    test "renders aria_label and tooltip as attributes on box" do
      state = init_component(%{aria_label: "foo", tooltip: "tip"})
      [box | _] = Progress.render(state, default_context())
      assert box.aria_label == "foo"
      assert box.tooltip == "tip"
    end

    test "does not include nil extra attributes" do
      state = init_component()
      [box | _] = Progress.render(state, default_context())
      refute Map.has_key?(box, :aria_label)
      refute Map.has_key?(box, :tooltip)
    end
  end

  describe "render/2" do
    setup do
      {:ok, context: default_context()}
    end

    test "renders basic progress bar", %{context: context} do
      state = init_component(%{progress: 0.5, width: 10})
      elements = Progress.render(state, context)
      assert is_list(elements)
    end

    test "renders percentage text when enabled", %{context: context} do
      state =
        init_component(%{show_percentage: true, progress: 0.75, width: 20})

      elements = Progress.render(state, context)

      assert Enum.any?(elements, fn el ->
               el.type == :text and String.contains?(el.content || "", "%")
             end)
    end

    test "renders label when provided", %{context: context} do
      state =
        init_component(%{progress: 0.3, width: 20, label: "Downloading..."})

      elements = Progress.render(state, context)

      assert Enum.any?(elements, fn el ->
               is_map(el) and el.type == :text and
                 String.contains?(el.content || "", "Downloading...")
             end)
    end

    test "generates correct bar content for different progress values", %{
      context: context
    } do
      empty_state = init_component(%{progress: 0.0, width: 10})
      half_state = init_component(%{progress: 0.5, width: 10})
      full_state = init_component(%{progress: 1.0, width: 10})
      assert is_list(Progress.render(empty_state, context))
      assert is_list(Progress.render(half_state, context))
      assert is_list(Progress.render(full_state, context))
    end

    test "renders animation character when animated", %{context: context} do
      state = init_component(%{progress: 0.5, width: 10, animated: true})
      state = %{state | animation_frame: 3}
      elements = Progress.render(state, context)
      assert is_list(elements)
    end

    test "render/2 handles invalid progress values gracefully" do
      state = init_component()
      context = default_context()
      below_state = %{state | progress: -0.5}
      elements_below = Progress.render(below_state, context)
      assert is_list(elements_below)
      above_state = %{state | progress: 1.5}
      elements_above = Progress.render(above_state, context)
      assert is_list(elements_above)
    end
  end

  describe "update/2" do
    test "merges style and theme on update" do
      state =
        init_component(%{style: %{fg: :red}, theme: %{progress: %{bg: :blue}}})

      {updated_state, _cmds} =
        Progress.update(
          {:update_props,
           %{style: %{bold: true}, theme: %{progress: %{fg: :green}}}},
          state
        )

      assert updated_state.style == %{fg: :red, bold: true}
      assert updated_state.theme == %{progress: %{bg: :blue, fg: :green}}
    end
  end
end
