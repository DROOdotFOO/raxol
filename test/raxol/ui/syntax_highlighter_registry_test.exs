defmodule Raxol.UI.SyntaxHighlighterRegistryTest do
  # async: FALSE on purpose -- this suite mutates the process-global Makeup
  # registry (`Application.env`), so it must not run concurrently with the
  # async highlighter/diff tests that read it. ExUnit runs sync suites apart
  # from async ones, and setup restores the captured registry either way.
  use ExUnit.Case, async: false

  alias Raxol.UI.SyntaxHighlighter

  @name_key :lexer_name_registry
  @ext_key :lexer_extension_registry

  setup do
    saved_name = Application.get_env(:makeup, @name_key)
    saved_ext = Application.get_env(:makeup, @ext_key)

    on_exit(fn ->
      restore(@name_key, saved_name)
      restore(@ext_key, saved_ext)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:makeup, key)
  defp restore(key, value), do: Application.put_env(:makeup, key, value)

  describe "highlight_lines/3 with an UNINITIALIZED Makeup registry" do
    # The live regression: Makeup the MODULE is loadable
    # (`Code.ensure_loaded?/1` true), but its lexer registry is populated only
    # when the Makeup application starts and each lexer self-registers. A
    # headless / :agent environment skips that boot, so
    # `Application.get_env(:makeup, :lexer_name_registry)` is nil and Makeup's
    # own `Map.fetch(nil, name)` raises BadMapError inside
    # `SyntaxHighlighter.fetch_lexer/1`. That crash propagated all the way up
    # through DiffViewer into a harness approval block's render, blanking the
    # whole diff as "(render error: expected a map, got: nil)". Highlighting
    # is a nicety; its absence must degrade to PLAIN source, never crash.
    test "degrades to plain source instead of raising" do
      Application.delete_env(:makeup, @name_key)
      Application.delete_env(:makeup, @ext_key)

      lines =
        SyntaxHighlighter.highlight_lines(
          ~s(      {:jason, "~> 1.4"},),
          "elixir"
        )

      tokens = List.flatten(lines)

      # Plain fallback: every token carries no fg colour (no lexer ran) ...
      assert Enum.all?(tokens, &(&1.fg == nil)),
             "an uninitialized registry must yield PLAIN tokens, got: " <>
               inspect(tokens)

      # ... and the text is preserved byte-for-byte (nothing dropped).
      assert Enum.map_join(tokens, & &1.text) == ~s(      {:jason, "~> 1.4"},)
    end

    test "an unknown language also degrades to plain (the :error path)" do
      # Registry present but the language has no lexer -- the same plain
      # contract via fetch_lexer/1's :error branch, no rescue involved.
      lines = SyntaxHighlighter.highlight_lines("some content", "no-such-lang")
      tokens = List.flatten(lines)
      assert Enum.all?(tokens, &(&1.fg == nil))
      assert Enum.map_join(tokens, & &1.text) == "some content"
    end
  end
end
