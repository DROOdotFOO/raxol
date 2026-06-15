# Retry Demo: failure_policy :retry
#
# Models a flaky external call that fails the first two attempts and
# succeeds on the third. Under failure_policy: :retry the runtime
# retries with exponential backoff before giving up.
#
# What you'll learn:
#   - failure_policy: :retry + max_attempts + retry_backoff_ms
#   - Per-attempt telemetry: each attempt emits its own node.started +
#     node.failed (or node.completed on the final success)
#   - The exponential backoff schedule (base * 2^(attempt - 1))
#
# Run: mix run examples/workflow/retry_demo.exs

alias Raxol.Workflow.Compiled
alias Raxol.Workflow.Graph

IO.puts("Retry demo: flaky API call, fails 2x then succeeds\n")

:ets.new(:retry_demo_counter, [:public, :named_table, :set])
:ets.insert(:retry_demo_counter, {:n, 0})

:telemetry.attach(
  "retry-demo-tap",
  [:raxol, :workflow, :node, :failed],
  fn _event, _m, metadata, _ ->
    IO.puts("  attempt failed: #{inspect(metadata.reason)}")
  end,
  nil
)

{:ok, compiled} =
  Graph.new(:retry_demo)
  |> Graph.add_node(:flaky_api, fn state ->
    n = :ets.update_counter(:retry_demo_counter, :n, 1)
    IO.puts("  calling api (attempt #{n})")

    if n <= 2 do
      {:error, {:transient, n}}
    else
      {:ok, Map.put(state, :api_response, "ok after #{n} attempts")}
    end
  end)
  |> Graph.add_edge(:__start__, :flaky_api)
  |> Graph.add_edge(:flaky_api, :__end__)
  |> Graph.compile(
    failure_policy: :retry,
    max_attempts: 5,
    retry_backoff_ms: 50
  )

case Compiled.invoke(compiled, %{}) do
  {:ok, final_state, meta} ->
    IO.puts("\nrun succeeded after #{meta.nodes_executed} node(s)")
    IO.puts("final state: #{inspect(final_state)}")

  {:error, reason, _} ->
    IO.puts("\nrun failed: #{inspect(reason)}")
end

:telemetry.detach("retry-demo-tap")
:ets.delete(:retry_demo_counter)
