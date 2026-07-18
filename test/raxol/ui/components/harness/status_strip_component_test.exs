defmodule Raxol.UI.Components.Harness.StatusStripComponentTest do
  @moduledoc """
  The StatusStrip Component wrapper (harness TEA migration §4, unit U2): the
  view-path seam over the pure `Raxol.Harness.StatusStrip` core -- the
  visibility gate, the tick-driven spinner injection, and the id/attrs
  stamp. The phase/elapsed/ctx/cost/alert logic itself is the pure core's,
  pinned by its own suite; this file pins only the wrapper.
  """
  use ExUnit.Case, async: true

  alias Raxol.Harness.StatusStrip, as: Core
  alias Raxol.UI.Components.Harness.StatusStrip

  defp content(lines), do: Enum.map(lines, & &1.content)

  describe "lines/3 -- the strip's footer rows" do
    test "a live turn renders the phase" do
      status = %{turn_stage: :turn_started, last_event_at: 0, now: 3000}
      assert [%{type: :text}] = StatusStrip.lines(status, 44)
      # turn_started is the pre-stream WAIT: bare spinner + elapsed, no word.
      assert ["3s"] = content(StatusStrip.lines(status, 44))
    end

    test "running <tool> and awaiting approval render their phases" do
      # running_tool rides a live turn (turn_stage set); with no :activity
      # it is visible but not animating, so no spinner is prepended.
      running = %{running_tool: "mix", turn_stage: :item_completed}
      assert content(StatusStrip.lines(running, 44)) == ["running mix"]

      assert content(StatusStrip.lines(%{needs_input: true}, 44)) == [
               "awaiting approval"
             ]
    end

    test "an alerting stall verdict renders the highest-priority ALERT" do
      status = %{
        stall_verdict: %{
          class: :stalled,
          evidence: %{summary: "no progress 90s"}
        }
      }

      assert ["ALERT: no progress 90s"] = content(StatusStrip.lines(status, 44))
    end
  end

  describe "lines/3 -- charged-minimum absence (yields to silence)" do
    test "an idle status renders NOTHING (no labelled void)" do
      assert StatusStrip.lines(%{}, 44) == []

      assert StatusStrip.lines(
               %{turn_stage: :turn_completed, turn_completed: true},
               44
             ) == []
    end
  end

  describe "lines/3 -- the tick-driven braille spinner" do
    setup do
      %{
        glyphs: Core.spinner_glyphs(),
        status: %{
          turn_stage: :turn_started,
          activity: :generating,
          last_event_at: 0,
          now: 1000
        }
      }
    end

    test "an animating turn prepends the resolved frame glyph", %{
      glyphs: glyphs,
      status: status
    } do
      [f0, f1 | _] = glyphs
      assert [line0] = content(StatusStrip.lines(status, 44, 0))
      assert String.starts_with?(line0, f0)

      # The next scripted tick advances the frame -- one shared clock.
      assert [line1] = content(StatusStrip.lines(status, 44, 1))
      assert String.starts_with?(line1, f1)
    end

    test "the frame counter wraps around the glyph set", %{
      glyphs: glyphs,
      status: status
    } do
      [f0 | _] = glyphs
      n = length(glyphs)
      assert [line] = content(StatusStrip.lines(status, 44, n))
      assert String.starts_with?(line, f0)
    end

    test "a non-animating status never carries a spinner", %{glyphs: glyphs} do
      # approval is visible but operator-paced -- no pulse.
      [content] = content(StatusStrip.lines(%{needs_input: true}, 44, 3))
      refute Enum.any?(glyphs, &String.starts_with?(content, &1))
    end
  end

  describe "visible?/1 -- the grown-instrument gate" do
    test "true for a live turn / approval / alert / animating" do
      assert StatusStrip.visible?(%{turn_stage: :item_delta})
      assert StatusStrip.visible?(%{needs_input: true})

      assert StatusStrip.visible?(%{
               stall_verdict: %{class: :looping, evidence: %{summary: "loop"}}
             })

      assert StatusStrip.visible?(%{
               activity: :generating,
               turn_stage: :turn_started
             })
    end

    test "false when there is nothing true to say" do
      refute StatusStrip.visible?(%{})
      # a completed/canceled/faulted turn is not live
      refute StatusStrip.visible?(%{
               turn_stage: :turn_completed,
               turn_completed: true
             })

      refute StatusStrip.visible?(%{turn_stage: :turn_canceled})
      refute StatusStrip.visible?(%{turn_stage: :error})
    end
  end

  describe "animating?/1 and alerting?/1 delegate to the pure core" do
    test "animating only for an active work activity" do
      assert StatusStrip.animating?(%{
               activity: :generating,
               turn_stage: :turn_started
             })

      refute StatusStrip.animating?(%{needs_input: true})
      refute StatusStrip.animating?(%{})
    end

    test "alerting only for a stall verdict with evidence" do
      assert StatusStrip.alerting?(%{
               stall_verdict: %{class: :stalled, evidence: %{summary: "x"}}
             })

      refute StatusStrip.alerting?(%{})
    end
  end

  describe "render/2 (controlled stamp)" do
    test "stamps a column with id + attrs and the strip line as children" do
      {:ok, state} =
        StatusStrip.init(
          id: "strip",
          status: %{needs_input: true},
          width: 44
        )

      view = StatusStrip.render(state, %{})
      assert view.type == :column
      assert view.id == "strip"
      assert view.attrs.component_module == StatusStrip
      assert view.attrs.kind == :status
      assert content(view.children) == ["awaiting approval"]
    end

    test "an idle strip renders an empty column (no rows)" do
      {:ok, state} = StatusStrip.init(id: "strip", status: %{}, width: 44)
      assert %{children: []} = StatusStrip.render(state, %{})
    end
  end

  describe "handle_event/3 (a read-only instrument)" do
    test "returns state unchanged with no commands" do
      {:ok, state} = StatusStrip.init([])
      assert {^state, []} = StatusStrip.handle_event(:anything, state, %{})
    end
  end
end
