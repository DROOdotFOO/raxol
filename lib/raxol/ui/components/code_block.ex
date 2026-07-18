defmodule Raxol.UI.Components.CodeBlock do
  @moduledoc """
  Renders a block of code with syntax highlighting.

  Uses Makeup for tokenization when available, with graceful fallback to
  plain text when Makeup is not loaded.
  """
  use Raxol.UI.Components.Base.Component

  @doc """
  Renders the code block.

  Props:
    * `content` (required): The source code string.
    * `language` (optional): The language name (e.g., "elixir"). Defaults to "text".
  """
  @spec render(map(), map()) :: any()
  @impl true
  def render(state, _context) do
    language = state[:language] || "text"
    code_content = state[:content] || ""

    if Code.ensure_loaded?(Makeup) do
      lexer_opt = lexer_for_language(language)
      opts = if lexer_opt, do: [lexer: lexer_opt], else: []

      highlighted = Makeup.highlight_inner_html(code_content, opts)
      Raxol.View.Components.text(content: strip_html_tags(highlighted))
    else
      Raxol.View.Components.text(content: code_content)
    end
  end

  @doc "Initializes the component state from props."
  @spec init(map()) :: {:ok, map()}
  @impl true
  def init(props), do: {:ok, props}

  @doc "Updates the component state. No updates are handled by default."
  @spec update(term(), map()) :: map()
  @impl true
  def update(_message, state), do: state

  @doc """
  Mount hook - called when component is mounted.
  No special setup needed for CodeBlock.
  """
  @impl true
  @spec mount(map()) :: {map(), list()}
  def mount(state), do: {state, []}

  @doc """
  Unmount hook - called when component is unmounted.
  No cleanup needed for CodeBlock.
  """
  @impl true
  @spec unmount(map()) :: map()
  def unmount(state), do: state

  @lexer_map %{
    "elixir" => Makeup.Lexers.ElixirLexer,
    "ex" => Makeup.Lexers.ElixirLexer
  }

  defp lexer_for_language(language) do
    Map.get(@lexer_map, String.downcase(language))
  end

  defp strip_html_tags(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
    |> String.replace("&quot;", "\"")
  end
end
