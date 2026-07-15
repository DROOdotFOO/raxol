defmodule Raxol.UI.SyntaxHighlighterTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.SyntaxHighlighter

  describe "highlight_lines/3" do
    test "elixir tokens get real fg hex colors" do
      [line] = SyntaxHighlighter.highlight_lines("def foo, do: :ok", "elixir")

      assert Enum.any?(line, fn tok ->
               is_binary(tok.fg) and tok.fg =~ ~r/^#[0-9A-Fa-f]{6}$/
             end)

      # The tokens concatenate back to the original source.
      assert Enum.map_join(line, & &1.text) == "def foo, do: :ok"
    end

    # Makeup token values are chardata (mixed binaries + bare codepoints);
    # a codepoint above 255 made the old IO.iodata_to_binary conversion
    # raise, silently degrading the WHOLE file to plain text. "€" (U+20AC)
    # is the exact character that surfaced it.
    test "a multi-byte codepoint does not knock out highlighting (euro regression)" do
      src = ~s{def currency_symbol(:eur), do: "€"\n}
      [line, _trailing] = SyntaxHighlighter.highlight_lines(src, "elixir")

      assert Enum.any?(line, fn tok -> is_binary(tok.fg) end),
             "expected highlighted tokens, got plain fallback: #{inspect(line)}"

      assert Enum.map_join(line, & &1.text) == String.trim_trailing(src, "\n")
    end

    test "complex unicode and emoji survive with highlighting intact" do
      cases = [
        {"cjk", ~s(x = "汉字テスト한글")},
        {"combining diacritics", ~s(x = "éà")},
        {"astral plane", ~s(x = "𝕊𝕥𝕣𝕚𝕟𝕘")},
        {"emoji", ~s(x = "🚀 fire 🔥")},
        {"zwj emoji sequence", ~s(x = "👩‍🚀👨‍👩‍👧‍👦")},
        {"flags + skin tone", ~s(x = "🏳️‍🌈 👍🏽")},
        {"mixed rtl", ~s(x = "abc عربى abc")}
      ]

      for {label, src} <- cases do
        [line] = SyntaxHighlighter.highlight_lines(src, "elixir")

        # never degrades to the single plain-token fallback
        assert Enum.any?(line, fn tok -> is_binary(tok.fg) end),
               "#{label}: lost highlighting: #{inspect(line)}"

        # tokens reconstruct the source byte-for-byte
        assert Enum.map_join(line, & &1.text) == src,
               "#{label}: token texts do not reconstruct the source"
      end
    end

    test "unicode inside comments and atoms keeps line structure" do
      src = "# comment with € and 🚀\n:atom_ok\n"
      lines = SyntaxHighlighter.highlight_lines(src, "elixir")

      assert length(lines) == 3
      assert Enum.map_join(hd(lines), & &1.text) == "# comment with € and 🚀"
    end

    test "an unresolvable language falls back to one plain token per line" do
      assert SyntaxHighlighter.highlight_lines(
               "hello world",
               "not-a-real-language"
             ) ==
               [[%{text: "hello world", fg: nil, styles: []}]]
    end

    test "nil language returns plain tokens per line, preserving line count" do
      assert SyntaxHighlighter.highlight_lines("a\nb\nc", nil) == [
               [%{text: "a", fg: nil, styles: []}],
               [%{text: "b", fg: nil, styles: []}],
               [%{text: "c", fg: nil, styles: []}]
             ]
    end

    test "empty source returns no lines" do
      assert SyntaxHighlighter.highlight_lines("", "elixir") == []
      assert SyntaxHighlighter.highlight_lines("", nil) == []
    end

    test "line count matches String.split(source, \"\\n\") even across a multi-line heredoc" do
      source = ~s(x = """\nhello\nworld\n"""\ny = 1)
      lines = SyntaxHighlighter.highlight_lines(source, "elixir")

      assert length(lines) == length(String.split(source, "\n"))

      # Every line's tokens still reconstruct that line's original text.
      original_lines = String.split(source, "\n")

      for {tokens, original} <- Enum.zip(lines, original_lines) do
        assert Enum.map_join(tokens, & &1.text) == original
      end
    end

    test "an unresolvable language keeps the line count correct too" do
      source = "a\nb\nc\nd"

      lines =
        SyntaxHighlighter.highlight_lines(source, "definitely-not-a-language")

      assert length(lines) == 4
    end

    test "theme atom resolves via Makeup.Styles.HTML.StyleMap" do
      [line] =
        SyntaxHighlighter.highlight_lines(
          "def foo, do: :ok",
          "elixir",
          :dracula
        )

      assert Enum.any?(line, fn tok -> is_binary(tok.fg) end)
    end

    test "an unknown theme atom falls back to the default rather than raising" do
      assert [_line] =
               SyntaxHighlighter.highlight_lines(
                 "x = 1",
                 "elixir",
                 :not_a_real_theme
               )
    end

    test "a lexer crash degrades to plain lines instead of raising" do
      defmodule CrashingLexer do
        @behaviour Makeup.Lexer
        def lex(_source, _opts), do: raise("boom")
        def match_groups(_tokens, _group_prefix), do: []
        def postprocess(tokens, _opts), do: tokens
        def root(_source), do: {:error, "unused", "", %{}, {1, 0}, 0}
        def root_element(_source), do: {:error, "unused", "", %{}, {1, 0}, 0}
      end

      Makeup.Registry.register_lexer(CrashingLexer, names: ["crashy-lang"])

      assert SyntaxHighlighter.highlight_lines("whatever", "crashy-lang") ==
               [[%{text: "whatever", fg: nil, styles: []}]]
    end
  end
end
