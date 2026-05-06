defmodule Raxol.ACP.ContractClient.InMemory do
  @moduledoc """
  In-process implementation of `Raxol.ACP.ContractClient` for tests.

  Holds the simulated chain state in an `Agent`. Job ids and tx hashes
  are deterministic synthetic strings (`"job-1"`, `"tx-1"`, ...) so test
  assertions stay stable.

  This is NOT a mock -- it's a second real implementation of the same
  behaviour, in the spirit of `Raxol.Payments.Wallets.Env` vs
  `Raxol.Payments.Wallets.Op`. The dispatch in
  `Raxol.ACP.ContractClient.impl/0` selects which one to use.

  ## Lifecycle

  Started once by `test_helper.exs`. Every test that exercises the
  contract client should call `reset/0` in setup so prior state does
  not leak.

  ## Inspection helpers

      InMemory.list_jobs()       # all known job ids
      InMemory.get_job(job_id)   # full state for one job, or nil
      InMemory.list_memos(jid)   # memos in submission order
  """

  @behaviour Raxol.ACP.ContractClient

  use Agent

  @type state :: %{
          jobs: %{binary() => map()},
          job_counter: non_neg_integer(),
          tx_counter: non_neg_integer()
        }

  @initial_state %{jobs: %{}, job_counter: 0, tx_counter: 0}

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
  def create_job(seller, price, data) when is_binary(seller) and is_binary(data) do
    Agent.get_and_update(__MODULE__, fn %{job_counter: n, jobs: jobs} = state ->
      job_id = "job-#{n + 1}"

      job = %{
        seller: seller,
        price: price,
        data: data,
        memos: [],
        deliverable_hash: nil,
        payment_authorization: nil,
        completed: false
      }

      new_state = %{state | job_counter: n + 1, jobs: Map.put(jobs, job_id, job)}
      {{:ok, job_id}, new_state}
    end)
  end

  @impl true
  def submit_memo(job_id, type, payload, signature)
      when is_binary(job_id) and is_atom(type) and is_map(payload) and is_binary(signature) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)
        memo = %{type: type, payload: payload, signature: signature, tx_hash: tx_hash}

        new_job = Map.update!(job, :memos, &(&1 ++ [memo]))
        bump_tx({{:ok, tx_hash}, put_job(state, job_id, new_job)})
      end)
    end)
  end

  @impl true
  def complete_job(job_id, deliverable_hash)
      when is_binary(job_id) and is_binary(deliverable_hash) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)
        new_job = %{job | deliverable_hash: deliverable_hash, completed: true}
        bump_tx({{:ok, tx_hash}, put_job(state, job_id, new_job)})
      end)
    end)
  end

  @impl true
  def pay_and_accept_requirement(job_id, authorization)
      when is_binary(job_id) and is_binary(authorization) do
    Agent.get_and_update(__MODULE__, fn state ->
      with_job(state, job_id, fn job, state ->
        tx_hash = next_tx_hash(state)
        new_job = %{job | payment_authorization: authorization}
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
