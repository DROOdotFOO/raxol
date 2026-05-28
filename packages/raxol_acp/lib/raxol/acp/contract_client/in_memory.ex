defmodule Raxol.ACP.ContractClient.InMemory do
  @moduledoc """
  In-process implementation of `Raxol.ACP.ContractClient`.

  Holds the simulated chain state in an `Agent`. Job ids and tx hashes
  are deterministic synthetic strings (`"job-1"`, `"tx-1"`, ...) so
  callers get reproducible identifiers.

  This is NOT a mock -- it's a second real implementation of the same
  behaviour, in the spirit of `Raxol.Payments.Wallets.Env` vs
  `Raxol.Payments.Wallets.Op`. The dispatch in
  `Raxol.ACP.ContractClient.impl/0` selects which one to use.

  ## When to use

  - **Tests** -- pair with the test helper (`test_helper.exs` starts
    one and seeds the env), call `reset/0` in setup so prior state
    does not leak.
  - **Bench harness** -- `mix raxol_acp.bench` drives jobs end-to-end
    against this impl with no chain or RPC required.
  - **Local development** -- exercise the seller stack without
    standing up a sepolia endpoint or burning testnet USDC.

  Lives in `lib/` (not `test/support/`) because the bench harness
  needs it at runtime.

  ## Inspection helpers

      InMemory.list_jobs()       # all known job ids
      InMemory.get_job(job_id)   # full state for one job, or nil
      InMemory.list_memos(jid)   # memos in submission order
  """

  @behaviour Raxol.ACP.ContractClient

  use Agent

  @type state :: %{
          jobs: %{binary() => map()},
          signs: [map()],
          job_counter: non_neg_integer(),
          tx_counter: non_neg_integer()
        }

  @initial_state %{jobs: %{}, signs: [], job_counter: 0, tx_counter: 0}

  # -- Lifecycle --

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []) do
    Agent.start_link(fn -> @initial_state end, name: __MODULE__)
  end

  @doc "Wipe all simulated chain state. Call this in test setup."
  @spec reset() :: :ok
  def reset, do: Agent.update(__MODULE__, fn _ -> @initial_state end)

  # -- Behaviour callbacks --

  @impl true
  def create_job(provider, evaluator, expired_at)
      when is_binary(provider) and is_binary(evaluator) and is_integer(expired_at) do
    Agent.get_and_update(__MODULE__, fn %{job_counter: n, jobs: jobs} = state ->
      job_id = "job-#{n + 1}"

      job = %{
        provider: provider,
        evaluator: evaluator,
        expired_at: expired_at,
        budget: nil,
        memos: [],
        signs: [],
        claimed: false
      }

      new_state = %{state | job_counter: n + 1, jobs: Map.put(jobs, job_id, job)}
      {{:ok, job_id}, new_state}
    end)
  end

  @impl true
  def set_budget(job_id, %Decimal{} = amount) when is_binary(job_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)
        new_job = %{job | budget: amount}
        bump_tx({{:ok, tx_hash}, put_job(state, job_id, new_job)})
      end)
    end)
  end

  @impl true
  def create_memo(job_id, content, memo_type, is_secured, next_phase)
      when is_binary(job_id) and is_binary(content) and is_atom(memo_type) and
             is_boolean(is_secured) and is_atom(next_phase) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)

        memo = %{
          content: content,
          memo_type: memo_type,
          is_secured: is_secured,
          next_phase: next_phase,
          tx_hash: tx_hash
        }

        new_job = Map.update!(job, :memos, &(&1 ++ [memo]))
        bump_tx({{:ok, tx_hash}, put_job(state, job_id, new_job)})
      end)
    end)
  end

  @impl true
  def sign_memo(memo_id, approved, reason)
      when (is_binary(memo_id) or is_integer(memo_id)) and is_boolean(approved) and
             is_binary(reason) do
    Agent.get_and_update(__MODULE__, fn state ->
      tx_hash = next_tx_hash(state)
      sign = %{memo_id: memo_id, approved: approved, reason: reason, tx_hash: tx_hash}
      bump_tx({{:ok, tx_hash}, %{state | signs: [sign | state.signs]}})
    end)
  end

  @impl true
  def claim_budget(job_id) when is_binary(job_id) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)
        new_job = %{job | claimed: true}
        bump_tx({{:ok, tx_hash}, put_job(state, job_id, new_job)})
      end)
    end)
  end

  # -- Inspection --

  @spec list_jobs() :: [binary()]
  def list_jobs do
    Agent.get(__MODULE__, fn %{jobs: jobs} -> jobs |> Map.keys() |> Enum.sort() end)
  end

  @spec get_job(binary()) :: map() | nil
  def get_job(job_id) do
    Agent.get(__MODULE__, fn %{jobs: jobs} -> Map.get(jobs, job_id) end)
  end

  @spec list_signs() :: [map()]
  def list_signs do
    Agent.get(__MODULE__, fn %{signs: signs} -> Enum.reverse(signs) end)
  end

  @spec list_memos(binary()) :: [map()]
  def list_memos(job_id) do
    case get_job(job_id) do
      nil -> []
      %{memos: memos} -> memos
    end
  end

  # -- Private --

  defp with_job(state, job_id, fun) do
    case Map.get(state.jobs, job_id) do
      nil -> {{:error, {:no_such_job, job_id}}, state}
      job -> fun.(job, state)
    end
  end

  defp put_job(state, job_id, job) do
    %{state | jobs: Map.put(state.jobs, job_id, job)}
  end

  defp next_tx_hash(%{tx_counter: n}), do: "tx-#{n + 1}"

  defp bump_tx({reply, state}) do
    {reply, %{state | tx_counter: state.tx_counter + 1}}
  end
end
