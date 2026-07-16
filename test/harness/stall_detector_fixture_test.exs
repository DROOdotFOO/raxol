defmodule Raxol.Harness.StallDetectorFixtureTest do
  @moduledoc """
  End-to-end: a recorded looping session, replayed through the real
  fixture loader, drives the stall detector, whose verdict surfaces on
  the status strip -- the full observation -> verdict -> notice path a
  live harness would take.

  The fixture is constructed inline (written to a per-test tmp dir and
  loaded through `Raxol.Harness.Fixture.load/1`) rather than checked in
  next to the golden sessions: it exists to exercise the detector seam,
  not to freeze a projection snapshot, so it carries no `.blocks.json` /
  `.t7blocks.json` companions and stays out of the golden name lists.

  RED-FIRST: this file was written and run before the detector module
  or the strip wiring existed; it failed with `UndefinedFunctionError`
  on `StallDetector.new/0`.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session
  alias Raxol.Harness.StallDetector
  alias Raxol.Harness.StallDetector.Verdict
  alias Raxol.Harness.StatusStrip

  @moduletag :tmp_dir

  # One turn in which the agent reads the same file four times in a row
  # (tool_use with byte-identical arguments), each call answered by a
  # tool_result -- the classic wedged re-read loop. The session ends
  # mid-loop on the fourth call: no turn_completed, because the agent
  # never gets there. Schema follows the checked-in golden sessions
  # (harness-fixture/1, envelope v1, dense monotonic ids, ts in
  # microseconds).
  @header ~s({"record":"header","schema":"harness-fixture/1","envelope_v":1,) <>
            ~s("harness_version":"0.1.0","backend":"anthropic",) <>
            ~s("model":"claude-sonnet-5","config_hash":"cfg-looping-01",) <>
            ~s("recorded_at":"2026-07-17T12:00:00Z","name":"looping-tool",) <>
            ~s("kind":"golden","notes":"agent wedged re-reading mix.exs; ) <>
            ~s(exercises the stall detector end-to-end"})

  defp envelope(id, ts_us, type, payload) do
    body = %{
      id: id,
      turn_id: "t1",
      ts: ts_us,
      family: "loop",
      type: type,
      tier: "durable",
      payload: payload
    }

    Jason.encode!(%{
      record: "envelope",
      v: 1,
      session_id: "sess-looping-tool",
      kind: "event",
      body: body
    })
  end

  defp looping_fixture do
    base_ts = 1_752_581_100_000_000

    tool_use = fn item ->
      %{
        "item_id" => item,
        "item_type" => "tool_use",
        "name" => "read_file",
        "arguments" => %{"path" => "mix.exs"},
        "call_id" => "call-#{item}"
      }
    end

    events =
      [
        {"turn_started", %{"prompt" => "fix the failing test"}},
        {"item_started", %{"item_id" => "i1", "item_type" => "tool_use"}},
        {"item_completed", tool_use.("i1")},
        {"item_started", %{"item_id" => "i2", "item_type" => "tool_result"}},
        {"item_completed",
         %{
           "item_id" => "i2",
           "item_type" => "tool_result",
           "name" => "read_file",
           "content" => "defmodule ..."
         }},
        {"item_started", %{"item_id" => "i3", "item_type" => "tool_use"}},
        {"item_completed", tool_use.("i3")},
        {"item_started", %{"item_id" => "i4", "item_type" => "tool_result"}},
        {"item_completed",
         %{
           "item_id" => "i4",
           "item_type" => "tool_result",
           "name" => "read_file",
           "content" => "defmodule ..."
         }},
        {"item_started", %{"item_id" => "i5", "item_type" => "tool_use"}},
        {"item_completed", tool_use.("i5")},
        {"item_started", %{"item_id" => "i6", "item_type" => "tool_result"}},
        {"item_completed",
         %{
           "item_id" => "i6",
           "item_type" => "tool_result",
           "name" => "read_file",
           "content" => "defmodule ..."
         }},
        {"item_started", %{"item_id" => "i7", "item_type" => "tool_use"}},
        {"item_completed", tool_use.("i7")}
      ]
      |> Enum.with_index(1)
      |> Enum.map(fn {{type, payload}, id} ->
        envelope(id, base_ts + id * 100_000, type, payload)
      end)

    Enum.join([@header | events], "\n") <> "\n"
  end

  test "a looping session replays into a strip-visible loop alert", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "looping-tool.jsonl")
    File.write!(path, looping_fixture())

    assert {:ok, %Session{} = session} = Fixture.load(path)

    {verdict, detector} =
      session.envelopes
      |> Enum.map(& &1.body)
      |> Enum.map(&StallDetector.observation_from_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({nil, StallDetector.new()}, fn obs, {_verdict, det} ->
        StallDetector.observe(det, obs)
      end)

    # The fourth identical read is the fresh escalation: explained, and
    # a first report (not a budget-exhausted echo).
    assert %Verdict{class: :looping, standing_by: false, evidence: evidence} =
             verdict

    assert evidence.reason == :repetition
    assert evidence.tool == "read_file"
    assert evidence.count == 4
    assert detector.escalations_left < StallDetector.new().escalations_left

    # And the strip surfaces it as its highest-priority notice.
    [line] =
      StatusStrip.render(
        %{turn_stage: :tool_call, needs_input: false, stall_verdict: verdict},
        200
      )

    assert line =~ "ALERT: possible loop: read_file x4 same args"
    assert line =~ "Stage: tool_call"
  end

  test "a healthy session replays to :ok end to end", %{tmp_dir: tmp_dir} do
    # The honesty floor at the seam level: replaying a normal session
    # through the same path must never surface an alert.
    path = Path.join(tmp_dir, "healthy.jsonl")

    events =
      [
        envelope(1, 1_752_581_100_100_000, "turn_started", %{"prompt" => "hi"}),
        envelope(2, 1_752_581_100_200_000, "item_started", %{
          "item_id" => "i1",
          "item_type" => "message"
        }),
        envelope(3, 1_752_581_100_300_000, "item_completed", %{
          "item_id" => "i1",
          "item_type" => "message",
          "content" => "hello"
        })
      ]

    File.write!(path, Enum.join([@header | events], "\n") <> "\n")

    assert {:ok, session} = Fixture.load(path)

    {verdict, _detector} =
      session.envelopes
      |> Enum.map(& &1.body)
      |> Enum.map(&StallDetector.observation_from_event/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce({nil, StallDetector.new()}, fn obs, {_verdict, det} ->
        StallDetector.observe(det, obs)
      end)

    assert %Verdict{class: :ok, evidence: nil} = verdict

    [line] = StatusStrip.render(%{stall_verdict: verdict}, 200)
    refute line =~ "ALERT"
  end
end
