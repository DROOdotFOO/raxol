defmodule Raxol.UI.SyntaxHighlighter do
  @moduledoc """
  Structured-token syntax highlighting for terminal rendering.

  Per `docs/proposals/in-flight/shiki-elixir-analysis.md`: components in
  this codebase emit styled spans (`text(content, fg:, style:)`) -- raw
  ANSI is only ever applied at the final `Terminal.Renderer` stage. A
  highlighter here must therefore yield **structured tokens**
  (`%{text:, fg:, styles:}`), never a pre-rendered ANSI/HTML string. That
  ruled out a Shiki port (Oniguruma/TextMate semantics don't translate to
  Erlang `:re`), `autumn` (tree-sitter engine, but only string output
  formats), and subprocess-based highlighters (`bat`, `chroma`).

  Built on `makeup` (pure-Elixir, Pygments-modeled, already a dependency:
  ExDoc's engine, José Valim/Tiago Barroso). `Makeup.Registry` covers the
  native lexers (elixir, erlang, heex, json, html, css, sql, js/ts,
  gleam, swift, ...) by language name or file extension. If the optional
  `makeup_syntect` dependency (Rust `syntect` NIF, precompiled, MIT) is
  present, it auto-registers 205 additional syntect syntaxes (python, go,
  rust, yaml, bash, markdown, ruby, ...) into the same registry on
  application start -- no extra code here, `Makeup.Registry` lookups just
  start finding them.

  Unknown languages, missing lexers, or a lexer crash all degrade to a
  single unstyled token per line (`fg: nil`) rather than raising -- a
  highlighting failure must never break a render frame.

  ## Tokenization strategy

  Lexers are stateful across lines (a line inside a heredoc or
  multi-line comment tokenizes as garbage in isolation), so callers must
  lex the **whole file text** for a version once, not line-by-line. This
  module does exactly that: `lex/2` runs over the full source, and the
  resulting flat token stream is split into per-line token lists
  (a token whose text spans a newline is split into per-line fragments
  that keep the same token type).
  """

  alias Makeup.Registry
  alias Makeup.Styles.HTML.Style
  alias Makeup.Styles.HTML.StyleMap
  alias Makeup.Styles.HTML.TokenStyle

  @type token :: %{
          text: String.t(),
          fg: String.t() | nil,
          styles: [:bold | :italic | :underline]
        }

  @default_theme :one_dark

  @doc """
  Tokenizes `source` as `language`, returning one token list per line.

  `language` is matched against `Makeup.Registry` by name first, then by
  file extension (so both `"elixir"` and `"ex"` resolve). `nil`, an
  unresolvable language, or a lexer crash all fall back to plain
  (unstyled) lines -- this function never raises.

  `theme` is either an atom naming one of Makeup's 34 built-in Pygments
  styles (`Makeup.Styles.HTML.StyleMap`, e.g. `:one_dark`, `:dracula`,
  `:monokai`) or an already-resolved `%Makeup.Styles.HTML.Style{}`.
  Defaults to `:one_dark`.

  The outer list always has exactly `length(String.split(source, "\\n"))`
  entries, matching `Raxol.UI.Components.Harness.LineDiff`'s line
  splitting, so `Enum.at(highlight_lines(text, lang, theme), n)` lines up
  with 0-based diff line indices for `text`.
  """
  @spec highlight_lines(String.t(), String.t() | nil, atom() | Style.t() | nil) ::
          [[token()]]
  def highlight_lines(source, language, theme \\ @default_theme)

  def highlight_lines("", _language, _theme), do: []

  def highlight_lines(source, nil, _theme) when is_binary(source),
    do: plain_lines(source)

  def highlight_lines(source, language, theme)
      when is_binary(source) and is_binary(language) do
    if Code.ensure_loaded?(Makeup) do
      case fetch_lexer(language) do
        {:ok, {lexer, opts}} -> highlight_with_lexer(source, lexer, opts, theme)
        :error -> plain_lines(source)
      end
    else
      plain_lines(source)
    end
  end

  defp fetch_lexer(language) do
    name = String.downcase(language)

    case Registry.fetch_lexer_by_name(name) do
      {:ok, entry} -> {:ok, entry}
      :error -> Registry.fetch_lexer_by_extension(name)
    end
  rescue
    # `Code.ensure_loaded?(Makeup)` only proves the MODULE is loadable, not
    # that its lexer registry is populated. Makeup stores that registry in
    # `Application.get_env(:makeup, ...)` and fills it only when the Makeup
    # application starts and each lexer self-registers. In a headless/:agent
    # environment that app boot is skipped, so `get_env` returns nil and
    # Makeup's own `Map.fetch(nil, name)` raises BadMapError. A missing
    # highlighter must degrade to plain source, never crash the diff (and the
    # whole block) render -- the same contract `highlight_with_lexer/4` keeps.
    _ -> :error
  end

  defp highlight_with_lexer(source, lexer, opts, theme) do
    style = resolve_style(theme)

    source
    |> lexer.lex(opts)
    |> tokens_to_lines()
    |> apply_theme(style)
  rescue
    _ -> plain_lines(source)
  end

  defp plain_lines(source) do
    source
    |> String.split("\n")
    |> Enum.map(fn line -> [%{text: line, fg: nil, styles: []}] end)
  end

  # -- Theme resolution ----------------------------------------------------

  defp resolve_style(%Style{} = style), do: style
  defp resolve_style(nil), do: resolve_style(@default_theme)

  defp resolve_style(theme) when is_atom(theme) do
    fun = :"#{theme}_style"

    # `function_exported?/3` never loads a module -- without
    # `Code.ensure_loaded?/1` first, an unloaded StyleMap makes this
    # always false, and falling back to `resolve_style(@default_theme)`
    # would recurse on the same unloaded-module check forever.
    if Code.ensure_loaded?(StyleMap) and function_exported?(StyleMap, fun, 0) do
      apply(StyleMap, fun, [])
    else
      StyleMap.one_dark_style()
    end
  end

  # Applies theme colors to every line's tokens in one pass, memoizing
  # the token-type -> TokenStyle lookup (including the Pygments-hierarchy
  # walk-up for non-standard types) per {theme, type} for the call.
  defp apply_theme(lines, style) do
    {result_rev, _cache} =
      Enum.reduce(lines, {[], %{}}, fn line, {lines_acc, cache} ->
        {line_tokens_rev, cache} =
          Enum.reduce(line, {[], cache}, fn {type, text}, {acc, cache} ->
            {token_style, cache} = cached_lookup(style.styles, type, cache)

            token = %{
              text: text,
              fg: token_style && token_style.color,
              styles: font_styles(token_style)
            }

            {[token | acc], cache}
          end)

        {[Enum.reverse(line_tokens_rev) | lines_acc], cache}
      end)

    Enum.reverse(result_rev)
  end

  defp cached_lookup(styles_map, type, cache) do
    case Map.fetch(cache, type) do
      {:ok, token_style} ->
        {token_style, cache}

      :error ->
        token_style = lookup_token_style(styles_map, type)
        {token_style, Map.put(cache, type, token_style)}
    end
  end

  # Makeup's `Style.make_style/1` already fills every standard Pygments
  # token type via inheritance at compile time, so this map hit almost
  # always succeeds directly. The walk-up only matters for a type outside
  # that standard set (e.g. an unmapped syntect scope).
  defp lookup_token_style(styles_map, type) do
    case Map.get(styles_map, type) do
      nil ->
        case parent_type(type) do
          nil -> nil
          parent -> lookup_token_style(styles_map, parent)
        end

      token_style ->
        token_style
    end
  end

  defp parent_type(:text), do: nil

  defp parent_type(type) do
    case type |> Atom.to_string() |> String.split("_") do
      [_single] ->
        :text

      parts ->
        parts
        |> Enum.drop(-1)
        |> Enum.join("_")
        |> String.to_existing_atom()
    end
  rescue
    ArgumentError -> :text
  end

  defp font_styles(nil), do: []

  defp font_styles(%TokenStyle{} = token_style) do
    []
    |> maybe_style(token_style.font_weight == "bold", :bold)
    |> maybe_style(token_style.font_style == "italic", :italic)
    |> maybe_style(token_style.text_decoration == "underline", :underline)
  end

  defp maybe_style(styles, true, style), do: [style | styles]
  defp maybe_style(styles, false, _style), do: styles

  # -- Whole-file tokens -> per-line token lists ---------------------------

  # Lexers are stateful across lines, so `source` is lexed once as a
  # whole; this splits the resulting flat token stream back into per-line
  # `{type, text}` pairs, carrying a token's type across every line
  # fragment when its text spans a newline (multi-line strings/comments).
  defp tokens_to_lines(tokens) do
    {finished_rev, current_rev} =
      Enum.reduce(tokens, {[], []}, &token_into_lines/2)

    [current_rev | finished_rev]
    |> Enum.reverse()
    |> Enum.map(&Enum.reverse/1)
  end

  # Makeup token values are CHARDATA, not iodata: mixed lists of binaries
  # and bare codepoints (e.g. `[":", 101, 117, 114]`). A codepoint above
  # 255 (like "€") makes `IO.iodata_to_binary/1` raise, which the
  # top-level rescue then degrades to plain text for the WHOLE file —
  # `IO.chardata_to_string/1` is the correct conversion.
  defp token_into_lines({type, _meta, chardata}, {finished_rev, current_rev}) do
    case chardata |> IO.chardata_to_string() |> String.split("\n") do
      [only] ->
        {finished_rev, maybe_prepend(type, only, current_rev)}

      [first | rest] ->
        completed = maybe_prepend(type, first, current_rev)
        finish_rest(type, rest, [completed | finished_rev])
    end
  end

  defp finish_rest(type, [last], finished_rev) do
    {finished_rev, maybe_prepend(type, last, [])}
  end

  defp finish_rest(type, [middle | rest], finished_rev) do
    finish_rest(type, rest, [maybe_prepend(type, middle, []) | finished_rev])
  end

  defp maybe_prepend(_type, "", acc), do: acc
  defp maybe_prepend(type, text, acc), do: [{type, text} | acc]
end
