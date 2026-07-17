defmodule Raxol.UI.Components.Harness.LaneNotice do
  @moduledoc """
  The harness footer's persistent live-session status channel as a
  controlled Component (harness TEA migration §4 footer row, unit U2):
  `put_lane_notice/2`'s reports -- "interrupt sent", "reconnecting to live
  session", "session process exited -- transcript preserved". It shares the
  exact line vocabulary of `Raxol.UI.Components.Harness.Notice` (a string,
  or a LIST of strings rendered one row each) and delegates line-building to
  it, so the two honest report channels can never drift; only the semantic
  identity differs.

  ## Why it is a PROTECTED footer channel

  Like `Notice`, the lane channel is an HONEST report, so `FooterStack`'s
  contract keeps `:lane` absent from every `drop_order` -- it is NEVER shed
  to fit the budget. A dropped lane notice would read as "nothing
  happened", the exact fail-safe inversion the channel exists to rule out.
  In display order it sits right after the status strip.

  ## Controlled (§2 doctrine)

  State in via props (`notice`), a pure line-list out; no local mutation,
  no interaction, no MCP action.
  """

  alias Raxol.UI.Components.Harness.Notice

  use Raxol.UI.Components.Base.Component

  @type notice :: Notice.notice()

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
          "harness-lane-notice-#{:erlang.unique_integer([:positive])}"
        ),
      notice: Map.get(props, :notice),
      width: Map.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

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
        kind: :lane,
        component_module: __MODULE__
      },
      style: state.style,
      gap: 0,
      children: lines(state.notice, width)
    }
  end

  @doc """
  The lane channel's footer line elements -- the same line vocabulary as
  `Raxol.UI.Components.Harness.Notice.lines/2` (one row per notice string,
  width-truncated). Delegated so lane and refusal notices never drift.
  """
  @spec lines(notice(), integer()) :: [map()]
  def lines(notice, width), do: Notice.lines(notice, width)
end
