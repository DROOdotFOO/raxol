defmodule Raxol.UI.Components.Harness.Notice do
  @moduledoc """
  The harness footer's honest report channel as a controlled Component
  (harness TEA migration §4 footer row, unit U2). Renders a one-frame
  notice -- a refusal ("no block focused"), a degradation warning, a
  charged-minimum absence report -- as footer line elements.

  This is the byte-for-byte re-hosting of the retired
  `Raxol.Harness.Surface`'s
  `notice_line/2`: `nil` renders nothing; a single string renders one
  physical row; a LIST of strings renders one row each, so a long first
  notice can never truncate away a later one (the degraded-resume warning
  rides this). Each row is truncated to the display width through
  `Raxol.UI.TextMeasure` (the blessed facade -- CJK/emoji aware, never
  `String.length/1`).

  ## Why it is a PROTECTED footer channel

  A notice IS the honest report that something was refused or degraded; a
  dropped one reads as "nothing happened" -- the exact fail-safe inversion
  the channel exists to rule out. So in `FooterStack`'s contract the
  `:notice` group is deliberately absent from every `drop_order` (never
  shed), and the flattened footer's last-resort head-take keeps the
  EARLIEST notice rows rather than the composer's tail. This Component only
  produces the rows; the never-shed guarantee is `FooterStack`'s.

  ## Controlled (§2 doctrine)

  State in via props (`notice`), a pure line-list out; no local mutation,
  no interaction, no MCP action (the honest absence -- a report channel has
  nothing to click).
  """

  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @ellipsis "…"

  @type notice :: String.t() | [String.t()] | nil

  @type t :: %{
          id: String.t() | atom(),
          notice: notice(),
          width: pos_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    state = %{
      id:
        Map.get(
          props,
          :id,
          "harness-notice-#{:erlang.unique_integer([:positive])}"
        ),
      notice: Map.get(props, :notice),
      width: Map.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # A report channel has nothing to click.
  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    width = context[:available_width] || state.width

    %{
      type: :column,
      id: state.id,
      attrs: %{
        kind: :notice,
        component_module: __MODULE__
      },
      style: state.style,
      gap: 0,
      children: lines(state.notice, width)
    }
  end

  @doc """
  The notice's footer line elements: `nil` -> `[]`; a string -> one row per
  `\\n`-split physical line, each width-truncated; a list -> the flat
  concatenation, so each notice keeps its own row. Byte-for-byte
  `Surface.notice_line/2`, retargeted from strings to
  `Raxol.View.Components.text/1` nodes (the `FooterStack` line-list shape).
  """
  @spec lines(notice(), integer()) :: [map()]
  def lines(nil, _width), do: []

  def lines(notices, width) when is_list(notices) do
    Enum.flat_map(notices, &lines(&1, width))
  end

  def lines(text, width) when is_binary(text) and is_integer(width) do
    text
    |> String.split("\n")
    |> Enum.map(fn line ->
      Components.text(content: truncate_to_width(line, width))
    end)
  end

  # Truncate to the display width with a trailing ellipsis (the shelved
  # substrate's `ViewText` :styled truncation, re-expressed on the blessed
  # `TextMeasure` facade). A non-positive width yields the empty string.
  defp truncate_to_width(_text, width) when width <= 0, do: ""

  defp truncate_to_width(text, width) do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> @ellipsis
    end
  end
end
