defmodule Raxol.UI.Components.Harness.ToastTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Toast

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}
  defp message_el(rendered), do: Enum.at(rendered.children, 0)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = Toast.init(id: :t1)
      assert state.message == ""
      assert state.level == :info
      assert state.ttl_ms == 4_000
    end
  end

  describe "render/2" do
    test "renders a rounded, padded box" do
      {:ok, state} = Toast.init(id: :t, message: "Checkpoint saved")
      rendered = Toast.render(state, default_context())

      assert rendered.type == :box
      assert rendered.style.border == :rounded
      assert rendered.style.padding == 1
    end

    test "pairs the info level with an info glyph and cyan" do
      {:ok, state} =
        Toast.init(id: :t, message: "Checkpoint saved", level: :info)

      rendered = Toast.render(state, default_context())

      assert message_el(rendered).content == "ℹ Checkpoint saved"
      assert message_el(rendered).fg == :cyan
    end

    test "pairs the warn level with a warning glyph and yellow" do
      {:ok, state} =
        Toast.init(id: :t, message: "Approaching cap", level: :warn)

      rendered = Toast.render(state, default_context())

      assert message_el(rendered).content == "⚠ Approaching cap"
      assert message_el(rendered).fg == :yellow
    end

    test "pairs the error level with an error glyph and red" do
      {:ok, state} = Toast.init(id: :t, message: "Turn failed", level: :error)
      rendered = Toast.render(state, default_context())

      assert message_el(rendered).content == "✗ Turn failed"
      assert message_el(rendered).fg == :red
    end

    test "falls back to a neutral glyph for an unknown level" do
      {:ok, state} = Toast.init(id: :t, message: "???", level: :mystery)
      rendered = Toast.render(state, default_context())

      assert message_el(rendered).content == "• ???"
      assert message_el(rendered).fg == :white
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = Toast.init(id: :t)
      {new_state, []} = Toast.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
