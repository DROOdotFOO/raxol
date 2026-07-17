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

  describe "render/2 (speaker separation: no tagline, bare prose)" do
    # The [assistant]/[user] tagline is DEAD (speaker-separation option A,
    # harness-speaker-separation.md §4): it was role-colored -- doctrine
    # §4.1 forbids color-as-speaker -- and spent a row. Authorship is
    # carried by the prompt-echo grammar at the Surface's margin/chevron
    # seam instead; this component renders the body alone for BOTH roles.
    test "the tagline never renders, for either role" do
      for role <- [:assistant, :user] do
        {:ok, state} =
          MessageBlock.init(id: :m_render, role: role, content: "hello")

        rendered = MessageBlock.render(state, default_context())

        refute Enum.any?(
                 flat_texts(rendered),
                 &(&1 =~ ~r/\[(assistant|user)\]/)
               ),
               "the #{role} tagline row must never render"
      end
    end

    test "renders the body as the ONLY child -- bare prose, no header row" do
      {:ok, state} =
        MessageBlock.init(id: :m_render, role: :assistant, content: "hello")

      rendered = MessageBlock.render(state, default_context())

      assert rendered.type == :column
      assert rendered.gap == 0
      assert [body_el] = rendered.children
      assert body_el.type == :column
    end

    test "both roles render an identical view for identical content -- the chevron echo is the Surface's job, not this component's" do
      {:ok, user_state} =
        MessageBlock.init(id: :m_same, role: :user, content: "same words")

      {:ok, asst_state} =
        MessageBlock.init(id: :m_same, role: :assistant, content: "same words")

      assert MessageBlock.render(user_state, default_context()) ==
               MessageBlock.render(asst_state, default_context()),
             "role must not change this component's own view -- speaker " <>
               "grammar lives at the Surface margin/chevron seam"
    end

    test "keeps the role in state as the speaker record" do
      {:ok, state} = MessageBlock.init(id: :m_role, role: :user)
      assert state.role == :user
    end

    test "reuses MarkdownRenderer verbatim for the message body" do
      content = "# Title\n\nSome *text* and a [link](https://example.com)."
      {:ok, state} = MessageBlock.init(id: :m_md, content: content, width: 40)

      rendered = MessageBlock.render(state, default_context())
      [body_el] = rendered.children

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

  # -- U1-a re-host: controlled fold vocabulary + TreeWalker stamping ------

  describe "controlled fold vocabulary (z / enter / space)" do
    # `z` is today's transcript fold key (Keymap binds char "z" ->
    # :fold_toggle, guard :not_composing); enter/space mirror
    # ReasoningBlock's activation keys. The component stays CONTROLLED:
    # it owns no fold state of its own -- it emits the wired `:on_toggle`
    # message out and leaves folding to the model that hosts it.
    defp char_event(char),
      do: %Event{type: :key, data: %{key: :char, char: char}}

    test "z emits the wired on_toggle message, state untouched" do
      {:ok, state} =
        MessageBlock.init(
          id: :m_z,
          content: "hi",
          on_toggle: {:toggle_fold, :m_z}
        )

      {new_state, commands} =
        MessageBlock.handle_event(char_event("z"), state, %{})

      assert new_state == state
      assert commands == [{:toggle_fold, :m_z}]
    end

    test "enter and space emit the wired on_toggle message" do
      {:ok, state} =
        MessageBlock.init(id: :m_act, content: "hi", on_toggle: :folded!)

      for key <- [:enter, :space] do
        event = %Event{type: :key, data: %{key: key}}
        {new_state, commands} = MessageBlock.handle_event(event, state, %{})

        assert new_state == state
        assert commands == [:folded!], "#{key} must emit the on_toggle message"
      end
    end

    test "fold keys emit nothing when on_toggle is not wired" do
      {:ok, state} = MessageBlock.init(id: :m_unwired, content: "hi")

      for event <- [char_event("z"), %Event{type: :key, data: %{key: :space}}] do
        assert {^state, []} = MessageBlock.handle_event(event, state, %{})
      end
    end

    test "modified z (ctrl/alt) passes through without emitting" do
      {:ok, state} =
        MessageBlock.init(id: :m_mod, content: "hi", on_toggle: :nope)

      for modifier <- [:ctrl, :alt] do
        event = %Event{
          type: :key,
          data: Map.put(%{key: :char, char: "z"}, modifier, true)
        }

        assert {^state, []} = MessageBlock.handle_event(event, state, %{})
      end
    end
  end

  describe "TreeWalker stamping (F0-mcp requirements)" do
    test "root node carries id, role-invariant attrs, and the wired on_click" do
      {:ok, state} =
        MessageBlock.init(
          id: "msg-1",
          role: :user,
          content: "hello",
          on_toggle: {:toggle_fold, "msg-1"}
        )

      rendered = MessageBlock.render(state, default_context())

      assert rendered.id == "msg-1"
      assert rendered.on_click == {:toggle_fold, "msg-1"}
      assert rendered.attrs.kind == :message
      assert rendered.attrs.mode == :sealed

      refute Map.has_key?(rendered.attrs, :role),
             "attrs must stay role-invariant -- speaker grammar is the host's"
    end

    test "attrs carry the component_module marker for tool derivation" do
      {:ok, state} = MessageBlock.init(id: "msg-2", content: "hi")
      rendered = MessageBlock.render(state, default_context())

      assert rendered.attrs.component_module == MessageBlock
      assert rendered.on_click == nil
    end
  end

  describe "ToolProvider derivation" do
    test "mcp_tools/1 derives a toggle action only when on_toggle is wired" do
      {:ok, wired} =
        MessageBlock.init(id: "msg-3", content: "hi", on_toggle: :flip)

      {:ok, unwired} = MessageBlock.init(id: "msg-4", content: "hi")

      wired_node = MessageBlock.render(wired, default_context())
      unwired_node = MessageBlock.render(unwired, default_context())

      assert [%{name: "toggle"}] = MessageBlock.mcp_tools(wired_node)

      assert MessageBlock.mcp_tools(unwired_node) == [],
             "an unwired block must not advertise a toggle it cannot honor"
    end

    test "handle_tool_call/3 toggle dispatches a widget-targeted click" do
      context = %{widget_id: "msg-5", widget_state: %{}, dispatcher_pid: nil}

      assert {:ok, _result, [event]} =
               MessageBlock.handle_tool_call("toggle", %{}, context)

      assert %Event{type: :click, data: %{widget_id: "msg-5"}} = event
    end

    test "unknown actions error" do
      context = %{widget_id: "msg-6", widget_state: %{}, dispatcher_pid: nil}

      assert {:error, _reason} =
               MessageBlock.handle_tool_call("explode", %{}, context)
    end
  end
end
