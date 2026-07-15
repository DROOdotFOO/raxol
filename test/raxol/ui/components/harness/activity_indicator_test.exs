defmodule Raxol.UI.Components.Harness.ActivityIndicatorTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.ActivityIndicator
  alias Raxol.UI.Components.Progress.Spinner

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}
  defp indicator_el(rendered), do: Enum.at(rendered.children, 0)
  defp dots_frame(index), do: Spinner.frames(:dots) |> Enum.at(index)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ActivityIndicator.init(id: :ai1)
      assert state.state == :idle
      assert state.since_ms == 0
      assert state.frame == 0
      assert state.hung_threshold_ms == 10_000
    end
  end

  describe "render/2 working" do
    test "renders the spinner glyph for the current frame plus a label" do
      {:ok, state} = ActivityIndicator.init(id: :ai, state: :working, frame: 0)
      rendered = ActivityIndicator.render(state, default_context())

      assert indicator_el(rendered).content == "#{dots_frame(0)} working"
      assert indicator_el(rendered).fg == :cyan
    end

    test "advances the spinner glyph with the frame prop" do
      {:ok, state} = ActivityIndicator.init(id: :ai, state: :working, frame: 1)
      rendered = ActivityIndicator.render(state, default_context())

      assert indicator_el(rendered).content == "#{dots_frame(1)} working"
    end

    test "stays working just under the hung threshold" do
      {:ok, state} =
        ActivityIndicator.init(id: :ai, state: :working, since_ms: 9_999)

      rendered = ActivityIndicator.render(state, default_context())
      assert indicator_el(rendered).content == "#{dots_frame(0)} working"
    end
  end

  describe "render/2 idle" do
    test "renders a calm dot, regardless of elapsed time" do
      {:ok, state} =
        ActivityIndicator.init(id: :ai, state: :idle, since_ms: 999_999)

      rendered = ActivityIndicator.render(state, default_context())

      assert indicator_el(rendered).content == "• idle"
      assert indicator_el(rendered).style == %{dim: true}
    end
  end

  describe "render/2 hung" do
    test "renders HUNG? with elapsed seconds when state is explicitly :hung" do
      {:ok, state} =
        ActivityIndicator.init(id: :ai, state: :hung, since_ms: 5_000)

      rendered = ActivityIndicator.render(state, default_context())

      assert indicator_el(rendered).content == "HUNG? (5s)"
      assert indicator_el(rendered).fg == :red
      assert indicator_el(rendered).style == %{bold: true}
    end

    test "self-overrides to HUNG? when :working stalls past the threshold" do
      {:ok, state} =
        ActivityIndicator.init(id: :ai, state: :working, since_ms: 12_000)

      rendered = ActivityIndicator.render(state, default_context())

      assert indicator_el(rendered).content == "HUNG? (12s)"
      assert indicator_el(rendered).fg == :red
    end

    test "respects a custom hung_threshold_ms" do
      {:ok, state} =
        ActivityIndicator.init(
          id: :ai,
          state: :working,
          since_ms: 2_000,
          hung_threshold_ms: 1_000
        )

      rendered = ActivityIndicator.render(state, default_context())
      assert indicator_el(rendered).content == "HUNG? (2s)"
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = ActivityIndicator.init(id: :ai)
      {new_state, []} = ActivityIndicator.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
