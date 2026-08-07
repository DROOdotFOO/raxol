defmodule Raxol.Agent.TrajectoryTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.{BenchmarkProfile, Contract, Trajectory}

  defp event(type, payload, turn_id \\ "t1") do
    %Contract.Event{type: type, payload: payload, turn_id: turn_id}
  end

  defp sample_meta(overrides \\ %{}) do
    {:ok, profile} =
      BenchmarkProfile.from_env(%{
        "RAXOL_PROFILE" => "benchmark",
        "RAXOL_MAX_TURNS" => "50"
      })

    Map.merge(
      %{
        prompt: "list the files",
        backend: :mock,
        model: "test-model",
        profile: profile,
        turns: 2,
        usage: %{input_tokens: 100, output_tokens: 50},
        exit_code: 0,
        reason: :completed
      },
      overrides
    )
  end

  test "build/2 restates events in order with totals and outcome" do
    events = [
      event(:turn_started, %{prompt: "list the files"}),
      event(:item_completed, %{item_type: :message, content: "two files"}),
      event(:turn_completed, %{final: true, usage: %{}})
    ]

    trajectory = Trajectory.build(events, sample_meta())

    assert trajectory.schema == "raxol-trajectory/1"
    assert trajectory.metadata.prompt == "list the files"
    assert trajectory.metadata.profile == "benchmark"
    assert trajectory.metadata.max_turns == 50

    assert [%{type: :turn_started} | _] = trajectory.steps
    assert length(trajectory.steps) == 3

    assert trajectory.totals.turns == 2
    assert trajectory.totals.usage.input_tokens == 100
    assert trajectory.outcome == %{exit_code: 0, reason: :completed}
  end

  test "build/2 records non-success outcomes" do
    trajectory =
      Trajectory.build([], sample_meta(%{exit_code: 143, reason: :terminated}))

    assert trajectory.outcome == %{exit_code: 143, reason: :terminated}
    assert trajectory.steps == []
  end

  test "write/2 produces decodable JSON at the path, creating parents" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "trajectory-test-#{System.unique_integer([:positive])}"
      )

    path = Path.join([dir, "nested", "trajectory.json"])
    on_exit(fn -> File.rm_rf(dir) end)

    trajectory =
      Trajectory.build([event(:turn_started, %{prompt: "p"})], sample_meta())

    assert :ok = Trajectory.write(path, trajectory)
    assert {:ok, decoded} = path |> File.read!() |> Jason.decode()
    assert decoded["schema"] == "raxol-trajectory/1"
    assert [%{"type" => "turn_started"}] = decoded["steps"]
    assert decoded["outcome"]["exit_code"] == 0
  end

  test "write/2 reports failure without raising" do
    trajectory = Trajectory.build([], sample_meta())

    assert {:error, _} =
             Trajectory.write("/dev/null/impossible/trajectory.json", trajectory)
  end

  test "non-JSON payload terms are sanitized, not fatal" do
    # A failed run's error event carries a raw reason tuple; the trajectory
    # of exactly that run must still encode (caught live: Req transport
    # errors crashed the export before sanitization).
    events = [
      event(:error, %{
        reason: {:request_failed, %ArgumentError{message: "boom"}}
      })
    ]

    trajectory =
      Trajectory.build(events, sample_meta(%{exit_code: 1, reason: :error}))

    assert {:ok, json} = Jason.encode(trajectory)
    assert json =~ "request_failed"
  end
end
