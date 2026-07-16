defmodule Raxol.UI.Components.Harness.MessageBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.MessageBlock
  alias Raxol.UI.Components.MarkdownRenderer

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp flat_texts(%{type: :text, content: content}), do: [content]

  defp flat_texts(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_texts/1)

  defp flat_texts(_node), do: []

  defp flat_leaves(%{type: :text, content: content} = node),
    do: [{content, node[:style] || %{}}]

  defp flat_leaves(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &flat_leaves/1)

  defp flat_leaves(_node), do: []

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

  # The BodyProvider seam mounts this component for a block that may still
  # be LIVE (streaming). The body render is delegated to Harness.MarkdownBody
  # so a live message gets the provisional-close treatment and every message
  # gets its sanitization -- pure content -> view, no state.
  describe "streaming mode (BodyProvider seam)" do
    test "defaults to :sealed mode" do
      assert {:ok, state} = MessageBlock.init(id: :m_mode_default)
      assert state.mode == :sealed
    end

    test "accepts mode: :streaming" do
      assert {:ok, state} =
               MessageBlock.init(id: :m_mode_stream, mode: :streaming)

      assert state.mode == :streaming
    end

    test ":streaming provisionally closes a trailing unclosed construct -- no marker leak" do
      {:ok, state} =
        MessageBlock.init(
          id: :m_stream,
          content: "checking **disk",
          mode: :streaming,
          width: 80
        )

      rendered = MessageBlock.render(state, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "disk"))

      refute Enum.any?(texts, &(&1 =~ "*")),
             "a live message's unclosed bold marker leaked as literal text"

      assert Enum.any?(flat_leaves(rendered), fn {content, style} ->
               content =~ "disk" and style[:bold] == true
             end),
             "the provisionally-closed span must render styled bold"
    end

    test ":sealed (default) renders the same unclosed marker literally -- parity with the plain full parse" do
      {:ok, state} =
        MessageBlock.init(id: :m_sealed, content: "checking **disk", width: 80)

      rendered = MessageBlock.render(state, default_context())

      assert Enum.any?(flat_texts(rendered), &(&1 =~ "**")),
             "sealed content is final -- a genuinely-unclosed marker stays literal"
    end
  end

  describe "sanitization and total safety (via MarkdownBody)" do
    test "raw ANSI escape bytes in content never reach the element tree" do
      {:ok, state} =
        MessageBlock.init(
          id: :m_ansi,
          content: "ok \e[31mred\e[0m done",
          width: 80
        )

      rendered = MessageBlock.render(state, default_context())
      texts = flat_texts(rendered)

      assert Enum.any?(texts, &(&1 =~ "red"))

      refute Enum.any?(texts, &(&1 =~ "\e")),
             "an embedded ESC byte reached the element tree -- this violates " <>
               "the no-raw-ANSI-in-text() rule at the View-DSL boundary"
    end

    test "non-binary content never raises" do
      {:ok, state} =
        MessageBlock.init(id: :m_bad, content: %{oops: :shape}, width: 80)

      rendered = MessageBlock.render(state, default_context())
      assert rendered.type == :column
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
