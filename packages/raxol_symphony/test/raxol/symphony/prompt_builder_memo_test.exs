defmodule Raxol.Symphony.PromptBuilderMemoTest do
  @moduledoc """
  White-box coverage for the parsed-template memo. The memo is ONE
  `:persistent_term` entry `{PromptBuilder, :parsed_templates}` holding a
  bounded `%{map: %{template => ast}, order: [template]}` with FIFO eviction.

  `async: false`: these poison and inspect the single shared entry, so no
  other module may call `PromptBuilder.build/2` concurrently.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Issue, PromptBuilder}
  alias Raxol.Symphony.PromptBuilder.Memo

  @memo_key {PromptBuilder, :parsed_templates}
  @max_memoized 16

  defp issue(opts \\ []) do
    struct(
      %Issue{id: "abc", identifier: "MT-1", title: "T", state: "Todo"},
      opts
    )
  end

  defp memo, do: :persistent_term.get(@memo_key, %{map: %{}, order: []})

  setup do
    # Start each test from an empty memo, and leave it empty afterward, so
    # eviction counts are deterministic and the cache is not left polluted.
    :persistent_term.erase(@memo_key)
    on_exit(fn -> :persistent_term.erase(@memo_key) end)
    :ok
  end

  test "memoizes the parsed AST; a second build reuses it instead of re-parsing" do
    template = "A {{ issue.identifier }}"
    other = "B {{ issue.identifier }}"

    assert {:ok, "A MT-1"} = PromptBuilder.build(issue(), template)

    # Poison the memoized slot for `template` with a DIFFERENT template's AST.
    # A re-parse would render "A ..."; a memo HIT renders the poisoned "B ...".
    {:ok, other_ast} = Solid.parse(other)
    m = memo()

    :persistent_term.put(@memo_key, %{
      m
      | map: Map.put(m.map, template, other_ast)
    })

    assert {:ok, "B MT-1"} = PromptBuilder.build(issue(), template)
  end

  test "distinct templates each memoize and render their own text" do
    assert {:ok, "one MT-1"} =
             PromptBuilder.build(issue(), "one {{ issue.identifier }}")

    assert {:ok, "two MT-1"} =
             PromptBuilder.build(issue(), "two {{ issue.identifier }}")

    assert Map.has_key?(memo().map, "one {{ issue.identifier }}")
    assert Map.has_key?(memo().map, "two {{ issue.identifier }}")
  end

  test "renders stay per-issue/attempt; only the parse is shared" do
    template = "s {{ issue.identifier }} a={{ attempt }}"

    assert {:ok, "s MT-1 a="} = PromptBuilder.build(issue(), template, nil)

    assert {:ok, "s MT-2 a=5"} =
             PromptBuilder.build(issue(identifier: "MT-2"), template, 5)
  end

  test "the memo is bounded: a live-reloaded template cannot grow it past the cap" do
    templates =
      for i <- 1..(@max_memoized + 5), do: "t#{i} {{ issue.identifier }}"

    Enum.each(templates, fn t ->
      assert {:ok, _} = PromptBuilder.build(issue(), t)
    end)

    m = memo()
    # Capped at @max_memoized despite building @max_memoized + 5 distinct
    # templates -- the persistent_term entry never grows without bound.
    assert map_size(m.map) == @max_memoized
    assert length(m.order) == @max_memoized

    # FIFO: the oldest templates were evicted, the newest retained.
    assert Map.has_key?(m.map, List.last(templates))
    refute Map.has_key?(m.map, List.first(templates))
  end

  test "distinct templates parsed concurrently keep the memo bounded and consistent" do
    # Far more distinct new templates than the cap, all racing through the
    # parse+memoize path at once. The single-writer memo owner serializes the
    # read-modify-write so the bound holds and order/map cannot drift.
    1..200
    |> Task.async_stream(
      fn n ->
        assert {:ok, _} =
                 PromptBuilder.build(issue(), "t#{n} {{ issue.identifier }}")
      end,
      max_concurrency: 50,
      ordered: false
    )
    |> Stream.run()

    m = memo()

    assert map_size(m.map) == @max_memoized
    assert length(m.order) == @max_memoized
    # No duplicate order entries, and order agrees exactly with the map keys.
    assert Enum.uniq(m.order) == m.order
    assert MapSet.new(m.order) == MapSet.new(Map.keys(m.map))
  end

  test "concurrent parses of the same new template do not double-insert" do
    template = "same {{ issue.identifier }}"

    1..50
    |> Task.async_stream(
      fn _ -> assert {:ok, _} = PromptBuilder.build(issue(), template) end,
      max_concurrency: 50,
      ordered: false
    )
    |> Stream.run()

    m = memo()

    assert map_size(m.map) == 1
    assert length(m.order) == 1
    assert m.order == Map.keys(m.map)
  end

  describe "a broken memo writer degrades to a best-effort no-op" do
    test "build renders correctly when the writer has been killed (it restarts)" do
      kill_memo()
      refute Process.whereis(Memo)

      template = "K {{ issue.identifier }}"
      assert {:ok, "K MT-1"} = PromptBuilder.build(issue(), template)
      # The absent writer was lazily restarted and the write went through.
      assert Map.has_key?(memo().map, template)
    end

    test "a writer that dies mid-call never crashes build; re-parse is identical" do
      install_standin_writer(:crash_on_call)

      template = "C {{ issue.identifier }}"

      # First build: the writer crashes on the `GenServer.call`. build/2 must
      # NOT crash/exit -- the parse result is returned, the write is a no-op.
      assert {:ok, "C MT-1"} = PromptBuilder.build(issue(), template)
      assert memo().map == %{}

      # The crashing stand-in died on that one call, so the next build lazily
      # starts the real writer. Output is identical (re-parsed), now memoized.
      assert {:ok, "C MT-1"} = PromptBuilder.build(issue(), template)
      assert Map.has_key?(memo().map, template)
    end

    test "a wedged writer cannot stall build past the write deadline" do
      install_standin_writer(:never_reply)

      template = "W {{ issue.identifier }}"

      {micros, result} =
        :timer.tc(fn -> PromptBuilder.build(issue(), template) end)

      # Returns the correct prompt despite the wedged singleton, and the 1s
      # write deadline means it never blocks for the old 5s GenServer default.
      assert {:ok, "W MT-1"} = result
      assert micros < 3_000_000
      # The write timed out, so it was a silent no-op: nothing memoized.
      assert memo().map == %{}
    end
  end

  # Kill the (possibly running) singleton writer and wait for the name to free.
  defp kill_memo do
    case Process.whereis(Memo) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          1_000 -> :ok
        end
    end
  end

  # Register a fake process under the writer's name so `ensure_started` finds a
  # live pid (skips the real start) but the `GenServer.call` into it fails --
  # exercising the try/catch :exit no-op. Killed on test exit.
  defp install_standin_writer(:crash_on_call) do
    install_standin(fn ->
      receive do
        {:"$gen_call", _from, _req} -> exit(:writer_died_mid_call)
      end
    end)
  end

  defp install_standin_writer(:never_reply) do
    install_standin(fn -> Process.sleep(:infinity) end)
  end

  defp install_standin(fun) do
    kill_memo()
    pid = spawn(fun)
    Process.register(pid, Memo)

    on_exit(fn ->
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    pid
  end
end
