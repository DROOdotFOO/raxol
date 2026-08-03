# Cross-Chain Settlement (ADR-0019)
#
# Single ACP job settles on two chains simultaneously. Each chain gets
# its own `createMemo`-style write running in a separate workflow
# branch; a join reconciles their tx_hashes into one merged state.
#
# Scope: this demonstrates the workflow graph mechanics (fan-out/join) with
# hermetic SimChain agents. For the actual cross-chain stealth settlement path
# through Xochi (`Raxol.Earn.Xochi.Settler` -> `Raxol.Payments.Protocols.Xochi`),
# see packages/raxol_payments/examples/crosschain_stealth_payment.exs.
#
# Demonstrates:
#
#   * `Raxol.Workflow.Graph.add_channel/3` declares a per-key reducer.
#   * `Raxol.Workflow.Graph.add_join/4` declares a barrier whose
#     upstream branches all converge before the join body runs.
#   * A conditional edge returning a list (`[branch_a, branch_b]`) tells
#     the runtime to fan out across the branches via `Task.async_stream`.
#   * The same workflow with `parallelism: 1` selects the serial path,
#     useful for contrasting wall-clock cost.
#
# Usage (from packages/raxol_earn/):
#
#   mix run examples/cross_chain_settlement.exs

alias Raxol.Workflow.Compiled
alias Raxol.Workflow.Graph

# --- Two simulated chains with independent state ---
#
# Each chain holds its own ledger + monotonic tx counter. In production
# these would be two on-chain write paths backed by different RPC
# endpoints (e.g., Base + Optimism); here they're plain Agents so the
# demo runs hermetically.

defmodule SimChain do
  use Agent

  def start(prefix, latency_ms) do
    {:ok, pid} = Agent.start_link(fn -> %{prefix: prefix, latency_ms: latency_ms, tx_counter: 0, memos: []} end)
    pid
  end

  def write_memo(pid, content) do
    Agent.get_and_update(pid, fn state ->
      Process.sleep(state.latency_ms)
      n = state.tx_counter + 1
      tx_hash = "#{state.prefix}-tx-#{n}"
      memo = %{seq: n, content: content, tx_hash: tx_hash}

      {tx_hash, %{state | tx_counter: n, memos: [memo | state.memos]}}
    end)
  end

  def memos(pid), do: Agent.get(pid, & &1.memos) |> Enum.reverse()
end

# --- Build the cross-chain workflow ---

build_graph = fn parallelism ->
  Graph.new(:cross_chain_settlement)
  # Two branches each write to `:tx_hashes` under different keys
  # (`:chain_a` / `:chain_b`); the channel's `Map.merge/2` reducer
  # collapses them into a single map at the join.
  |> Graph.add_channel(:tx_hashes, into: :tx_hashes, with: &Map.merge/2)
  |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
  |> Graph.add_node(:submit_chain_a, fn s ->
    tx_hash = SimChain.write_memo(s.chain_a, "delivery_evidence")
    {:ok, Map.put(s, :tx_hashes, %{chain_a: tx_hash})}
  end)
  |> Graph.add_node(:submit_chain_b, fn s ->
    tx_hash = SimChain.write_memo(s.chain_b, "evaluator_signature")
    {:ok, Map.put(s, :tx_hashes, %{chain_b: tx_hash})}
  end)
  |> Graph.add_node(:reconcile, fn s ->
    %{chain_a: a, chain_b: b} = s.tx_hashes
    {:ok, Map.put(s, :reconciled, %{chain_a_tx: a, chain_b_tx: b})}
  end)
  |> Graph.add_edge(:__start__, :fan_out)
  |> Graph.add_conditional_edge(
    :fan_out,
    [:submit_chain_a, :submit_chain_b],
    fn _ -> [:submit_chain_a, :submit_chain_b] end
  )
  |> Graph.add_edge(:submit_chain_a, :reconcile)
  |> Graph.add_edge(:submit_chain_b, :reconcile)
  |> Graph.add_join(:reconcile, [:submit_chain_a, :submit_chain_b], parallelism: parallelism)
  |> Graph.add_edge(:reconcile, :__end__)
end

run_once = fn label, parallelism ->
  chain_a = SimChain.start("a", 80)
  chain_b = SimChain.start("b", 120)

  {:ok, compiled} = Graph.compile(build_graph.(parallelism))

  initial_state = %{chain_a: chain_a, chain_b: chain_b, tx_hashes: %{}}

  started_us = System.monotonic_time(:microsecond)
  {:ok, final, _meta} = Compiled.invoke(compiled, initial_state)
  elapsed_ms = div(System.monotonic_time(:microsecond) - started_us, 1_000)

  IO.puts("\n[#{label}]")
  IO.puts("  parallelism      : #{inspect(parallelism)}")
  IO.puts("  elapsed          : #{elapsed_ms} ms")
  IO.puts("  reconciled       : #{inspect(final.reconciled)}")
  IO.puts("  chain_a memos    : #{inspect(SimChain.memos(chain_a))}")
  IO.puts("  chain_b memos    : #{inspect(SimChain.memos(chain_b))}")

  elapsed_ms
end

IO.puts("=== Cross-Chain Settlement (ADR-0019) ===")
IO.puts("Chain A simulated RPC latency: 80 ms")
IO.puts("Chain B simulated RPC latency: 120 ms")

parallel_ms = run_once.("concurrent", :branches)
serial_ms = run_once.("serial (parallelism: 1)", 1)

speedup = Float.round(serial_ms / max(parallel_ms, 1), 2)

IO.puts("\n=== Summary ===")
IO.puts("  concurrent  : #{parallel_ms} ms (bounded by the slowest branch)")
IO.puts("  serial      : #{serial_ms} ms (sum of both branches)")
IO.puts("  speedup     : ~#{speedup}x")
