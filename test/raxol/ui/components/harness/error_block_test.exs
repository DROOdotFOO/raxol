defmodule Raxol.UI.Components.Harness.ErrorBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ErrorBlock

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ErrorBlock.init(id: :e1)
      assert state.id == :e1
      assert state.where == ""
      assert state.reason == ""
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               ErrorBlock.init(
                 id: :e2,
                 where: "tool_call:read_file",
                 reason: :timeout
               )

      assert state.where == "tool_call:read_file"
      assert state.reason == :timeout
    end
  end

  describe "render/2" do
    test "renders a red-bordered box with title, where, and reason" do
      {:ok, state} =
        ErrorBlock.init(
          id: :e_render,
          where: "tool_call:read_file",
          reason: "permission denied"
        )

      rendered = ErrorBlock.render(state, default_context())

      assert rendered.type == :box
      assert rendered.style.border == :single
      assert rendered.style.fg == :red

      assert [inner] = rendered.children
      assert inner.type == :column

      [title, where, reason] = inner.children
      assert title.content == "Error"
      assert title.style == %{bold: true, fg: :red}

      assert where.content == "where: tool_call:read_file"
      assert where.style == %{dim: true}

      assert reason.content == "reason: permission denied"
      assert reason.style == %{fg: :red}
    end

    test "formats non-binary where/reason terms via inspect" do
      {:ok, state} =
        ErrorBlock.init(id: :e_term, where: :boot, reason: {:timeout, 5000})

      rendered = ErrorBlock.render(state, default_context())
      [inner] = rendered.children
      [_title, where, reason] = inner.children

      assert where.content == "where: :boot"
      assert reason.content == "reason: {:timeout, 5000}"
    end

    test "inline style overrides the default border color" do
      {:ok, state} = ErrorBlock.init(id: :e_style, style: %{fg: :magenta})
      rendered = ErrorBlock.render(state, default_context())
      assert rendered.style.fg == :magenta
      assert rendered.style.border == :single
    end
  end

  describe "handle_event/3" do
    test "is stateless -- passes through all events unchanged" do
      {:ok, state} = ErrorBlock.init(id: :e_evt, reason: "boom")

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, commands} = ErrorBlock.handle_event(event, state, %{})

      assert new_state == state
      assert commands == []
    end
  end
end
