defmodule Raxol.UI.Components.Harness.MessageBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.MessageBlock
  alias Raxol.UI.Components.MarkdownRenderer

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = MessageBlock.init(id: :m1)
      assert state.id == :m1
      assert state.role == :assistant
      assert state.content == ""
      assert state.width == Raxol.Core.Defaults.terminal_width()
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               MessageBlock.init(
                 id: :m2,
                 role: :user,
                 content: "**hi** there",
                 width: 60,
                 style: %{bg: :blue},
                 theme: %{fg: :white}
               )

      assert state.id == :m2
      assert state.role == :user
      assert state.content == "**hi** there"
      assert state.width == 60
      assert state.style == %{bg: :blue}
      assert state.theme == %{fg: :white}
    end
  end

  describe "render/2" do
    test "renders a column with a dim role prefix above the markdown body" do
      {:ok, state} =
        MessageBlock.init(id: :m_render, role: :assistant, content: "hello")

      rendered = MessageBlock.render(state, default_context())

      assert rendered.type == :column
      assert rendered.gap == 0
      assert length(rendered.children) == 2

      [role_el, body_el] = rendered.children
      assert role_el.content == "[assistant]"
      assert role_el.style == %{dim: true, fg: :cyan}
      assert body_el.type == :column
    end

    test "colors the user role prefix distinctly from assistant" do
      {:ok, user_state} = MessageBlock.init(id: :m_user, role: :user)
      {:ok, asst_state} = MessageBlock.init(id: :m_asst, role: :assistant)

      user_rendered = MessageBlock.render(user_state, default_context())
      asst_rendered = MessageBlock.render(asst_state, default_context())

      [user_role_el | _] = user_rendered.children
      [asst_role_el | _] = asst_rendered.children

      assert user_role_el.content == "[user]"
      assert user_role_el.style.fg == :green
      assert asst_role_el.style.fg == :cyan
      assert user_role_el.style.fg != asst_role_el.style.fg
    end

    test "reuses MarkdownRenderer verbatim for the message body" do
      content = "# Title\n\nSome *text* and a [link](https://example.com)."
      {:ok, state} = MessageBlock.init(id: :m_md, content: content, width: 40)

      rendered = MessageBlock.render(state, default_context())
      [_role_el, body_el] = rendered.children

      {:ok, md_state} =
        MarkdownRenderer.init(%{markdown_text: content, width: 40})

      expected_body = MarkdownRenderer.render(md_state, default_context())

      assert body_el == expected_body
    end
  end

  describe "handle_event/3" do
    test "is stateless -- passes through all events unchanged" do
      {:ok, state} = MessageBlock.init(id: :m_evt, content: "hi")

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, commands} = MessageBlock.handle_event(event, state, %{})

      assert new_state == state
      assert commands == []
    end
  end
end
