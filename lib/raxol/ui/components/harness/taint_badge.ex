defmodule Raxol.UI.Components.Harness.TaintBadge do
  @moduledoc """
  A tiny inline badge marking untrusted, tool-derived content.

  Render-dual of one event envelope's `provenance.trust` field (see
  `docs/proposals/in-flight/harness-spec-protocol.md` sec 3): renders
  `"⚠ untrusted"` in yellow when `provenance.trust == :tainted` (passed in as
  `taint: true`); renders nothing when trusted. This is the frontend's
  lethal-trifecta visibility marker (`harness-spec-frontend.md` sec 6) --
  content whose provenance traces back to untrusted tool output must stay
  visibly marked, never silently blended into the primary feed.

  Composed inline by `Raxol.UI.Components.Harness.ToolResultBlock`.
  """

  alias Raxol.UI.StyleHelper

  use Raxol.UI.Components.Base.Component

  @type t :: %{
          id: String.t() | atom(),
          taint: boolean(),
          style: map(),
          theme: map()
        }

  @label "⚠ untrusted"

  @impl true
  @spec init(keyword()) :: {:ok, t()}
  def init(props) do
    state = %{
      id:
        Keyword.get(
          props,
          :id,
          "taint-badge-#{:erlang.unique_integer([:positive])}"
        ),
      taint: Keyword.get(props, :taint, false),
      style: Keyword.get(props, :style, %{}),
      theme: Keyword.get(props, :theme, %{})
    }

    {:ok, state}
  end

  @impl true
  def handle_event(_event, state, _context), do: {state, []}

  @impl true
  @spec render(t(), map()) :: map()
  def render(%{taint: true} = state, context) do
    base_style =
      StyleHelper.merge_component_styles(state, context, :taint_badge)

    Raxol.View.Components.text(
      id: state.id,
      content: @label,
      style: Map.merge(%{fg: :yellow, bold: true}, base_style)
    )
  end

  def render(state, _context) do
    Raxol.View.Components.text(id: state.id, content: "")
  end
end
