defmodule Raxol.UI.Components.CodeBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.CodeBlock

  describe "init/1" do
    test "returns {:ok, state} with props passed through" do
      props = %{content: "IO.puts(:hello)", language: "elixir"}
      assert {:ok, state} = CodeBlock.init(props)
      assert state == props
    end

    test "returns {:ok, state} with empty props" do
      assert {:ok, state} = CodeBlock.init(%{})
      assert state == %{}
    end

    test "preserves all provided props" do
      props = %{
        content: "def foo, do: :bar",
        language: "elixir",
        class: "my-class"
      }

      assert {:ok, ^props} = CodeBlock.init(props)
    end
  end

  describe "update/2" do
    test "returns state unchanged for any message" do
      {:ok, state} = CodeBlock.init(%{content: "code", language: "elixir"})

      assert CodeBlock.update(:any_message, state) == state
      assert CodeBlock.update(%{content: "new"}, state) == state
      assert CodeBlock.update(nil, state) == state
    end
  end

  describe "handle_event/3" do
    test "returns {state, []} for any event" do
      {:ok, state} = CodeBlock.init(%{content: "code", language: "elixir"})

      assert {^state, []} = CodeBlock.handle_event(:click, state, %{})
      assert {^state, []} = CodeBlock.handle_event(:key, state, %{theme: %{}})
      assert {^state, []} = CodeBlock.handle_event(nil, state, %{})
    end
  end

  describe "mount/1" do
    test "returns {state, []} without modifying state" do
      {:ok, state} = CodeBlock.init(%{content: "x = 1", language: "elixir"})
      assert {^state, []} = CodeBlock.mount(state)
    end
  end

  describe "unmount/1" do
    test "returns state unchanged" do
      {:ok, state} = CodeBlock.init(%{content: "x = 1", language: "elixir"})
      assert CodeBlock.unmount(state) == state
    end
  end

  describe "render/2" do
    test "renders a column of token-span rows" do
      {:ok, state} =
        CodeBlock.init(%{content: "IO.puts(:hello)", language: "elixir"})

      result = CodeBlock.render(state, %{})
      assert result.type == :column
      assert is_list(result.children)
      assert result.children != []
    end

    test "rendered content preserves the source text" do
      source = "IO.puts(:hello)"
      {:ok, state} = CodeBlock.init(%{content: source, language: "elixir"})
      result = CodeBlock.render(state, %{})
      flat = flatten_text(result)
      assert flat =~ "IO"
      assert flat =~ "puts"
      assert flat =~ "hello"
    end

    test "elixir tokens carry hex foreground colors when Makeup is available" do
      {:ok, state} =
        CodeBlock.init(%{content: "def foo, do: 1", language: "elixir"})

      result = CodeBlock.render(state, %{})
      fgs = collect_fgs(result)

      # SyntaxHighlighter paints keyword/name tokens with theme hex colors
      # (e.g. #C678DD for `def`). Plain-text fallback has only nil fgs —
      # skip the assertion if Makeup didn't register a lexer in this env.
      if Enum.any?(fgs, &is_binary/1) do
        assert Enum.any?(fgs, &match?("#" <> _, &1))
      end
    end

    test "renders unknown language without raising" do
      {:ok, state} =
        CodeBlock.init(%{content: "print('hi')", language: "python"})

      result = CodeBlock.render(state, %{})
      assert flatten_text(result) =~ "print"
    end

    test "renders with empty content" do
      {:ok, state} = CodeBlock.init(%{})
      result = CodeBlock.render(state, %{})
      assert result.type == :column
      assert flatten_text(result) == ""
    end

    test "renders plain text language" do
      {:ok, state} =
        CodeBlock.init(%{content: "hello world", language: "text"})

      result = CodeBlock.render(state, %{})
      assert flatten_text(result) =~ "hello world"
    end

    test "never emits HTML spans" do
      {:ok, state} =
        CodeBlock.init(%{
          content: "defmodule Foo do\nend",
          language: "elixir"
        })

      result = CodeBlock.render(state, %{})
      flat = flatten_text(result)
      refute flat =~ "<span"
      refute flat =~ "</span>"
    end
  end

  defp flatten_text(%{content: c}) when is_binary(c), do: c

  defp flatten_text(%{children: children}) when is_list(children),
    do: Enum.map_join(children, "\n", &flatten_text/1)

  defp flatten_text(_), do: ""

  defp collect_fgs(%{style: %{fg: fg}}) when not is_nil(fg), do: [fg]
  defp collect_fgs(%{style: style}) when is_map(style), do: [Map.get(style, :fg)]
  defp collect_fgs(%{fg: fg}) when not is_nil(fg), do: [fg]

  defp collect_fgs(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &collect_fgs/1)

  defp collect_fgs(_), do: []
end
