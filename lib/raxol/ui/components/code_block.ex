defmodule Raxol.UI.Components.CodeBlock do
  @moduledoc """
  Renders a block of code with **structured** syntax highlighting for the
  terminal.

  Reuses `Raxol.UI.SyntaxHighlighter` — the same Makeup-backed, token-based
  path that Pierre-style diffs (`Harness.DiffViewer`) use. Tokens carry
  hex `fg` + font styles and are painted as styled `text/1` spans; raw
  ANSI is never embedded (only applied at the final Terminal.Renderer).

  The previous implementation called `Makeup.highlight_inner_html/2` and
  then stripped the HTML tags, which discarded every color. That path is
  gone.

  ## Props

    * `:content` (string) — source code (default `""`)
    * `:language` (string) — language name or extension for
      `Makeup.Registry` (e.g. `"elixir"`, `"ex"`, `"python"`). Unknown
      languages degrade to unstyled plain text, never raise.
    * `:theme` (atom | `%Makeup.Styles.HTML.Style{}`) — Makeup style
      (default `:one_dark`, same as DiffViewer)
  """
  use Raxol.UI.Components.Base.Component

  alias Raxol.UI.SyntaxHighlighter
  alias Raxol.View.Components

  @default_theme :one_dark

  @doc """
  Highlights `source` and returns one row element per line (token spans).

  Public so other renderers (e.g. `MarkdownRenderer` fenced blocks) can
  reuse the exact CodeBlock line shape without nesting a full column.
  Empty lines yield a single empty text cell so vertical spacing holds.
  """
  @spec render_lines(String.t(), String.t() | nil, atom() | term()) :: [map()]
  def render_lines(source, language \\ "text", theme \\ @default_theme)

  def render_lines(source, language, theme) when is_binary(source) do
    lang = language || "text"

    source
    |> SyntaxHighlighter.highlight_lines(lang, theme)
    |> Enum.map(&line_row/1)
  end

  @doc """
  Renders the code block as a column of token-span rows.
  """
  @spec render(map(), map()) :: map()
  @impl true
  def render(state, _context) do
    source = state[:content] || ""
    language = state[:language] || "text"
    theme = state[:theme] || @default_theme

    Components.column(
      gap: 0,
      children: render_lines(source, language, theme)
    )
  end

  defp line_row([]) do
    # Empty source line — preserve vertical spacing with a blank cell.
    Components.row(gap: 0, children: [Components.text(content: "")])
  end

  defp line_row(tokens) do
    spans =
      Enum.map(tokens, fn token ->
        Components.text(
          content: token.text,
          style: token_style(token)
        )
      end)

    Components.row(gap: 0, children: spans)
  end

  defp token_style(%{fg: fg, styles: styles}) do
    base = if is_binary(fg), do: %{fg: fg}, else: %{}

    Enum.reduce(styles || [], base, fn
      :bold, acc -> Map.put(acc, :bold, true)
      :italic, acc -> Map.put(acc, :italic, true)
      :underline, acc -> Map.put(acc, :underline, true)
      _, acc -> acc
    end)
  end

  @doc "Initializes the component state from props."
  @spec init(map()) :: {:ok, map()}
  @impl true
  def init(props), do: {:ok, props}

  @doc "Updates the component state. No updates are handled by default."
  @spec update(term(), map()) :: map()
  @impl true
  def update(_message, state), do: state

  @doc "Handles events for the component. No events are handled by default."
  @spec handle_event(term(), map(), map()) :: {map(), list()}
  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec mount(map()) :: {map(), list()}
  def mount(state), do: {state, []}

  @impl true
  @spec unmount(map()) :: map()
  def unmount(state), do: state
end
