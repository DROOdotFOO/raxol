defmodule Raxol.Agent.PaymentRecoveryTest do
  @moduledoc """
  Crash safety for an agent that signs and dispatches a payment, then loses its
  process before the settlement is confirmed.

  Cross-chain settlement is asynchronous: there is a window where the agent has
  signed and dispatched an intent, the solver is filling it, and the agent does not
  yet know it landed. A crash in that window is where money is lost on a runtime
  with no fault isolation: the restarted agent re-signs and pays twice, or strands
  the funds.

  These tests model the chain/solver as a `SettlementStore` (a fixture for the
  external boundary, not a stand-in for any Raxol module) and run a real
  supervised `Agent.Process`. The safe agent checkpoints its `intent_id` to context
  and resumes that intent on restart, signing exactly once. A non-persisting agent
  re-signs -- the failure this design prevents.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.ContextStore
  alias Raxol.Agent.Process, as: AgentProcess

  defmodule SettlementStore do
    @moduledoc "Stands in for the chain/solver. Counts raw sign calls and confirmations."
    use GenServer

    def child_spec(opts) do
      %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}}
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, %{}, name: Keyword.fetch!(opts, :name))
    end

    def sign(name), do: GenServer.call(name, :sign)
    def poll(name, intent_id), do: GenServer.call(name, {:poll, intent_id})
    def release(name, intent_id), do: GenServer.call(name, {:release, intent_id})
    def confirm(name, intent_id), do: GenServer.call(name, {:confirm, intent_id})
    def sign_calls(name), do: GenServer.call(name, :sign_calls)
    def settled_count(name), do: GenServer.call(name, :settled_count)

    @impl true
    def init(_) do
      {:ok, %{sign_calls: 0, released: MapSet.new(), confirmed: MapSet.new()}}
    end

    @impl true
    def handle_call(:sign, _from, state) do
      n = state.sign_calls + 1
      {:reply, "intent-#{n}", %{state | sign_calls: n}}
    end

    def handle_call({:poll, intent_id}, _from, state) do
      reply = if MapSet.member?(state.released, intent_id), do: :settled, else: :pending
      {:reply, reply, state}
    end

    def handle_call({:release, intent_id}, _from, state) do
      {:reply, :ok, %{state | released: MapSet.put(state.released, intent_id)}}
    end

    def handle_call({:confirm, intent_id}, _from, state) do
      {:reply, :ok, %{state | confirmed: MapSet.put(state.confirmed, intent_id)}}
    end

    def handle_call(:sign_calls, _from, state), do: {:reply, state.sign_calls, state}

    def handle_call(:settled_count, _from, state),
      do: {:reply, MapSet.size(state.confirmed), state}
  end

  defmodule PaymentAgent do
    @moduledoc "Signs an intent, then polls it to settlement. Optionally checkpoints the intent."

    def init(opts) do
      {:ok,
       %{
         store: Keyword.fetch!(opts, :store),
         persist: Keyword.get(opts, :persist, true),
         intent_id: nil,
         status: :idle
       }}
    end

    def observe(_events, state), do: {:ok, %{}, state}

    def think(_observation, state) do
      cond do
        Map.get(state, :status) == :completed -> {:wait, state}
        is_nil(Map.get(state, :intent_id)) -> {:act, :sign, state}
        true -> {:act, :poll, state}
      end
    end

    def act(:sign, state) do
      intent_id = SettlementStore.sign(state.store)
      {:ok, %{state | intent_id: intent_id, status: :dispatched}}
    end

    def act(:poll, state) do
      case SettlementStore.poll(state.store, state.intent_id) do
        :settled ->
          SettlementStore.confirm(state.store, state.intent_id)
          {:ok, %{state | status: :completed}}

        :pending ->
          {:ok, state}
      end
    end

    def receive_directive(_directive, state), do: {:ok, state}

    # The safe agent checkpoints the in-flight intent; the non-persisting one drops
    # it and is forced to start over (re-signing) on restart.
    def context_snapshot(%{persist: true} = state),
      do: Map.take(state, [:store, :persist, :intent_id, :status])

    def context_snapshot(%{persist: false} = state),
      do: Map.take(state, [:store, :persist])

    def restore_context(snapshot) do
      {:ok,
       %{
         store: Map.fetch!(snapshot, :store),
         persist: Map.fetch!(snapshot, :persist),
         intent_id: Map.get(snapshot, :intent_id),
         status: Map.get(snapshot, :status, :idle)
       }}
    end
  end

  setup do
    ContextStore.init()

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})
    start_supervised!({SettlementStore, name: :settlement_store})

    on_exit(fn ->
      for id <- ContextStore.list(), do: ContextStore.delete(id)
    end)

    %{store: :settlement_store}
  end

  test "resumes the in-flight intent after a crash without re-signing", %{store: store} do
    {:ok, original} = start_payer(:payer_safe, store, persist: true)

    # Signed and dispatched, intent durably checkpointed -- the in-flight window.
    wait_until(fn -> SettlementStore.sign_calls(store) == 1 and dispatched?(:payer_safe) end)
    intent_id = loaded(:payer_safe).intent_id
    assert is_binary(intent_id)

    # The crash that should cost money: the machine dies mid-settlement.
    Process.exit(original, :kill)
    restarted = wait_for_restart(:payer_safe, original)
    assert restarted != original

    # The solver settles the original intent. A correct resume polls that same
    # intent; it never signs a second time.
    SettlementStore.release(store, intent_id)
    wait_until(fn -> SettlementStore.settled_count(store) == 1 end)

    assert SettlementStore.sign_calls(store) == 1
    assert loaded(:payer_safe).status == :completed
  end

  test "a non-persisting agent re-signs after a crash (the failure this prevents)", %{
    store: store
  } do
    {:ok, original} = start_payer(:payer_naive, store, persist: false)

    wait_until(fn -> SettlementStore.sign_calls(store) == 1 end)

    Process.exit(original, :kill)
    restarted = wait_for_restart(:payer_naive, original)
    assert restarted != original

    # Without the checkpoint the restarted agent has no memory of the in-flight
    # payment, so it signs again -- a double-spend.
    wait_until(fn -> SettlementStore.sign_calls(store) == 2 end)
    assert SettlementStore.sign_calls(store) == 2
  end

  defp start_payer(agent_id, store, opts) do
    DynamicSupervisor.start_child(
      Raxol.Agent.DynSup,
      {AgentProcess,
       agent_id: agent_id,
       agent_module: PaymentAgent,
       tick_ms: 20,
       store: store,
       persist: Keyword.fetch!(opts, :persist)}
    )
  end

  defp loaded(agent_id) do
    case ContextStore.load(agent_id) do
      {:ok, context} -> context
      _ -> nil
    end
  end

  defp dispatched?(agent_id), do: match?(%{status: :dispatched}, loaded(agent_id))

  defp wait_for_restart(agent_id, old_pid) do
    wait_until(fn ->
      case registered_pid(agent_id) do
        pid when is_pid(pid) -> pid != old_pid and Process.alive?(pid)
        _ -> false
      end
    end)

    registered_pid(agent_id)
  end

  defp registered_pid(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, {:process, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Polls a predicate up to a bound; deterministic, no timing assertions.
  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
