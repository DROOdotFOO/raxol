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
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    style = StyleHelper.merge_component_styles(state, context, :text)

    lines =
      process_content(
        state.content,
        state.width,
        state.white_space,
        state.wrap,
        state.truncate
      )

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

        %{type: :column, style: style, children: children}
    end
  end

  # --- Content processing ---

  defp process_content(content, nil, _white_space, _wrap, _truncate),
    do: [content]

  defp process_content(content, _width, _white_space, _wrap, _truncate)
       when content == "",
       do: [""]

  # CSS `white-space` takes over the whole collapse/preserve/wrap decision
  # whenever it's set to anything other than the default -- at :normal we
  # fall through to the legacy `wrap`-prop dispatch below unchanged.
  defp process_content(content, width, white_space, _wrap, _truncate)
       when white_space != :normal do
    TextLayout.wrap(content, width, white_space)
  end

  defp process_content(content, width, :normal, :none, true) do
    [truncate_line(content, width)]
  end

  defp process_content(content, _width, :normal, :none, false), do: [content]

  defp process_content(content, width, :normal, :word, _truncate) do
    TextLayout.wrap(content, width, :normal)
  end

  defp process_content(content, width, :normal, :char, _truncate) do
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
