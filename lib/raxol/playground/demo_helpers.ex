defmodule Raxol.Playground.DemoHelpers do
  @moduledoc """
  Shared helpers for playground demo TEA apps.

  Small utilities that eliminate the most common duplication
  across demos while keeping demos self-contained and readable.
  """

  @doc """
  Moves a cursor index down (increment), clamped to `max_index`.
  """
  @spec cursor_down(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def cursor_down(current, max_index), do: min(current + 1, max_index)

  @doc """
  Moves a cursor index up (decrement), clamped to 0.
  """
  @spec cursor_up(non_neg_integer()) :: non_neg_integer()
  def cursor_up(current), do: max(current - 1, 0)

  @doc """
  Returns `"> "` if `index` matches `selected`, else `"  "`.
  """
  @spec cursor_prefix(non_neg_integer(), non_neg_integer()) :: String.t()
  def cursor_prefix(index, selected) when index == selected, do: "> "
  def cursor_prefix(_index, _selected), do: "  "

  @doc """
  Cycles an index forward through a list length, wrapping around.
  """
  @spec cycle_next(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def cycle_next(current, count), do: rem(current + 1, count)

  @doc """
  Returns the effective width for a demo element, clamping `desired` to the
  available width injected by the playground app. Falls back to `desired` when
  running outside the playground.
  """
  @spec effective_width(map(), pos_integer()) :: pos_integer()
  def effective_width(model, desired) do
    case Map.get(model, :available_width) do
      avail when is_integer(avail) and avail > 0 -> min(desired, avail)
      _ -> desired
    end
  end

  @doc """
  Renders text through `Raxol.UI.Components.Display.Text`, the canonical
  wrapping/truncation entry point (`docs/core/LAYOUT.md` section 4:
  `white_space`, `text_overflow`, `line_clamp`, `text_wrap: :pretty`).

  The plain View DSL `text/1`/`text/2` helper (`Raxol.Core.Renderer.View`)
  only supports `fg`/`bg`/`style`/`align`/`wrap`/`link` -- it has no
  CSS-style wrapping/truncation props of its own. Demos that want to show
  `white_space`, `text_overflow`, `line_clamp`, or `text_wrap: :pretty`
  need the actual `Display.Text` component; this wraps its `init/1` +
  `render/2` lifecycle so it drops into a `row`/`column`/`box` children
  list exactly like `text/1`.

  ## Examples

      rich_text("a very long line", width: 12, white_space: :nowrap, text_overflow: :ellipsis)
      rich_text(prose, width: 20, text_wrap: :pretty)
      rich_text(prose, width: 20, line_clamp: 2)
  """
  @spec rich_text(String.t(), keyword()) :: map()
  def rich_text(content, opts \\ []) do
    {:ok, state} =
      Raxol.UI.Components.Display.Text.init([content: content] ++ opts)

    Raxol.UI.Components.Display.Text.render(state, %{})
  end

  @doc """
  Renders `content` (Markdown text) through
  `Raxol.UI.Components.MarkdownRenderer` -- the canonical Markdown-to-styled-
  elements renderer (bold/italic/code spans, headings, lists, blockquotes,
  code blocks, horizontal rules). Wraps its `init/1` + `render/2` lifecycle
  so it drops into a `row`/`column`/`box` children list exactly like
  `text/1` and `rich_text/2`.

  ## Examples

      markdown("# Title\\n\\nSome **bold** text.", 40)
  """
  @spec markdown(String.t(), pos_integer()) :: map()
  def markdown(content, width) do
    {:ok, state} =
      Raxol.UI.Components.MarkdownRenderer.init(%{
        markdown_text: content,
        width: width
      })

    Raxol.UI.Components.MarkdownRenderer.render(state, %{})
  end

  @doc """
  Navigate backward through input history.

  Expects the model to have `:input_history`, `:history_index`, `:input`, and `:cursor` fields.
  """
  @spec history_prev(map()) :: map()
  def history_prev(%{input_history: []} = model), do: model

  def history_prev(model) do
    idx = (model.history_index || -1) + 1
    idx = min(idx, length(model.input_history) - 1)
    input = Enum.at(model.input_history, idx, model.input)
    %{model | history_index: idx, input: input, cursor: String.length(input)}
  end

  @doc """
  Navigate forward through input history.

  Expects the model to have `:input_history`, `:history_index`, `:input`, and `:cursor` fields.
  """
  @spec history_next(map()) :: map()
  def history_next(model) do
    case model.history_index do
      nil ->
        model

      0 ->
        %{model | history_index: nil, input: "", cursor: 0}

      idx ->
        new_idx = idx - 1
        input = Enum.at(model.input_history, new_idx, "")

        %{
          model
          | history_index: new_idx,
            input: input,
            cursor: String.length(input)
        }
    end
  end
end
