defmodule Raxol.ACP.Buyer.Queue do
  @moduledoc """
  The buyer's dispatch authority -- the mirror of `Raxol.ACP.Seller.Queue`.

  Owns the client half of the ACP flow. `start_purchase/1` originates a job:
  it builds a `Raxol.ACP.JobSession.Client` from a purchase intent plus
  `Application` config, reserves the spend, writes `createJob` on-chain, and
  resolves the assigned `job_id`, then tracks the resulting client by `job_id`.
  `dispatch/1` (called by `Raxol.ACP.Buyer.Runtime`) routes the job's later
  lifecycle events to that client:

  - `:budget_set` -- the seller set the budget: `Client.on_budget_set` funds the
    escrow (asserting the budget does not exceed the reserved ceiling).
  - `:submitted` -- the seller delivered: `Client.on_submitted` evaluates and
    writes `complete`/`reject` (terminal; the client is dropped).
  - `:job_expired` -- `Client.release` refunds the reservation; drop.

  Unknown types and events for jobs we do not track drop with telemetry. Config
  is read from `Application` on every call so it can rotate without a restart.

  ## Configuration

      config :raxol_acp,
        buyer_address: "0x...",                    # this buyer's wallet (0x string)
        buyer_provider_adapter: adapter,           # Raxol.ACP.ProviderAdapter (required to write)
        buyer_chain_id: 8453,                      # chain the jobs live on (default 8453)
        buyer_acp_core_address: "0x...",           # defaults to Chain.mainnet
        buyer_agent_id: :raxol_buyer,              # ledger agent id for spend accounting
        buyer_spending_policy: %SpendingPolicy{},  # fail-closed in prod when absent
        buyer_ledger: MyLedger,                    # Raxol.Payments.Ledger server
        buyer_job_api_opts: [...],                 # Raxol.ACP.JobApi.HTTP.new/1 opts
        buyer_job_id_resolver: {mod, cfg}          # defaults to JobIdResolver.Receipt

  ## Telemetry

  - `[:raxol, :acp, :buyer, :queue, :purchased]` -- `%{job_id, offering}`.
  - `[:raxol, :acp, :buyer, :queue, :dispatched]` -- `%{type, job_id}`.
  - `[:raxol, :acp, :buyer, :queue, :dropped]` -- `%{type, job_id, reason}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.{Chain, JobApi}
  alias Raxol.ACP.JobSession.Client

  @known_types [:budget_set, :submitted, :job_expired]

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Originate a purchase. `intent` is a map with at least `:provider` (seller
  wallet) and `:amount` (an `AssetToken`); optional `:offering`, `:evaluator`,
  `:hook_address`, `:expired_at`, `:description`, `:nonce`, `:evaluate_fn`.

  Synchronous: reserves, writes `createJob`, resolves the job_id, and returns
  `{:ok, job_id}` (or `{:rejected, reason}` / `{:error, reason}`).
  """
  @spec start_purchase(map()) :: {:ok, non_neg_integer()} | {:rejected, term()} | {:error, term()}
  def start_purchase(intent) when is_map(intent) do
    GenServer.call(__MODULE__, {:start_purchase, intent})
  end

  @doc "Dispatch a lifecycle event for a tracked job. Asynchronous."
  @spec dispatch(map()) :: :ok
  def dispatch(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:dispatch, event})
  end

  @doc """
  Re-track an already-created job (used by `Raxol.ACP.Buyer.Resync` on restart).

  Builds a client from `intent` (which must carry `:job_id`, `:provider`,
  `:amount`, and an observed `:status`), starts/adopts its `JobSession` at that
  status, and stores it so later lifecycle events route to it. Does NOT write
  on-chain. The `request_key` is derived from the job identity (`nonce: job_id`)
  so it is stable across restarts. Returns `{:ok, job_id}`.
  """
  @spec adopt(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def adopt(intent) when is_map(intent) do
    GenServer.call(__MODULE__, {:adopt, intent})
  end

  @doc "Inspect the resolved defaults from `Application` config."
  @spec defaults() :: map()
  def defaults, do: read_defaults()

  # -- BaseManager callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts), do: {:ok, %{jobs: %{}}}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:start_purchase, intent}, _from, state) do
    defaults = read_defaults()

    if defaults.provider_adapter == nil do
      {:reply, {:error, :no_provider_adapter}, state}
    else
      purchase(intent, defaults, state)
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:adopt, intent}, _from, state) do
    defaults = read_defaults()
    job_id = Map.fetch!(intent, :job_id)
    status = Map.get(intent, :status, :budget_set)

    case ensure_session(defaults.chain_id, job_id, status) do
      {:ok, session} ->
        client =
          intent
          |> Map.put(:nonce, job_id)
          |> build_client(defaults)
          |> Map.merge(%{job_id: job_id, session: session})

        {:reply, {:ok, job_id}, put_job(state, job_id, client)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:dispatch, event}, state) do
    {:noreply, handle_event(event, state)}
  end

  # -- Purchase origination --

  defp purchase(intent, defaults, state) do
    client = build_client(intent, defaults)

    case Client.buy(client) do
      {:ok, client, %{job_id: job_id}} ->
        emit(:purchased, %{job_id: job_id, offering: Map.get(intent, :offering)})
        {:reply, {:ok, job_id}, put_job(state, job_id, client)}

      {:rejected, reason} ->
        emit(:dropped, %{type: :start_purchase, job_id: nil, reason: {:rejected, reason}})
        {:reply, {:rejected, reason}, state}

      {:error, reason} ->
        emit(:dropped, %{type: :start_purchase, job_id: nil, reason: reason})
        {:reply, {:error, reason}, state}
    end
  end

  # -- Event handling --

  defp handle_event(%{type: :budget_set, job_id: job_id} = event, state) do
    with_job(:budget_set, job_id, state, fn client ->
      case Client.on_budget_set(client, Map.get(event, :budget_raw)) do
        {:ok, client, _result} ->
          _ = dispatched(:budget_set, job_id)
          put_job(state, job_id, client)

        {:ok, %{idempotent: true}} ->
          _ = dispatched(:budget_set, job_id)
          state

        {:rejected, reason} ->
          drop(:budget_set, job_id, {:rejected, reason}, drop_job(state, job_id))

        {:error, reason} ->
          drop(:budget_set, job_id, reason, state)
      end
    end)
  end

  defp handle_event(%{type: :submitted, job_id: job_id} = event, state) do
    with_job(:submitted, job_id, state, fn client ->
      deliverable = Map.get(event, :deliverable, %{})

      case Client.on_submitted(client, deliverable) do
        {:ok, _client, _result} ->
          _ = dispatched(:submitted, job_id)
          drop_job(state, job_id)

        {:error, reason} ->
          drop(:submitted, job_id, reason, state)
      end
    end)
  end

  defp handle_event(%{type: :job_expired, job_id: job_id}, state) do
    with_job(:job_expired, job_id, state, fn client ->
      :ok = Client.release(client)
      _ = dispatched(:job_expired, job_id)
      drop_job(state, job_id)
    end)
  end

  # A known type reaching here is missing its `:job_id` (the typed clauses above
  # require it in the head), so the id is nil by construction -- malformed.
  defp handle_event(%{type: type}, state) when type in @known_types do
    drop(type, nil, :malformed, state)
  end

  defp handle_event(%{type: type} = event, state) do
    drop(type, Map.get(event, :job_id), :unknown_event, state)
  end

  # No `:type` key at all.
  defp handle_event(event, state) do
    drop(nil, Map.get(event, :job_id), :malformed, state)
  end

  # -- Client construction --

  defp build_client(intent, defaults) do
    Client.new(
      adapter: defaults.provider_adapter,
      api: defaults.api,
      resolver: defaults.resolver,
      chain_id: defaults.chain_id,
      acp_core_address: defaults.acp_core_address,
      buyer: defaults.buyer_address,
      provider: Map.fetch!(intent, :provider),
      evaluator: Map.get(intent, :evaluator),
      hook_address: Map.get(intent, :hook_address),
      offering: Map.get(intent, :offering),
      amount: Map.fetch!(intent, :amount),
      expired_at: Map.get(intent, :expired_at),
      description: Map.get(intent, :description),
      nonce: Map.get(intent, :nonce),
      ledger: defaults.ledger,
      policy: defaults.policy,
      agent_id: defaults.agent_id,
      checkpoint: defaults.checkpoint,
      evaluate_fn: Map.get(intent, :evaluate_fn)
    )
  end

  defp ensure_session(chain_id, job_id, status) do
    case Raxol.ACP.JobSession.Supervisor.start_session(
           chain_id: chain_id,
           job_id: job_id,
           role: :client,
           initial_status: status
         ) do
      {:ok, _pid} -> {:ok, {chain_id, job_id}}
      {:error, {:already_started, _pid}} -> {:ok, {chain_id, job_id}}
      {:error, reason} -> {:error, {:session_start_failed, reason}}
    end
  end

  # -- Defaults --

  defp read_defaults do
    %{
      buyer_address: Application.get_env(:raxol_acp, :buyer_address),
      provider_adapter: Application.get_env(:raxol_acp, :buyer_provider_adapter),
      checkpoint: Raxol.ACP.Checkpoint.store(),
      chain_id: Application.get_env(:raxol_acp, :buyer_chain_id, 8453),
      acp_core_address:
        Application.get_env(:raxol_acp, :buyer_acp_core_address) ||
          Chain.mainnet().acp_core_address,
      api: buyer_job_api(),
      resolver: buyer_resolver(),
      ledger: Application.get_env(:raxol_acp, :buyer_ledger),
      policy: Application.get_env(:raxol_acp, :buyer_spending_policy),
      agent_id: Application.get_env(:raxol_acp, :buyer_agent_id, :raxol_buyer)
    }
  end

  defp buyer_job_api do
    case Application.get_env(:raxol_acp, :buyer_job_api_opts) do
      nil -> nil
      opts when is_list(opts) -> JobApi.HTTP.new(opts)
    end
  end

  defp buyer_resolver do
    case Application.get_env(:raxol_acp, :buyer_job_id_resolver) do
      nil -> %{adapter: Raxol.ACP.JobIdResolver.Receipt}
      {module, config} when is_atom(module) -> %{adapter: module, config: config}
      %{adapter: _} = resolver -> resolver
    end
  end

  # -- Helpers --

  defp with_job(type, job_id, state, fun) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, client} -> fun.(client)
      :error -> drop(type, job_id, :job_not_tracked, state)
    end
  end

  defp put_job(state, job_id, client), do: %{state | jobs: Map.put(state.jobs, job_id, client)}
  defp drop_job(state, job_id), do: %{state | jobs: Map.delete(state.jobs, job_id)}

  defp dispatched(type, job_id) do
    emit(:dispatched, %{type: type, job_id: job_id})
    :ok
  end

  defp drop(type, job_id, reason, state) do
    emit(:dropped, %{type: type, job_id: job_id, reason: reason})
    state
  end

  defp emit(suffix, metadata) do
    :telemetry.execute([:raxol, :acp, :buyer, :queue, suffix], %{}, metadata)
  end
end
