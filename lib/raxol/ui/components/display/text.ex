defmodule Raxol.UI.Components.Display.Text do
  @moduledoc """
  Styled text rendering with wrapping, alignment, and truncation.

  Display-only widget -- no keyboard handling.

  Props:
  - `content` (string) -- text to display
  - `wrap` (`:word | :char | :none`) -- wrapping mode, default `:none`
  - `white_space` (`:normal | :nowrap | :pre | :pre_wrap | :pre_line`) --
    CSS `white-space`-following collapse/preserve/wrap semantics, default
    `:normal`. Only takes effect when set to a value other than `:normal`;
    at the default it defers entirely to the legacy `wrap` prop so existing
    callers see zero behavior change. See `Raxol.UI.TextLayout` for the
    unified wrapping implementation.
  - `align` (`:left | :center | :right`) -- alignment within width, default `:left`
  - `width` (integer | nil) -- constraint for wrapping/alignment/truncation
  - `truncate` (boolean) -- truncate with ellipsis when exceeding width, default `false`
  - `text_overflow` (`:clip | :ellipsis`) -- CSS `text-overflow`-following
    single-line truncation, default `:clip` (a no-op; existing rendering
    already visually clips at the buffer edge). Only takes effect when
    `white_space` is `:nowrap` or `:pre` (the CSS-spec-following
    non-wrapping cases) and set to `:ellipsis`; at any other combination
    it defers entirely, so existing callers see zero behavior change. See
    `Raxol.UI.TextLayout.truncate/3`.
  - `line_clamp` (`pos_integer | nil`) -- CSS Overflow Module Level 4
    `line-clamp`: caps wrapped output at this many lines, block-ellipsing
    the last kept line, default `nil` (a no-op). When set, it overrides
    the legacy `wrap`/`truncate` dispatch entirely and wraps via
    `white_space` (default `:normal`) through
    `Raxol.UI.TextLayout.clamp/4`.
  - `style`, `theme`, `id` -- standard
  """

  alias Raxol.UI.Components.Input.TextWrapping
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextLayout

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          content: String.t(),
          wrap: :word | :char | :none,
          white_space: TextLayout.white_space(),
          align: :left | :center | :right,
          width: non_neg_integer() | nil,
          truncate: boolean(),
          text_overflow: :clip | :ellipsis,
          line_clamp: pos_integer() | nil,
          text_wrap: :auto | :pretty,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(props, :id, "text-#{:erlang.unique_integer([:positive])}"),
      content: Keyword.get(props, :content, ""),
      wrap: Keyword.get(props, :wrap, :none),
      white_space: Keyword.get(props, :white_space, :normal),
      align: Keyword.get(props, :align, :left),
      width: Keyword.get(props, :width),
      truncate: Keyword.get(props, :truncate, false),
      text_overflow: Keyword.get(props, :text_overflow, :clip),
      line_clamp: Keyword.get(props, :line_clamp),
      text_wrap: Keyword.get(props, :text_wrap, :auto),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    style = StyleHelper.merge_component_styles(state, context, :text)

    # `text_wrap: :pretty` replaces the greedy break-point choice for
    # plain wrapped text; `line_clamp` (which does its own wrapping) and
    # non-:normal white-space modes take priority and ignore it.
    lines =
      if Map.get(state, :text_wrap, :auto) == :pretty and
           state.white_space == :normal and is_integer(state.width) and
           is_nil(state.line_clamp) and state.content != "" do
        TextLayout.wrap(state.content, state.width, :normal, :pretty)
      else
        process_content(
          state.content,
          state.width,
          state.white_space,
          state.wrap,
          state.truncate,
          state.text_overflow,
          state.line_clamp
        )
      end

    lines = align_lines(lines, state.width, state.align)

    case lines do
      [single] ->
        Raxol.View.Components.text(id: state.id, content: single, style: style)

      multiple ->
        children =
          multiple
          |> Enum.with_index()
          |> Enum.map(fn {line, i} ->
            Raxol.View.Components.text(
              id: "#{state.id}-line-#{i}",
              content: line,
              style: style
            )
          end)

        %{type: :column, style: style, children: children, gap: 0}
    end
  end

  # --- Content processing ---

  defp process_content(
         content,
         nil,
         _white_space,
         _wrap,
         _truncate,
         _text_overflow,
         _line_clamp
       ),
       do: [content]

  defp process_content(
         content,
         _width,
         _white_space,
         _wrap,
         _truncate,
         _text_overflow,
         _line_clamp
       )
       when content == "",
       do: [""]

  # `line_clamp` overrides the legacy `wrap`/`truncate` dispatch entirely
  # (and takes priority over `white_space`, which it passes through to
  # TextLayout.clamp/4 as the wrapping mode) whenever it's set.
  defp process_content(
         content,
         width,
         white_space,
         _wrap,
         _truncate,
         _text_overflow,
         line_clamp
       )
       when is_integer(line_clamp) do
    TextLayout.clamp(content, width, line_clamp, white_space: white_space)
  end

  # `text-overflow: ellipsis` only applies to the non-wrapping CSS
  # `white-space` cases (`:nowrap`, `:pre`); `:clip` (the default) is a
  # no-op here since rendering already clips visually at the buffer edge.
  defp process_content(
         content,
         width,
         white_space,
         _wrap,
         _truncate,
         :ellipsis,
         _line_clamp
       )
       when white_space in [:nowrap, :pre] do
    content
    |> TextLayout.wrap(width, white_space)
    |> Enum.map(&TextLayout.truncate(&1, width, :ellipsis))
  end

  # CSS `white-space` takes over the whole collapse/preserve/wrap decision
  # whenever it's set to anything other than the default -- at :normal we
  # fall through to the legacy `wrap`-prop dispatch below unchanged.
  defp process_content(
         content,
         width,
         white_space,
         _wrap,
         _truncate,
         _text_overflow,
         _line_clamp
       )
       when white_space != :normal do
    TextLayout.wrap(content, width, white_space)
  end

  defp process_content(
         content,
         width,
         :normal,
         :none,
         true,
         _text_overflow,
         _line_clamp
       ) do
    [truncate_line(content, width)]
  end

  defp process_content(
         content,
         _width,
         :normal,
         :none,
         false,
         _text_overflow,
         _line_clamp
       ),
       do: [content]

  defp process_content(
         content,
         width,
         :normal,
         :word,
         _truncate,
         _text_overflow,
         _line_clamp
       ) do
    TextLayout.wrap(content, width, :normal)
  end

  defp process_content(
         content,
         width,
         :normal,
         :char,
         _truncate,
         _text_overflow,
         _line_clamp
       ) do
    TextWrapping.wrap_line_by_char(content, width)
  end

  defp truncate_line(text, width) when width < 4 do
    String.slice(text, 0, width)
  end

  defp truncate_line(text, width) do
    if Raxol.UI.TextMeasure.display_width(text) > width do
      {left, _} = Raxol.UI.TextMeasure.split_at_display_width(text, width - 3)
      left <> "..."
    else
      text
    end
  end

  # --- Alignment ---

  defp align_lines(lines, nil, _align), do: lines
  defp align_lines(lines, _width, :left), do: lines

  defp align_lines(lines, width, :right) do
    Enum.map(lines, fn line ->
      pad = max(width - Raxol.UI.TextMeasure.display_width(line), 0)
      String.duplicate(" ", pad) <> line
    end)
  end

  defp align_lines(lines, width, :center) do
    Enum.map(lines, fn line ->
      total_pad = max(width - Raxol.UI.TextMeasure.display_width(line), 0)
      left_pad = div(total_pad, 2)
      right_pad = total_pad - left_pad

      String.duplicate(" ", left_pad) <>
        line <> String.duplicate(" ", right_pad)
    end)
  end
end
