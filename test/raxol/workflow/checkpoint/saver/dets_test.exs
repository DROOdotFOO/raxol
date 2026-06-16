defmodule Raxol.Workflow.Checkpoint.Saver.DetsTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver.Dets

  setup do
    nonce = :erlang.unique_integer([:positive])
    name = :"dets_test_#{nonce}"
    file = Path.join(System.tmp_dir!(), "raxol_workflow_dets_#{nonce}")

    {:ok, pid} = Dets.start_link(name: name, file: file)

    on_exit(fn ->
      if Process.alive?(pid), do: Dets.stop(name)
      File.rm(file)
    end)

    {:ok, config: %{name: name}}
  end

  defp make_cp(thread_id, step, state \\ %{}) do
    Checkpoint.new(thread_id: thread_id, step: step, state: state)
  end

  describe "round-trip" do
    test "put then get_latest returns the checkpoint", %{config: config} do
      cp = make_cp("thr", 0, %{x: 1})
      assert :ok = Dets.put(config, "thr", cp)
      assert {:ok, ^cp} = Dets.get_latest(config, "thr")
    end

    test "latest is the highest step", %{config: config} do
      Dets.put(config, "thr", make_cp("thr", 0))
      Dets.put(config, "thr", make_cp("thr", 2))
      Dets.put(config, "thr", make_cp("thr", 1))

      assert {:ok, %Checkpoint{step: 2}} = Dets.get_latest(config, "thr")
    end

    test "get_latest returns :not_found for unknown thread", %{config: config} do
      assert {:error, :not_found} = Dets.get_latest(config, "ghost")
    end

    test "append-only: second write to same key is no-op", %{config: config} do
      Dets.put(config, "thr", make_cp("thr", 0, %{v: :first}))
      Dets.put(config, "thr", make_cp("thr", 0, %{v: :second}))

      assert {:ok, %Checkpoint{state: %{v: :first}}} =
               Dets.get_latest(config, "thr")
    end
  end

  describe "list" do
    test "newest-first order, respects limit", %{config: config} do
      for step <- 0..9, do: Dets.put(config, "thr", make_cp("thr", step))

      assert {:ok, listed} = Dets.list(config, "thr", 3)
      assert Enum.map(listed, & &1.step) == [9, 8, 7]
    end

    test "isolates threads", %{config: config} do
      Dets.put(config, "a", make_cp("a", 0, %{w: :a}))
      Dets.put(config, "b", make_cp("b", 0, %{w: :b}))

      assert {:ok, [%{state: %{w: :a}}]} = Dets.list(config, "a", 5)
      assert {:ok, [%{state: %{w: :b}}]} = Dets.list(config, "b", 5)
    end
  end

  describe "delete_thread" do
    test "removes only the targeted thread", %{config: config} do
      Dets.put(config, "keep", make_cp("keep", 0))
      Dets.put(config, "drop", make_cp("drop", 0))

      Dets.delete_thread(config, "drop")

      assert {:ok, %Checkpoint{}} = Dets.get_latest(config, "keep")
      assert {:error, :not_found} = Dets.get_latest(config, "drop")
    end
  end

  describe "list_paused (ADR-0017)" do
    defp make_paused(thread_id, step, reason, paused_at, state \\ %{}) do
      Checkpoint.new(
        thread_id: thread_id,
        step: step,
        state: state,
        metadata: %{
          node_id: :awaiting,
          interrupt_reason: reason,
          paused_at: paused_at
        }
      )
    end

    test "returns paused threads, newest-paused-first", %{config: config} do
      t0 = ~U[2026-01-01 00:00:00Z]
      t1 = ~U[2026-01-01 00:01:00Z]

      Dets.put(config, "a", make_paused("a", 0, :awaiting_payment, t0))
      Dets.put(config, "b", make_paused("b", 0, :awaiting_approval, t1))
      Dets.put(config, "c", make_cp("c", 0))

      assert {:ok, rows} = Dets.list_paused(config, 10)
      assert length(rows) == 2

      [first | _] = rows
      assert first.thread_id == "b"
      assert first.interrupt_reason == :awaiting_approval
      assert first.paused_at == t1
    end

    test "a resumed thread (newer non-pause checkpoint) is excluded",
         %{config: config} do
      t0 = ~U[2026-01-01 00:00:00Z]
      Dets.put(config, "paused", make_paused("paused", 0, :awaiting_x, t0))
      Dets.put(config, "resumed", make_paused("resumed", 0, :awaiting_x, t0))
      Dets.put(config, "resumed", make_cp("resumed", 1, %{done: true}))

      assert {:ok, [row]} = Dets.list_paused(config, 10)
      assert row.thread_id == "paused"
    end
  end

  describe "durability across server restart" do
    test "checkpoints persist when the GenServer restarts", %{
      config: %{name: name} = config
    } do
      Dets.put(config, "thr", make_cp("thr", 0, %{durable: true}))
      Dets.stop(name)

      # Same name + same file path -> reopens the existing DETS data
      file =
        Path.join(
          System.tmp_dir!(),
          "raxol_workflow_dets_#{name |> Atom.to_string() |> String.replace("dets_test_", "")}"
        )

      {:ok, _} = Dets.start_link(name: name, file: file)

      assert {:ok, %Checkpoint{state: %{durable: true}}} =
               Dets.get_latest(config, "thr")
    end
  end
end
