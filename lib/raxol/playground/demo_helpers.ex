defmodule Raxol.Playground.DemoHelpers do
  @moduledoc """
  Shared helpers for playground demo TEA apps.

  Small utilities that eliminate the most common duplication
  across demos while keeping demos self-contained and readable.
  """

  import Raxol.Core.Renderer.View, only: [text: 2]

  @default_log_limit 8

  @doc """
  Prepend an entry to the demo's event log (newest-first), trimming to `limit`.

  The event log is the storybook "actions panel": every demo that mounts a
  real component records the events it routes and the outcomes it observes,
  rendered at the bottom of the demo via `event_log_lines/2`. Entries are
  plain strings built by the demo (it knows how to summarize its own events),
  stored in the model's `:event_log` field.

  ## Examples

      model
      |> DemoHelpers.log_event("key \\"a\\" -> len=4 cursor=4")
      |> DemoHelpers.log_event("focus -> focused=true")
  """
  @spec log_event(map(), String.t(), pos_integer()) :: map()
  def log_event(model, entry, limit \\ @default_log_limit)
      when is_binary(entry) do
    log = [entry | Map.get(model, :event_log, [])] |> Enum.take(limit)
    Map.put(model, :event_log, log)
  end

  @doc """
  Renders the demo's event log as a titled block of dim text lines,
  newest first. Returns `[element]` for splicing into a column's children.

  Options: `:title` (default `"events"`), `:empty` (text shown when no
  entries yet, default `"(no events yet — interact above)"`).
  """
  @spec event_log_lines(map(), keyword()) :: [map()]
  def event_log_lines(model, opts \\ []) do
    title = Keyword.get(opts, :title, "events")
    empty = Keyword.get(opts, :empty, "(no events yet — interact above)")
    log = Map.get(model, :event_log, [])

    entries =
      case log do
        [] -> [text("   #{empty}", style: [:dim])]
        _ -> Enum.map(log, fn entry -> text("   " <> entry, style: [:dim]) end)
      end

    [text(" #{title} (newest first):", style: [:bold, :dim])] ++ entries
  end

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
  Renders text through `Raxol.UI.Components.Display.Text`
  (canonical wrapping/truncation entry point, `docs/core/LAYOUT.md` §4).

  Plain `Raxol.Core.Renderer.View.text/2` accepts only `fg/bg/style/align/wrap/link`.

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
  Renders `content` (Markdown text) through `Raxol.UI.Components.MarkdownRenderer`,
  the canonical Markdown-to-styled-elements renderer.

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
