defmodule Raxol.Playground.Demos.HarnessStatusStripDemo do
  @moduledoc """
  Playground demo: the pinned status strip re-hosted as a controlled
  `StatusStrip` Component (harness TEA migration §4 footer row, unit U2).
  Scripted status scenes plus a tick clock exercise the strip's phase
  vocabulary, the tick-driven braille spinner, the alert state, and the
  charged-minimum absence.

  This demo IS the §7 autotest fixture. It pins, headlessly against the
  screenshot:

    * **phase rendering** -- `thinking` / `running <tool>` / `responding`
      (live turns), `awaiting approval` (the safety phase), and the
      highest-priority `ALERT:` stall notice;
    * **the spinner advances on the tick clock** -- a scripted tick (`t`)
      moves the braille frame to the next glyph, and with NO tick the frame
      never moves (event-clocked, never wall time), exactly the U1-d
      tool-spinner guarantee;
    * **charged-minimum absence** -- between turns the strip has nothing
      TRUE to say and renders NOTHING (no `Stage: - | Ctx: -` void).

  Scenes cycle with `n` (and back with `p`). `t` advances the spinner one
  scripted frame; `a` toggles a real 150ms interval (OFF by default so the
  autotests are deterministic -- the interval sends the SAME `:tick`
  message, so scripted and wall-clock share one code path). All state lives
  in the model (§2 controlled doctrine); the `StatusStrip` Component is
  re-`init`+`render`ed from props each frame and holds no clock of its own.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Components.Harness.StatusStrip

  @width 44
  @tick_interval_ms 150

  # Ordered scenes: the first three are live turns that ANIMATE the spinner;
  # the approval + alert scenes are visible but do NOT animate (operator-
  # paced / alarm); the idle scene yields to silence.
  @scenes [:thinking, :running, :responding, :approval, :alert, :idle]

  @impl true
  def init(_context) do
    %{scene_index: 0, spinner_frame: 0, animate: false}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("n") ->
        {%{model | scene_index: Integer.mod(model.scene_index + 1, count())},
         []}

      key_match("p") ->
        {%{model | scene_index: Integer.mod(model.scene_index - 1, count())},
         []}

      key_match("t") ->
        {%{model | spinner_frame: model.spinner_frame + 1}, []}

      key_match("a") ->
        {%{model | animate: not model.animate}, []}

      :tick ->
        {%{model | spinner_frame: model.spinner_frame + 1}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    scene = current_scene(model)

    {:ok, strip} =
      StatusStrip.init(
        id: "status_strip",
        status: status_for(scene),
        spinner_frame: model.spinner_frame,
        width: @width
      )

    column style: %{gap: 0} do
      [
        text("Harness StatusStrip Demo", id: "ss_title", style: [:bold]),
        text(scene_line(model, scene), id: "ss_scene", style: [:dim]),
        divider(),
        StatusStrip.render(strip, %{available_width: @width}),
        divider(),
        text(hint(), id: "ss_hint", style: [:dim])
      ]
    end
  end

  # Only subscribe a real tick when the operator opted in AND the current
  # scene actually animates -- otherwise the strip has no spinner to move,
  # and the default (animate: false) keeps the autotests event-clocked.
  @impl true
  def subscribe(%{animate: true} = model) do
    if StatusStrip.animating?(status_for(current_scene(model))) do
      [subscribe_interval(@tick_interval_ms, :tick)]
    else
      []
    end
  end

  def subscribe(_model), do: []

  # -- scene labels (deliberately collision-free with the strip's phase
  # text so a test can grep the phase without matching this line) ----------

  defp current_scene(model), do: Enum.at(@scenes, model.scene_index)

  defp count, do: length(@scenes)

  defp scene_line(model, scene) do
    "scene #{model.scene_index + 1}/#{count()}: #{scene_label(scene)}"
  end

  defp scene_label(:thinking), do: "live turn"
  defp scene_label(:running), do: "tool run"
  defp scene_label(:responding), do: "streaming"
  defp scene_label(:approval), do: "human gate"
  defp scene_label(:alert), do: "stall alarm"
  defp scene_label(:idle), do: "quiet"

  defp hint do
    "[n]/[p] scene · [t] tick spinner · [a] toggle live animation"
  end

  # -- scripted status maps ------------------------------------------------
  #
  # `now`/`last_event_at` are plain injected integers (never a wall clock),
  # so the elapsed suffix is deterministic and stays under the 15s SLOW
  # threshold. The `activity` flag drives the spinner pulse.

  defp status_for(:thinking) do
    # `:item_started` is the phase that carries the "thinking" word; the
    # pre-stream `:turn_started` wait is now a bare spinner (V, 2026-07-18).
    %{
      turn_stage: :item_started,
      activity: :generating,
      last_event_at: 0,
      now: 3000
    }
  end

  defp status_for(:running) do
    %{running_tool: "mix", activity: :running_tool, last_event_at: 0, now: 2000}
  end

  defp status_for(:responding) do
    %{
      turn_stage: :item_delta,
      activity: :responding,
      last_event_at: 0,
      now: 1000
    }
  end

  # The safety phase: an agent waiting on a human. Visible, never animated
  # (operator-paced -- the HUNG-suppression ruling).
  defp status_for(:approval), do: %{needs_input: true}

  # The one alarm the strip exists to make unmissable: a stall verdict with
  # evidence renders the highest-priority `ALERT:` segment.
  defp status_for(:alert) do
    %{
      stall_verdict: %{
        class: :stalled,
        evidence: %{summary: "no progress for 90s"}
      }
    }
  end

  # Between turns: nothing TRUE to say -> the strip yields to silence.
  defp status_for(:idle), do: %{}
end
