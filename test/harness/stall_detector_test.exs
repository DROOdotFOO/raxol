defmodule Raxol.Harness.StallDetectorTest do
  @moduledoc """
  The stall / doom-loop detector: a pure supervision instrument that
  turns a stream of observations (tool calls, output activity, clock
  ticks) into an explained verdict, so the human supervising an agent
  learns "this agent has wedged" instead of watching a lying spinner.

  Each `describe` block below encodes one of the detector's design laws
  as an executable contract:

    1. PURE DETECTION POLICY -- observations in, verdict out, caller
       owns time, every non-ok verdict carries its evidence.
    2. INDEPENDENT BUDGET -- escalation accounting is the detector's
       own counter, consumed only by fresh alarms.
    3. NEVER AUTO-RECOVER -- the module exposes observation/verdict
       functions only; there is no corrective surface at all.
    4. HARD GRACEFUL TERMINAL -- a spent budget yields a deterministic
       "reported, standing by" state, never an endless re-alarm.
    5. HONESTY FLOOR -- a fresh or insufficient observation window is
       `:ok`; no verdict ever fires without evidence.

  RED-FIRST: this entire file was written and run against a codebase
  with no `Raxol.Harness.StallDetector` module (every test failed with
  `UndefinedFunctionError`) before the implementation existed.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.StallDetector
  alias Raxol.Harness.StallDetector.Verdict
  alias Raxol.Harness.StatusStrip

  # -- helpers ---------------------------------------------------------

  @args %{"path" => "mix.exs"}

  defp call(name, args \\ @args, at \\ 0), do: {:tool_call, name, args, at}

  # Folds a list of observations, returning the FINAL {verdict, detector}.
  defp drive(det, observations) do
    Enum.reduce(observations, {nil, det}, fn obs, {_verdict, d} ->
      StallDetector.observe(d, obs)
    end)
  end

  defp repeat_call(name, n), do: List.duplicate(call(name), n)

  # -- law 1: pure detection policy -------------------------------------

  describe "law 1: pure detection policy" do
    test "observe/2 is a pure fold: identical inputs, identical outputs" do
      observations = repeat_call("read_file", 4) ++ [{:progress, 1_000}]

      first = drive(StallDetector.new(), observations)
      second = drive(StallDetector.new(), observations)

      assert first == second
    end

    test "check/2 is pure too: same detector + same now, same verdict" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 0}])

      assert StallDetector.check(det, 90_000) ==
               StallDetector.check(det, 90_000)
    end

    test "verdicts are structs carrying class, evidence, and standing_by only" do
      keys =
        %Verdict{} |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert keys == [:class, :evidence, :standing_by]
    end

    test "every non-ok verdict carries evidence with a reason and a summary" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 4))

      assert %Verdict{class: :looping, evidence: evidence} = verdict
      assert is_atom(evidence.reason)
      assert is_binary(evidence.summary)
      assert evidence.summary != ""
    end
  end

  # -- law 5: honesty floor ----------------------------------------------

  describe "law 5: honesty floor (fresh window is :ok, never suspect-by-default)" do
    test "a fresh detector checked against any clock is :ok with no evidence" do
      det = StallDetector.new()

      assert {%Verdict{class: :ok, evidence: nil}, _det} =
               StallDetector.check(det, 999_999_999)
    end

    test "a couple of identical calls is normal work, not a verdict" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 2))

      assert %Verdict{class: :ok, evidence: nil} = verdict
    end

    test ":ok verdicts never carry evidence" do
      {verdict, _det} = drive(StallDetector.new(), [call("read_file")])

      assert %Verdict{class: :ok, evidence: nil, standing_by: false} = verdict
    end
  end

  # -- signal: repetition --------------------------------------------------

  describe "repetition: same tool, identical arguments" do
    test "four identical calls is a loop verdict naming tool, count, and args" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 4))

      assert %Verdict{class: :looping, evidence: evidence} = verdict
      assert evidence.reason == :repetition
      assert evidence.tool == "read_file"
      assert evidence.count == 4
      assert evidence.summary == "possible loop: read_file x4 same args"
    end

    test "three identical calls (threshold minus one) is :suspect with evidence" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 3))

      assert %Verdict{class: :suspect, evidence: evidence} = verdict
      assert evidence.reason == :repetition
      assert evidence.count == 3
    end

    test "four calls to the same tool with DIFFERENT args is :ok" do
      observations =
        for i <- 1..4, do: call("read_file", %{"path" => "file#{i}.ex"})

      {verdict, _det} = drive(StallDetector.new(), observations)

      assert %Verdict{class: :ok} = verdict
    end

    test "interleaved progress events do not reset the call window" do
      observations =
        Enum.intersperse(repeat_call("read_file", 4), {:progress, 100})

      {verdict, _det} = drive(StallDetector.new(), observations)

      assert %Verdict{class: :looping, evidence: %{reason: :repetition}} =
               verdict
    end

    test "a different call clears an active loop verdict back to :ok" do
      {_verdict, det} = drive(StallDetector.new(), repeat_call("read_file", 4))

      {verdict, _det} = StallDetector.observe(det, call("list_dir", %{}))

      assert %Verdict{class: :ok, evidence: nil} = verdict
    end

    test "the loop verdict keeps counting past the threshold" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 6))

      assert %Verdict{class: :looping, evidence: %{count: 6}} = verdict
    end
  end

  # -- signal: ping-pong (cycle length 2) -----------------------------------

  describe "ping-pong: two tools alternating" do
    test "three full A,B cycles is a loop verdict naming both tools" do
      a = call("read_file")
      b = call("list_dir", %{})

      {verdict, _det} = drive(StallDetector.new(), [a, b, a, b, a, b])

      assert %Verdict{class: :looping, evidence: evidence} = verdict
      assert evidence.reason == :ping_pong
      assert evidence.cycles == 3
      assert evidence.summary == "possible loop: read_file<->list_dir x3"
    end

    test "two full cycles (threshold minus one) is :suspect" do
      a = call("read_file")
      b = call("list_dir", %{})

      {verdict, _det} = drive(StallDetector.new(), [a, b, a, b])

      assert %Verdict{class: :suspect, evidence: %{reason: :ping_pong}} =
               verdict
    end

    test "the same tool with two alternating argument sets is still ping-pong" do
      a = call("read_file", %{"path" => "a.ex"})
      b = call("read_file", %{"path" => "b.ex"})

      {verdict, _det} = drive(StallDetector.new(), [a, b, a, b, a, b])

      assert %Verdict{class: :looping, evidence: %{reason: :ping_pong}} =
               verdict
    end

    test "a broken alternation is :ok" do
      a = call("read_file")
      b = call("list_dir", %{})
      c = call("grep", %{"q" => "x"})

      {verdict, _det} = drive(StallDetector.new(), [a, b, a, b, a, c])

      assert %Verdict{class: :ok} = verdict
    end

    test "pure repetition is never misread as ping-pong" do
      {verdict, _det} = drive(StallDetector.new(), repeat_call("read_file", 3))

      assert %Verdict{evidence: %{reason: :repetition}} = verdict
    end
  end

  # -- signal: no-progress elapse -------------------------------------------

  describe "no-progress elapse (the status strip's hung heuristic, formalized)" do
    test "defaults are the status strip's own thresholds, not a parallel set" do
      det = StallDetector.new()

      assert det.warn_after_ms == StatusStrip.default_warn_after_ms()
      assert det.hung_after_ms == StatusStrip.default_hung_after_ms()
    end

    test "under the warn threshold is :ok" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 0}])

      assert {%Verdict{class: :ok}, _det} =
               StallDetector.check(det, 14_999)
    end

    test "past the warn threshold is :suspect with elapsed evidence" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 0}])

      {verdict, _det} = StallDetector.check(det, 15_000)

      assert %Verdict{class: :suspect, evidence: evidence} = verdict
      assert evidence.reason == :no_progress
      assert evidence.elapsed_ms == 15_000
    end

    test "past the hung threshold is :stalled with a human-readable summary" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 0}])

      {verdict, _det} = StallDetector.check(det, 75_000)

      assert %Verdict{class: :stalled, evidence: evidence} = verdict
      assert evidence.reason == :no_progress
      assert evidence.elapsed_ms == 75_000
      assert evidence.summary == "no output for 1m15s"
    end

    test "any observation resets the elapse window" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 0}])
      {_verdict, det} = StallDetector.observe(det, {:progress, 59_000})

      assert {%Verdict{class: :ok}, _det} =
               StallDetector.check(det, 70_000)
    end

    test "thresholds are overridable at construction" do
      det = StallDetector.new(warn_after_ms: 1_000, hung_after_ms: 4_000)
      {_verdict, det} = StallDetector.observe(det, {:progress, 0})

      assert {%Verdict{class: :stalled}, _det} = StallDetector.check(det, 5_000)
    end

    test "a clock running backwards clamps to zero elapsed, never crashes" do
      {_verdict, det} = drive(StallDetector.new(), [{:progress, 100_000}])

      assert {%Verdict{class: :ok}, _det} = StallDetector.check(det, 50_000)
    end

    test "an active loop verdict is not cleared by a mere clock tick" do
      {_verdict, det} = drive(StallDetector.new(), repeat_call("read_file", 4))

      {verdict, _det} = StallDetector.check(det, 1_000)

      assert %Verdict{class: :looping} = verdict
    end
  end

  # -- law 3: never auto-recover ---------------------------------------------

  describe "law 3: the detector only surfaces verdicts, never acts" do
    test "the module's whole public surface is construction + observation" do
      exports =
        StallDetector.__info__(:functions)
        |> Keyword.keys()
        |> Enum.reject(&(&1 == :__struct__))
        |> Enum.sort()
        |> Enum.uniq()

      assert exports == [:check, :new, :observation_from_event, :observe]
    end
  end

  # -- law 2 + law 4: independent budget, hard graceful terminal --------------

  describe "law 2: the escalation budget is the detector's own counter" do
    test "ordinary observations never touch the budget" do
      det = StallDetector.new()
      {_verdict, driven} = drive(det, [call("a", %{}), call("b", %{})])

      assert driven.escalations_left == det.escalations_left
    end

    test "only a fresh alarm spends budget; a persisting one does not" do
      {_verdict, det} = drive(StallDetector.new(), repeat_call("read_file", 4))
      spent_once = det.escalations_left

      # The loop persists: same signature, no additional spend.
      {verdict, det} = StallDetector.observe(det, call("read_file"))

      assert det.escalations_left == spent_once
      assert %Verdict{class: :looping, standing_by: true} = verdict
    end

    test "suspect pre-alarms are free: only :stalled/:looping spend budget" do
      det = StallDetector.new()
      {verdict, driven} = drive(det, repeat_call("read_file", 3))

      assert %Verdict{class: :suspect} = verdict
      assert driven.escalations_left == det.escalations_left
    end
  end

  describe "law 4: hard graceful terminal once the budget is spent" do
    test "a spent budget yields standing_by verdicts with honest evidence" do
      det = StallDetector.new(escalation_budget: 1)

      # Alarm one: fresh escalation, spends the whole budget.
      {verdict, det} = drive(det, repeat_call("read_file", 4))
      assert %Verdict{class: :looping, standing_by: false} = verdict
      assert det.escalations_left == 0

      # Recover, then wedge on a different tool.
      {%Verdict{class: :ok}, det} =
        StallDetector.observe(det, call("compile", %{}))

      {verdict, _det} = drive(det, repeat_call("run_tests", 4))

      # Terminal state: the verdict still tells the truth about WHAT is
      # wrong (class + current evidence), but is flagged standing_by --
      # it is never presented as a fresh escalation again.
      assert %Verdict{class: :looping, standing_by: true, evidence: evidence} =
               verdict

      assert evidence.tool == "run_tests"
    end

    test "the terminal state is stable across further observations" do
      det = StallDetector.new(escalation_budget: 0)

      {verdict, det} = drive(det, repeat_call("read_file", 4))
      assert %Verdict{standing_by: true} = verdict

      {verdict, _det} = StallDetector.observe(det, call("read_file"))
      assert %Verdict{class: :looping, standing_by: true} = verdict
    end

    test "recovery to :ok is always available regardless of budget" do
      det = StallDetector.new(escalation_budget: 0)
      {_verdict, det} = drive(det, repeat_call("read_file", 4))

      {verdict, _det} = StallDetector.observe(det, call("list_dir", %{}))

      assert %Verdict{class: :ok, evidence: nil, standing_by: false} = verdict
    end
  end

  # -- fixture-event mapping ---------------------------------------------------

  describe "observation_from_event/1: harness fixture events -> observations" do
    test "a completed tool_use item maps to a tool_call with ms timestamps" do
      event = %{
        id: 5,
        turn_id: "t1",
        ts: 1_752_581_100_400_000,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{
          "item_id" => "i2",
          "item_type" => "tool_use",
          "name" => "list_dir",
          "arguments" => %{"path" => "."},
          "call_id" => "call-1"
        }
      }

      assert StallDetector.observation_from_event(event) ==
               {:tool_call, "list_dir", %{"path" => "."}, 1_752_581_100_400}
    end

    test "any other loop-family event maps to progress activity" do
      event = %{
        id: 7,
        turn_id: "t1",
        ts: 1_752_581_100_600_000,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{"item_type" => "tool_result", "content" => "ok"}
      }

      assert StallDetector.observation_from_event(event) ==
               {:progress, 1_752_581_100_600}
    end

    test "meta-family events are not observations" do
      event = %{
        id: 1,
        ts: 1_752_581_100_000_000,
        family: :meta,
        type: :config_changed,
        tier: :durable,
        payload: %{}
      }

      assert StallDetector.observation_from_event(event) == nil
    end

    test "an event without a usable timestamp is not an observation" do
      event = %{family: :loop, type: :item_delta, ts: nil, payload: %{}}

      assert StallDetector.observation_from_event(event) == nil
    end
  end
end
