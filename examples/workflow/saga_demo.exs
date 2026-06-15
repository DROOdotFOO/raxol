# Saga Demo: failure_policy :compensate
#
# Models a 3-step order fulfillment that fails at the shipping step.
# When :ship fails, the runtime walks back through the executed nodes
# in reverse and runs each one's compensation function, threading
# state through so the final result reflects a clean rollback.
#
# What you'll learn:
#   - Graph.add_node/4 with (id, do_fun, compensate_fun)
#   - failure_policy: :compensate via Graph.compile/2
#   - State threading through reverse-order compensations
#   - Telemetry: [:raxol, :workflow, :node, :compensated] events
#
# Run: mix run examples/workflow/saga_demo.exs

alias Raxol.Workflow.Compiled
alias Raxol.Workflow.Graph

IO.puts("Saga demo: order with reserve -> charge -> ship, failing at :ship\n")

# Attach a telemetry handler to print each compensation as it runs.
:telemetry.attach(
  "saga-demo-tap",
  [:raxol, :workflow, :node, :compensated],
  fn _event, _measurements, metadata, _ ->
    IO.puts(
      "  compensated #{inspect(metadata.node_id)} -> #{inspect(metadata.result)}"
    )
  end,
  nil
)

{:ok, compiled} =
  Graph.new(:order_saga)
  |> Graph.add_node(
    :reserve_inventory,
    fn state ->
      IO.puts("  reserving inventory")
      {:ok, Map.put(state, :reserved, true)}
    end,
    fn state ->
      IO.puts("  releasing reserved inventory")
      {:ok, Map.put(state, :reserved, false)}
    end
  )
  |> Graph.add_node(
    :charge_payment,
    fn state ->
      IO.puts("  charging payment $#{state.amount}")
      {:ok, Map.put(state, :charged, true)}
    end,
    fn state ->
      IO.puts("  refunding payment $#{state.amount}")
      {:ok, Map.put(state, :charged, false)}
    end
  )
  |> Graph.add_node(:ship_order, fn _ ->
    IO.puts("  attempting to ship - carrier unavailable")
    {:error, :carrier_unavailable}
  end)
  |> Graph.add_edge(:__start__, :reserve_inventory)
  |> Graph.add_edge(:reserve_inventory, :charge_payment)
  |> Graph.add_edge(:charge_payment, :ship_order)
  |> Graph.add_edge(:ship_order, :__end__)
  |> Graph.compile(failure_policy: :compensate)

{:error, reason, final_state} = Compiled.invoke(compiled, %{amount: 42})

IO.puts("\nrun failed with reason: #{inspect(reason)}")
IO.puts("final state: #{inspect(final_state)}")

:telemetry.detach("saga-demo-tap")
