defmodule Raxol.UI.Components.Harness.StatusStrip do
  @moduledoc """
  The pinned status strip as a controlled TEA Component (harness TEA
  migration §4 footer row, unit U2). A thin re-hosting of the pure
  projection `Raxol.Harness.StatusStrip` (`state -> [footer_line]`, the
  charged-minimum form): this Component adds the *view-path* seam the pure
  core deliberately omits -- the strip-visibility gate, the tick-driven
  braille spinner injection, and the id/attrs stamp -- while leaving all of
  the phase / elapsed / ctx / cost / stall-alert logic in the pure core
  where its own test suite pins it.

  ## Controlled (§2 doctrine)

  State in via props (`status` map + `width` + `spinner_frame`), a pure
  list-of-line-elements out; no `ComponentManager`, no local mutation, no
  interaction (the strip is a read-only instrument -- the honest absence of
  an MCP action). The host owns the `status` map and the tick counter.

  ## The visibility gate (ported from the retired `Raxol.Harness.Surface`)

  `visible?/1` and `live_turn?/1` are the byte-for-byte port of the
  surface's `strip_visible?/1` + `live_turn?/1`. The strip is a *grown
  instrument* (doctrine §1.2): it renders only while the session has
  something TRUE to say -- a live turn, an approval wait (`needs_input`), a
  stall alarm, or a turn-in-flight `:activity` that is animating -- and
  yields to silence (`[]`, no line at all) at boot and between turns. An
  idle `Stage: - | Ctx: - | Cost: -` frame is the "airiness with nothing to
  say" the charged-minimum ruling banned.

  ## The tick-driven spinner (one clock, shared source)

  When the turn is animating (`Raxol.Harness.StatusStrip.animating?/1`) the
  strip prepends a braille spinner frame to the phase segment. The frame is
  resolved from `spinner_frame` (a caller-advanced tick counter) against the
  shared `Raxol.Harness.StatusStrip.spinner_glyphs/0` -- the SAME frame set
  and the SAME counter the transcript's running-tool margin spinner rides,
  so strip pulse and margin pulse never drift and this Component owns no
  timer of its own. Event-clocked: with no tick the frame never advances
  (fixtures/replay carry no `:activity` and so never animate).
  """

  alias Raxol.Harness.StatusStrip, as: Core
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @type status :: map()

  @type t :: %{
          id: String.t() | atom(),
          status: status(),
          width: pos_integer(),
          spinner_frame: non_neg_integer(),
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
          "harness-status-strip-#{:erlang.unique_integer([:positive])}"
        ),
      status: Map.get(props, :status, %{}),
      width: Map.get(props, :width, Raxol.Core.Defaults.terminal_width()),
      spinner_frame: Map.get(props, :spinner_frame, 0),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # A read-only instrument has no events of its own.
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
        kind: :status,
        component_module: __MODULE__
      },
      style: state.style,
      gap: 0,
      children: lines(state.status, width, state.spinner_frame)
    }
  end

  @doc """
  The strip's footer line elements for the given `status` and display
  `width`, with the braille spinner resolved from `spinner_frame` -- or `[]`
  when the strip yields to silence (`visible?/1` is false). Each element is
  one physical row (a `Raxol.View.Components.text/1` node), the line-list
  shape `Raxol.UI.Components.Harness.FooterStack` measures and fits.
  """
  @spec lines(status(), integer(), non_neg_integer()) :: [map()]
  def lines(status, width, spinner_frame \\ 0)

  def lines(status, width, spinner_frame)
      when is_map(status) and is_integer(width) do
    if visible?(status) do
      status
      |> with_spinner_frame(spinner_frame)
      |> Core.render(width)
      |> Enum.map(&text_line/1)
    else
      []
    end
  end

  @doc """
  Whether the strip renders at all for `status` -- the grown-instrument
  gate. Ported from the retired `Raxol.Harness.Surface.strip_visible?/1`:
  an alerting
  stall, an approval wait, a live turn, or an animating activity. Public so
  a host can decide whether to allocate the strip's footer group.
  """
  @spec visible?(status()) :: boolean()
  def visible?(status) when is_map(status) do
    Core.alerting?(status) or
      Map.get(status, :needs_input) == true or
      live_turn?(status) or
      Core.animating?(status)
  end

  @doc """
  Whether the strip should animate its spinner this frame (delegates to
  `Raxol.Harness.StatusStrip.animating?/1`). Public so the host's
  `subscribe/1` can gate a tick interval on it.
  """
  @spec animating?(status()) :: boolean()
  def animating?(status) when is_map(status), do: Core.animating?(status)

  @doc """
  Whether the strip is rendering a highest-priority `ALERT:` stall notice
  (delegates to `Raxol.Harness.StatusStrip.alerting?/1`).
  """
  @spec alerting?(status()) :: boolean()
  def alerting?(status) when is_map(status), do: Core.alerting?(status)

  # -- private -------------------------------------------------------------

  # A live turn: loop events have been observed and the most recent bracket
  # has neither completed, canceled, nor faulted the turn. Verbatim port of
  # `Surface.live_turn?/1`.
  defp live_turn?(status) do
    case Map.get(status, :turn_stage) do
      nil -> false
      :turn_canceled -> false
      :error -> false
      _stage -> Map.get(status, :turn_completed) != true
    end
  end

  # Inject the current braille spinner frame when the turn animates, from
  # the shared glyph source advanced by the caller's tick counter. Mirrors
  # `Surface.maybe_put_spinner/2` + `current_spinner_frame/1`.
  defp with_spinner_frame(status, spinner_frame) do
    if Core.animating?(status) do
      Map.put(status, :spinner, current_frame(spinner_frame))
    else
      status
    end
  end

  defp current_frame(spinner_frame) do
    glyphs = Core.spinner_glyphs()
    Enum.at(glyphs, rem(max(spinner_frame, 0), length(glyphs)))
  end

  # The pure core already width-truncated the line; wrap it as one physical
  # row for the footer line-list.
  defp text_line(content), do: Components.text(content: content)
end
