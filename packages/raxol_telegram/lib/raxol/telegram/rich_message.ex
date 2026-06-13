defmodule Raxol.Telegram.RichMessage do
  @moduledoc """
  Builders for Telegram Bot API 10.1 Rich Messages.

  Bot API 10.1 (released 2026-06-11) introduced `sendRichMessage` and
  `sendRichMessageDraft` for structured content beyond MarkdownV2: tables,
  collapsible sections, headings, mathematical expressions, sub/superscript,
  AI-thinking blocks, and an expanded 32,768 character cap.

  This module produces the wire payload via composable builders. Builders
  return plain maps with atom keys; Jason encodes them directly. The hand-off
  to HTTP lives in `Raxol.Telegram.RichMessage.Sender` so this module stays
  pure.

  Telegex 1.8 predates Bot API 10.1 and does not expose `sendRichMessage`.
  Calls go through raw HTTP via the optional `:req` dependency. When `:req`
  is absent, the Sender returns `{:error, :req_not_available}`.

  ## Length limits

  Bot API 10.1 raises the message text cap from 4,096 to 32,768 characters.
  `chunk/2` enforces a configurable Show More boundary (default 8,000) by
  wrapping the tail of long content in a `details` block (collapsible).
  Content over `max_chars` returns `{:error, :too_long}` rather than being
  silently truncated.

  ## Wire format note

  The JSON discriminator field used is `type` with snake_case values
  (`"bold"`, `"paragraph"`, `"table_cell"`, etc.), mirroring the existing
  MessageEntity convention. The Bot API 10.1 schema was documented at the
  class-name level (`RichBlockTable`, `RichTextBold`, etc.) at release time;
  this module assumes the wire keys derive from those class names by
  stripping the prefix and snake-casing. If Telegram's actual wire format
  differs, the only adjustment needed is the discriminator string in each
  builder.

  ## Example

      import Raxol.Telegram.RichMessage

      msg = rich_message([
        heading(1, "Build status"),
        paragraph([bold("master"), text(" is red")]),
        details([text("Show stacktrace")], [
          paragraph([code("UndefinedFunctionError")])
        ]),
        table([
          [cell([bold("Module")]),       cell([bold("Coverage")])],
          [cell([text("Bot")]),          cell([text("94%")])],
          [cell([text("RichMessage")]),  cell([text("100%")])]
        ]),
        math(~S"\\int_0^1 x^2 dx = \\frac{1}{3}")
      ])

      {:ok, _} = Raxol.Telegram.RichMessage.Sender.send(chat_id, msg)
  """

  @max_chars 32_768
  @show_more_threshold 8_000

  @type inline_node :: map()
  @type block_node :: map()
  @type rich_message :: %{required(:blocks) => [block_node()]}

  # --- Envelope ---

  @doc "Wraps a list of block nodes as a rich message."
  @spec rich_message([block_node()]) :: rich_message()
  def rich_message(blocks) when is_list(blocks), do: %{blocks: blocks}

  # --- Inline RichText builders ---

  @doc "Plain text leaf node."
  @spec text(String.t()) :: inline_node()
  def text(string) when is_binary(string), do: %{type: "text", text: string}

  @doc "Bold inline. Accepts a string or a list of inline nodes."
  @spec bold([inline_node()] | String.t()) :: inline_node()
  def bold(children) when is_list(children), do: inline_wrapper("bold", children)
  def bold(string) when is_binary(string), do: bold([text(string)])

  @doc "Italic inline."
  @spec italic([inline_node()] | String.t()) :: inline_node()
  def italic(children) when is_list(children), do: inline_wrapper("italic", children)
  def italic(string) when is_binary(string), do: italic([text(string)])

  @doc "Underline inline."
  @spec underline([inline_node()] | String.t()) :: inline_node()
  def underline(children) when is_list(children), do: inline_wrapper("underline", children)
  def underline(string) when is_binary(string), do: underline([text(string)])

  @doc "Strikethrough inline."
  @spec strikethrough([inline_node()] | String.t()) :: inline_node()
  def strikethrough(children) when is_list(children),
    do: inline_wrapper("strikethrough", children)

  def strikethrough(string) when is_binary(string), do: strikethrough([text(string)])

  @doc "Monospace code inline. Always a leaf (no nested formatting)."
  @spec code(String.t()) :: inline_node()
  def code(string) when is_binary(string), do: %{type: "code", text: string}

  @doc "Spoiler inline (hidden until tapped)."
  @spec spoiler([inline_node()] | String.t()) :: inline_node()
  def spoiler(children) when is_list(children), do: inline_wrapper("spoiler", children)
  def spoiler(string) when is_binary(string), do: spoiler([text(string)])

  @doc "Subscript inline."
  @spec subscript([inline_node()] | String.t()) :: inline_node()
  def subscript(children) when is_list(children), do: inline_wrapper("subscript", children)
  def subscript(string) when is_binary(string), do: subscript([text(string)])

  @doc "Superscript inline."
  @spec superscript([inline_node()] | String.t()) :: inline_node()
  def superscript(children) when is_list(children),
    do: inline_wrapper("superscript", children)

  def superscript(string) when is_binary(string), do: superscript([text(string)])

  @doc "Inline mathematical expression (LaTeX-style)."
  @spec math_inline(String.t()) :: inline_node()
  def math_inline(expression) when is_binary(expression),
    do: %{type: "mathematical_inline", expression: expression}

  # --- Block RichBlock builders ---

  @doc "Paragraph block. Accepts a string (wrapped in text/1) or inline nodes."
  @spec paragraph([inline_node()] | String.t()) :: block_node()
  def paragraph(children) when is_list(children),
    do: %{type: "paragraph", children: children}

  def paragraph(string) when is_binary(string), do: paragraph([text(string)])

  @doc "Heading block at the given level (1-6)."
  @spec heading(1..6, [inline_node()] | String.t()) :: block_node()
  def heading(level, children) when level in 1..6 and is_list(children),
    do: %{type: "heading", level: level, children: children}

  def heading(level, string) when level in 1..6 and is_binary(string),
    do: heading(level, [text(string)])

  @doc "Table block. Rows are lists of `cell/1` children."
  @spec table([[block_node()]]) :: block_node()
  def table(rows) when is_list(rows), do: %{type: "table", rows: rows}

  @doc "Table cell. Children may be inline or block nodes."
  @spec cell([inline_node() | block_node()]) :: block_node()
  def cell(children) when is_list(children), do: %{type: "table_cell", children: children}

  @doc """
  List block. `:ordered` option (default `false`) selects bullet vs numbered.
  Items must be produced by `list_item/1`.
  """
  @spec list([block_node()], keyword()) :: block_node()
  def list(items, opts \\ []) when is_list(items),
    do: %{type: "list", ordered: Keyword.get(opts, :ordered, false), items: items}

  @doc "List item. Accepts a string (wrapped in paragraph/1) or block nodes."
  @spec list_item([block_node()] | String.t()) :: block_node()
  def list_item(children) when is_list(children),
    do: %{type: "list_item", children: children}

  def list_item(string) when is_binary(string), do: list_item([paragraph(string)])

  @doc """
  Collapsible details block. `summary` is the always-visible header,
  `children` are revealed when the user taps to expand.
  """
  @spec details([inline_node()], [block_node()]) :: block_node()
  def details(summary, children) when is_list(summary) and is_list(children),
    do: %{type: "details", summary: summary, children: children}

  @doc "Display mathematical expression (block-level, LaTeX-style)."
  @spec math(String.t()) :: block_node()
  def math(expression) when is_binary(expression),
    do: %{type: "mathematical", expression: expression}

  @doc """
  AI thinking block. Renders as the "reasoning" expanded view that Telegram
  clients collapse by default. Used with `Sender.send_draft/3` for streaming.
  """
  @spec thinking([block_node()]) :: block_node()
  def thinking(children) when is_list(children),
    do: %{type: "thinking", children: children}

  # --- Length analysis ---

  @doc "Sums the displayable character length of all leaf text in the tree."
  @spec text_length(map() | [map()]) :: non_neg_integer()
  def text_length(%{blocks: blocks}), do: sum_lengths(blocks)
  def text_length(nodes) when is_list(nodes), do: sum_lengths(nodes)
  def text_length(%{type: type, text: t}) when type in ["text", "code"], do: String.length(t)

  def text_length(%{type: type, expression: e})
      when type in ["mathematical", "mathematical_inline"],
      do: String.length(e)

  def text_length(%{type: "table", rows: rows}) do
    Enum.reduce(rows, 0, fn row, acc -> acc + sum_lengths(row) end)
  end

  def text_length(%{type: "details", summary: summary, children: children}),
    do: sum_lengths(summary) + sum_lengths(children)

  def text_length(%{type: "list", items: items}), do: sum_lengths(items)

  def text_length(%{type: _, children: children}) when is_list(children),
    do: sum_lengths(children)

  def text_length(_), do: 0

  defp sum_lengths(nodes) when is_list(nodes),
    do: Enum.reduce(nodes, 0, fn n, acc -> acc + text_length(n) end)

  # --- Chunking (Show More) ---

  @doc """
  Splits a long rich message at the Show More threshold by wrapping the tail
  in a `details` block. Returns the message unchanged when total length is
  under threshold.

  Returns `{:error, :too_long}` when total length exceeds `max_chars`
  (default 32,768).

  ## Options

    * `:show_more_threshold`: character budget before chunking (default 8,000)
    * `:max_chars`: hard cap (default 32,768)
    * `:summary`: inline text shown for the collapsed section header
      (default `"Show more"`)
  """
  @spec chunk(rich_message(), keyword()) :: {:ok, rich_message()} | {:error, :too_long}
  def chunk(%{blocks: blocks} = msg, opts \\ []) do
    threshold = Keyword.get(opts, :show_more_threshold, @show_more_threshold)
    max_chars = Keyword.get(opts, :max_chars, @max_chars)
    summary_text = Keyword.get(opts, :summary, "Show more")

    total = text_length(msg)

    cond do
      total > max_chars -> {:error, :too_long}
      total <= threshold -> {:ok, msg}
      true -> chunk_with_details(blocks, threshold, summary_text, msg)
    end
  end

  defp chunk_with_details(blocks, threshold, summary_text, original) do
    {head_rev, tail} = split_blocks(blocks, threshold)

    case tail do
      [] -> {:ok, original}
      _ -> {:ok, %{blocks: Enum.reverse([details([text(summary_text)], tail) | head_rev])}}
    end
  end

  defp split_blocks(blocks, threshold) do
    {head_rev, tail_rev, _acc} =
      Enum.reduce(blocks, {[], [], 0}, &place_block(&1, &2, threshold))

    {head_rev, Enum.reverse(tail_rev)}
  end

  defp place_block(block, {head_rev, tail_rev, acc}, _threshold) when tail_rev != [] do
    {head_rev, [block | tail_rev], acc}
  end

  defp place_block(block, {head_rev, [], acc}, threshold) do
    block_len = text_length(block)

    if acc + block_len > threshold and head_rev != [] do
      {head_rev, [block], acc + block_len}
    else
      {[block | head_rev], [], acc + block_len}
    end
  end

  # --- Payload assembly ---

  @doc """
  Builds the `sendRichMessage` HTTP body for a chat.

  Returns a map suitable for Jason encoding and POST to the Bot API.

  ## Options

    * `:reply_markup`: inline keyboard or other reply markup map
    * `:disable_notification`: bool
    * `:reply_to_message_id`: integer
    * `:parse_mode_fallback`: string ("HTML" or "MarkdownV2") set on a
      fallback `text` field for older clients that don't yet support
      `sendRichMessage`. Not currently emitted (reserved for future use).
  """
  @spec to_payload(integer() | String.t(), rich_message(), keyword()) :: map()
  def to_payload(chat_id, %{blocks: _} = rich_message, opts \\ []) do
    base = %{chat_id: chat_id, rich_message: rich_message}

    Enum.reduce(opts, base, fn
      {key, value}, acc
      when key in [:reply_markup, :disable_notification, :reply_to_message_id] ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  @doc "Returns the hard cap on rich message content length."
  @spec max_chars() :: pos_integer()
  def max_chars, do: @max_chars

  @doc "Returns the default Show More chunking threshold."
  @spec show_more_threshold() :: pos_integer()
  def show_more_threshold, do: @show_more_threshold

  # --- Private ---

  defp inline_wrapper(type, children), do: %{type: type, children: children}
end
