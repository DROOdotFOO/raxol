defmodule Raxol.Symphony.Sandboxes.TurnRateLimitTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Sandbox
  alias Raxol.Symphony.Sandboxes.TurnRateLimit

  defp sandbox(opts \\ []) do
    %TurnRateLimit{
      max_turns: Keyword.get(opts, :max_turns, 3),
      window_ms: Keyword.get(opts, :window_ms, 1_000),
      bucket_table:
        Keyword.get(
          opts,
          :bucket_table,
          :"trl_test_#{:erlang.unique_integer([:positive])}"
        )
    }
  end

  setup do
    on_exit(fn ->
      for table <- :ets.all(),
          is_atom(table),
          String.starts_with?(Atom.to_string(table), "trl_test_") do
        drop_table(table)
      end
    end)

    :ok
  end

  # A table owned by a process the test spawned may be on its way out already,
  # so treat "already gone" as done rather than as a failing cleanup.
  defp drop_table(table) do
    :ets.delete(table)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp authorize(sb, issue_id, action \\ :turn) do
    Sandbox.authorize(sb, action, %{issue_id: issue_id, turn: 1}, %{})
  end

  describe "Sandbox protocol, :turn action" do
    test "allows the first N turns within the window" do
      sb = sandbox(max_turns: 3)

      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
    end

    test "denies the N+1th turn with :rate_limited" do
      sb = sandbox(max_turns: 2)

      assert :ok = authorize(sb, "iss-1")
      assert :ok = authorize(sb, "iss-1")
      assert {:deny, :rate_limited} = authorize(sb, "iss-1")
    end

    test "issues are tracked independently" do
      sb = sandbox(max_turns: 1)

      assert :ok = authorize(sb, "iss-a")
      assert :ok = authorize(sb, "iss-b")
      assert :ok = authorize(sb, "iss-c")

      # Each issue's bucket is independent.
      assert {:deny, :rate_limited} = authorize(sb, "iss-a")
      assert {:deny, :rate_limited} = authorize(sb, "iss-b")
    end

    test "older entries are pruned past the window" do
      # 1-turn budget, 50ms window. Use 1 turn, sleep > 50ms, get
      # another turn back.
      sb = sandbox(max_turns: 1, window_ms: 50)

      assert :ok = authorize(sb, "iss-1")
      assert {:deny, :rate_limited} = authorize(sb, "iss-1")

      Process.sleep(80)

      assert :ok = authorize(sb, "iss-1")
    end

    test "a max_turns of 0 denies every turn and records nothing" do
      sb = sandbox(max_turns: 0)

      assert {:deny, :rate_limited} = authorize(sb, "iss-1")
      assert {:deny, :rate_limited} = authorize(sb, "iss-1")
      assert [] = :ets.lookup(sb.bucket_table, "iss-1")
    end
  end

  describe "Sandbox protocol, other actions abstain" do
    test "non-:turn actions return :ok regardless of bucket state" do
      sb = sandbox(max_turns: 0)

      # Even with max_turns: 0 (no :turn ever allowed), other actions
      # pass through.
      assert :ok = authorize(sb, "iss-1", :shell)
      assert :ok = authorize(sb, "iss-1", :send_agent)
      assert :ok = authorize(sb, "iss-1", :async)
    end

    test "a payload without an issue_id abstains" do
      sb = sandbox(max_turns: 0)

      assert :ok = Sandbox.authorize(sb, :turn, %{turn: 1}, %{})
    end
  end

  describe "admit/3 window edges" do
    test "an entry ages out exactly window_ms after it was recorded" do
      sb = sandbox(max_turns: 1, window_ms: 100)

      assert :ok = TurnRateLimit.admit(sb, "iss-1", 1_000)

      # One millisecond short of the window: the entry is still counted.
      assert {:deny, :rate_limited} = TurnRateLimit.admit(sb, "iss-1", 1_099)

      # At now - window_ms the entry has aged out.
      assert :ok = TurnRateLimit.admit(sb, "iss-1", 1_100)
    end

    test "a denied turn is not recorded, so it cannot extend the window" do
      sb = sandbox(max_turns: 1, window_ms: 1_000)

      assert :ok = TurnRateLimit.admit(sb, "iss-1", 1_000)
      assert {:deny, :rate_limited} = TurnRateLimit.admit(sb, "iss-1", 1_500)

      assert [{"iss-1", [1_000]}] = :ets.lookup(sb.bucket_table, "iss-1")

      # The budget returns window_ms after the admitted turn, not after the
      # denied one.
      assert :ok = TurnRateLimit.admit(sb, "iss-1", 2_000)
    end

    test "a row never holds more than max_turns entries" do
      sb = sandbox(max_turns: 2, window_ms: 1_000)

      for now <- [1_000, 1_100, 2_500, 2_600, 4_000] do
        _ = TurnRateLimit.admit(sb, "iss-1", now)
      end

      assert [{"iss-1", stamps}] = :ets.lookup(sb.bucket_table, "iss-1")
      assert length(stamps) <= sb.max_turns
    end
  end

  describe "concurrent :turn authorization" do
    test "admits exactly max_turns when many processes contend for one issue" do
      contenders = 64
      rounds = 10
      sb = sandbox(max_turns: 5, window_ms: 60_000)

      # Own the table from the test process. Created inside a contender it
      # would die with that contender partway through the round.
      TurnRateLimit.ensure_table(sb.bucket_table)

      for round <- 1..rounds do
        results = race(sb, "iss-race-#{round}", contenders)

        admitted = Enum.count(results, &(&1 == :ok))
        denied = Enum.count(results, &(&1 == {:deny, :rate_limited}))

        assert admitted == sb.max_turns,
               "round #{round}: #{admitted} turns admitted, the cap is #{sb.max_turns}"

        assert denied == contenders - sb.max_turns
      end
    end
  end

  describe "sweep/2" do
    test "drops rows whose whole window has elapsed and keeps the rest" do
      sb = sandbox(max_turns: 2, window_ms: 100)

      assert :ok = TurnRateLimit.admit(sb, "iss-old", 1_000)
      assert :ok = TurnRateLimit.admit(sb, "iss-new", 1_050)

      assert 1 = TurnRateLimit.sweep(sb, 1_100)

      assert [] = :ets.lookup(sb.bucket_table, "iss-old")
      assert [{"iss-new", [1_050]}] = :ets.lookup(sb.bucket_table, "iss-new")
    end

    test "does not hand a live issue its budget back" do
      sb = sandbox(max_turns: 1, window_ms: 100)

      assert :ok = TurnRateLimit.admit(sb, "iss-1", 1_000)
      assert 0 = TurnRateLimit.sweep(sb, 1_050)
      assert {:deny, :rate_limited} = TurnRateLimit.admit(sb, "iss-1", 1_050)
    end

    test "is a no-op on an empty table" do
      sb = sandbox()

      assert 0 = TurnRateLimit.sweep(sb, 1_000)
    end
  end

  describe "ensure_table/1" do
    test "creates a new ETS table on first call" do
      table = :"trl_test_#{:erlang.unique_integer([:positive])}"
      assert :ets.whereis(table) == :undefined

      assert ^table = TurnRateLimit.ensure_table(table)
      assert :ets.whereis(table) != :undefined

      :ets.delete(table)
    end

    test "is idempotent (second call no-ops)" do
      table = :"trl_test_#{:erlang.unique_integer([:positive])}"
      _ = TurnRateLimit.ensure_table(table)

      ref_after_first = :ets.whereis(table)
      _ = TurnRateLimit.ensure_table(table)

      assert :ets.whereis(table) == ref_after_first

      :ets.delete(table)
    end

    test "concurrent first calls settle on one table instead of raising" do
      table = :"trl_test_#{:erlang.unique_integer([:positive])}"
      parent = self()
      gate = open_gate()

      pids =
        for _ <- 1..32 do
          spawn(fn ->
            send(parent, {:ready, self()})
            :ok = await_gate(gate)
            send(parent, {:result, self(), TurnRateLimit.ensure_table(table)})

            # Whichever contender won the create owns the table, so hold them
            # all open until the assertions have run.
            receive do
              :stop -> :ok
            after
              5_000 -> :ok
            end
          end)
        end

      release(gate, pids)

      for pid <- pids do
        assert_receive {:result, ^pid, ^table}, 5_000
      end

      assert :ets.whereis(table) != :undefined

      for pid <- pids, do: send(pid, :stop)
      :ets.delete(gate)
    end
  end

  # Release `contenders` processes against a barrier so they authorize the same
  # issue at the same instant, then collect what each one was told. Spawning and
  # messaging them in sequence would let the first finish before the last starts,
  # which is exactly the interleaving a read-modify-write bug survives.
  defp race(sb, issue_id, contenders) do
    parent = self()
    gate = open_gate()

    pids =
      for _ <- 1..contenders do
        spawn(fn ->
          send(parent, {:ready, self()})
          :ok = await_gate(gate)
          send(parent, {:result, self(), authorize(sb, issue_id)})
        end)
      end

    release(gate, pids)

    results =
      for pid <- pids do
        assert_receive {:result, ^pid, result}, 5_000
        result
      end

    :ets.delete(gate)
    results
  end

  defp open_gate do
    gate = :ets.new(:trl_race_gate, [:set, :public])
    :ets.insert(gate, {:open?, false})
    gate
  end

  # Wait until every contender is scheduled and spinning on the flag, then flip
  # it once so they all proceed together.
  defp release(gate, pids) do
    for pid <- pids, do: assert_receive({:ready, ^pid}, 5_000)
    :ets.insert(gate, {:open?, true})
    :ok
  end

  defp await_gate(gate) do
    await_gate(gate, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_gate(gate, deadline) do
    cond do
      :ets.lookup_element(gate, :open?, 2) -> :ok
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> await_gate(gate, deadline)
    end
  end
end
