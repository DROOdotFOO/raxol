defmodule Raxol.Harness.HarnessAppFoldTest do
  @moduledoc """
  U4 update/2: each frozen `Raxol.Harness.PumpContract` message folds into
  the model correctly (spec §2 mapping table) — the per-message falsifiers.
  Belief fields, loud-loss, the submit busy-gate, and the directive-vs-stub
  split are all pinned here.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.Directive.Lane
  alias Raxol.Harness.HarnessApp
  alias Raxol.Harness.HarnessApp.Model
  alias Raxol.UI.Components.Harness.Composer

  defp model(opts \\ []),
    do: Model.build(Keyword.merge([width: 80, rows: 24], opts))

  defp markers(m),
    do:
      m.transcript_records
      |> Enum.reverse()
      |> Enum.filter(&match?({:marker, _}, &1))

  test "{:tick, now} ages the clock and bumps the spinner; no directives" do
    {m, cmds} = HarnessApp.update({:tick, 500}, model())
    assert cmds == []
    assert m.status.now == 500
    assert m.spinner_frame == 1
  end

  test "{:lane_notice, text} sets, nil clears the persistent notice" do
    {m, []} = HarnessApp.update({:lane_notice, "reconnecting"}, model())
    assert m.lane_notice == "reconnecting"
    {m, []} = HarnessApp.update({:lane_notice, nil}, m)
    assert m.lane_notice == nil
  end

  test "{:debug_highlight, group} honors the vocabulary; an unknown group clears (fail-safe)" do
    {m, []} = HarnessApp.update({:debug_highlight, :composer}, model())
    assert m.debug_highlight == :composer
    {m, []} = HarnessApp.update({:debug_highlight, :bogus}, m)
    assert m.debug_highlight == nil
  end

  test "{:stall_verdict, v} shows a real verdict; the :ok class and needs_input suppress it" do
    verdict = %{class: :looping, evidence: "x"}
    {m, []} = HarnessApp.update({:stall_verdict, verdict}, model())
    assert m.status.stall_verdict == verdict

    {m, []} = HarnessApp.update({:stall_verdict, %{class: :ok}}, m)
    refute Map.has_key?(m.status, :stall_verdict)

    # operator-paced (needs_input) is not stalled: a verdict is suppressed
    busy = %{model() | status: %{needs_input: true}}
    {m, []} = HarnessApp.update({:stall_verdict, verdict}, busy)
    refute Map.has_key?(m.status, :stall_verdict)
  end

  test "{:seal_lines, lines} seals each; a non-binary seals as inspect/1 (never dropped)" do
    {m, []} = HarnessApp.update({:seal_lines, ["boot ok", 42]}, model())
    assert markers(m) == [{:marker, "boot ok"}, {:marker, "42"}]
  end

  test "{:batch, items} seals a LOUD marker for loss / malformed / unknown (loud-loss law)" do
    items = [{:cadence_dropped, 3}, {:malformed_event}, {:surprise, :element}]
    {m, []} = HarnessApp.update({:batch, items}, model())
    texts = markers(m) |> Enum.map(fn {:marker, t} -> t end)
    assert length(texts) == 3
    assert Enum.any?(texts, &(&1 =~ "3 event(s) dropped"))
    assert Enum.any?(texts, &(&1 =~ "malformed"))
    assert Enum.any?(texts, &(&1 =~ "unrecognized stream element"))
  end

  test "{:session_down, reason} preserves the transcript, closes the stream, arms session_over?" do
    {m, []} =
      HarnessApp.update({:session_down, :killed}, %{
        model()
        | stream_open?: true
      })

    assert m.session_over? == true
    assert m.stream_open? == false
    assert m.lane_notice =~ "session process exited"
  end

  test "{:feed_down, :subscribe, _} only notices; :cadence closes the stream" do
    {sub, []} =
      HarnessApp.update({:feed_down, :subscribe, :nxdomain}, %{
        model()
        | stream_open?: true
      })

    assert sub.stream_open? == true
    assert sub.lane_notice =~ "could not attach"

    {cad, []} =
      HarnessApp.update({:feed_down, :cadence, :crash}, %{
        model()
        | stream_open?: true
      })

    assert cad.stream_open? == false
    assert cad.lane_notice =~ "no further events"
  end

  test "{:isig_reasserted} names the -isig re-assert honestly" do
    {m, []} = HarnessApp.update({:isig_reasserted}, model())
    assert m.lane_notice =~ "-isig"
  end

  test "{:submit_result, {:error, _}} restores the draft and names the failure" do
    m = %{model() | pending_submit: %{text: "draft"}}
    {m, []} = HarnessApp.update({:submit_result, {:error, :busy}}, m)
    assert m.pending_submit == nil
    assert Composer.value(m.composer) == "draft"
    assert m.lane_notice =~ "submit refused"
  end

  test "{:steer_result, _} always clears steer_in_flight? and names the outcome (CAS never silent)" do
    m = %{model() | steer_in_flight?: true}

    {accepted, []} =
      HarnessApp.update({:steer_result, {:ok, {:accepted, %{}}}}, m)

    assert accepted.steer_in_flight? == false
    assert accepted.lane_notice =~ "accepted"

    {timeout, []} =
      HarnessApp.update({:steer_result, {:error, {:timeout, 5000}}}, %{
        model()
        | steer_in_flight?: true
      })

    assert timeout.steer_in_flight? == false
    assert timeout.lane_notice =~ "timed out"
  end

  test "{:editor_result, {:ok, ...}} loads the edited draft; a degraded list warns" do
    outcome =
      {:ok, %{text: "edited draft", width: 80, rows: 24, degraded: [:reader]}}

    {m, []} = HarnessApp.update({:editor_result, outcome}, model())
    assert Composer.value(m.composer) == "edited draft"
    assert m.lane_notice =~ "keyboard may be dead"
  end

  test "resize %Event{} adopts geometry and re-widths the composer" do
    {m, []} =
      HarnessApp.update(
        %Event{type: :resize, data: %{width: 120, height: 40}},
        model()
      )

    assert m.width == 120 and m.rows == 40
  end

  test "a printable key types into the composer while composing; no directive" do
    {m, cmds} = HarnessApp.update(Event.key_event("x", :pressed, []), model())
    assert cmds == []
    assert Composer.value(m.composer) =~ "x"
  end

  test "the contract's {:key, normalized} shape types the same (live pump path)" do
    # The SessionPump normalizes at its boundary (PumpContract §4), so
    # update/2 receives {:key, normalized_map} -- never the raw Event.
    # Before the idempotence/component-event fix, this shape silently
    # dropped text (the Composer pattern-matches %Event{}, and the
    # normalized map hit its fallback): the U6 live wiring's first
    # end-to-end bug.
    norm = Raxol.UI.Harness.InputEvent.normalize(Event.key("z"))
    {m, cmds} = HarnessApp.update({:key, norm}, model())
    assert cmds == []
    assert Composer.value(m.composer) =~ "z"
  end

  test "the contract's normalized ctrl chord still arms the quit protocol" do
    # The double-normalization that used to un-press Ctrl would have
    # broken every live chord; the arm proves ctrl survived the fold.
    norm =
      Raxol.UI.Harness.InputEvent.normalize(%Event{
        type: :key,
        data: %{key: "c", state: :pressed, modifiers: [:ctrl]}
      })

    {m, []} = HarnessApp.update({:key, norm}, model())
    assert m.quit_armed? == true
  end

  test "q on an empty composer requests a halt directive (only when a pump is wired)" do
    {_m, cmds} =
      HarnessApp.update(Event.key_event("q", :pressed, []), model(pump: self()))

    assert [%Lane{action: :halt}] = cmds
  end

  test "the submit busy-gate: Enter is refused while a turn is running (belief-side, §6)" do
    composer = Composer.set_value(model().composer, "hello")

    idle = %{model(pump: self()) | composer: composer}
    {m, cmds} = HarnessApp.update(Event.key_event(:enter, :pressed, []), idle)
    assert [%Lane{action: :submit, payload: %{text: "hello"}}] = cmds
    assert m.pending_submit == %{text: "hello"}

    busy = %{model(pump: self()) | composer: composer, current_turn_id: "t1"}
    {m, cmds} = HarnessApp.update(Event.key_event(:enter, :pressed, []), busy)
    assert cmds == []
    assert m.lane_notice =~ "already running"
  end

  test "fixture mode (pump: nil) folds an honest stub notice instead of a lane directive" do
    composer = Composer.set_value(model().composer, "hello")

    {m, cmds} =
      HarnessApp.update(Event.key_event(:enter, :pressed, []), %{
        model()
        | composer: composer
      })

    assert cmds == []
    assert m.stub_notice =~ "(stub)"
  end

  test "an unknown message is ignored, never crashing the fold" do
    assert {_m, []} = HarnessApp.update({:wat, :ever}, model())
  end
end
