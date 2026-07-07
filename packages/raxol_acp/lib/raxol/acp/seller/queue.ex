defmodule Raxol.ACP.Seller.Queue do
  @moduledoc """
  Routes ACP backend events to `Raxol.ACP.JobSession`s, driving each as the
  seller PROVIDER via `Raxol.ACP.JobSession.Provider`.

  The Queue is a single GenServer that owns the dispatch policy for the seller.
  Backend events arrive via `dispatch/1` (called by `Raxol.ACP.Seller.Runtime`
  after it receives an `{:acp_event, event}` message). For each event the Queue
  invokes the offering `Handler`, writes the matching hook call on-chain through
  `Raxol.ACP.HookClient` + the configured `Raxol.ACP.ProviderAdapter`, and
  mirrors the resulting status into the job's `JobSession`.

  ## Configuration

      config :raxol_acp,
        seller_address: "0x...",                 # 0x string, surfaced in handler ctx
        seller_max_active_jobs: 100,              # backpressure cap (default 100)
        seller_provider_adapter: adapter,         # a Raxol.ACP.ProviderAdapter (required to write on-chain)
        seller_chain_id: 8453,                    # chain the jobs live on (default 8453)
        seller_acp_core_address: "0x..."          # ACP v2 core; defaults to Chain.mainnet

  Read from `Application` on every dispatch so config can be rotated without
  restarting the supervision tree.

  ## Backpressure

  A `:job_offered` starts a supervised `JobSession`, so an unbounded stream of
  offers is an unbounded stream of processes. The Queue caps concurrent sessions
  at `:seller_max_active_jobs`: once the cap is reached, further offers drop with
  reason `:at_capacity`. Events for jobs already in flight are never capped.

  ## Events handled (v1 backend shapes -> v2 statuses)

  - `:job_offered` -- start a `JobSession(:provider)`, then
    `Provider.accept_request` (`handle_request` -> `setBudget` on-chain -> mirror
    `:budget_set`). A handler `reject` expires the session.
  - `:payment_received` -- the client funded: mirror `:funded`, then
    `Provider.deliver` (`handle_deliver` -> `submit` on-chain -> mirror
    `:submitted`).
  - `:approval_received` -- the external evaluator approved: mirror `:completed`
    (terminal; the session stops).
  - `:job_expired` -- mirror `:expired`.

  Unknown types and events for unknown job_ids drop with telemetry.

  ## Telemetry

  - `[:raxol, :acp, :seller, :queue, :dispatched]` -- successful dispatch.
    Metadata: `%{type, job_id, offering}`.
  - `[:raxol, :acp, :seller, :queue, :dropped]` -- event dropped. Metadata:
    `%{type, job_id, reason}` where reason is one of `:offering_not_registered`,
    `:job_not_running`, `:no_provider_adapter`, `:start_failed`, `:at_capacity`,
    `:malformed`, `:unknown_event`, `{:rejected, reason}`, or
    `{:handler_error, reason}`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.{Chain, JobSession}
  alias Raxol.ACP.AssetToken
  alias Raxol.ACP.JobSession.Provider
  alias Raxol.ACP.Offering.Registry, as: OfferingRegistry

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dispatch a backend event. Asynchronous: returns `:ok` immediately and the
  Queue processes the event in its mailbox. A malformed event is dropped with
  telemetry inside the Queue rather than crashing the caller.
  """
  @spec dispatch(map()) :: :ok
  def dispatch(event) when is_map(event) do
    GenServer.cast(__MODULE__, {:dispatch, event})
  end

  @doc "Inspect the Queue's currently resolved defaults from Application config."
  @spec defaults() :: map()
  def defaults, do: read_defaults()

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts), do: {:ok, %{jobs: %{}}}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:dispatch, event}, state) do
    {:noreply, handle_event(event, state, read_defaults())}
  end

  defp read_defaults do
    %{
      seller_address: Application.get_env(:raxol_acp, :seller_address),
      max_active_jobs: Application.get_env(:raxol_acp, :seller_max_active_jobs, 100),
      provider_adapter: Application.get_env(:raxol_acp, :seller_provider_adapter),
      chain_id: Application.get_env(:raxol_acp, :seller_chain_id, 8453),
      acp_core_address:
        Application.get_env(:raxol_acp, :seller_acp_core_address) ||
          Chain.mainnet().acp_core_address
    }
  end

  # -- Event handlers --
  #
  # Each clause requires the keys it needs in the head, so a malformed backend
  # event drops with telemetry instead of crashing the Queue. Handler and
  # on-chain-write failures drop with a specific reason rather than being
  # reported as a successful dispatch.

  @known_types [:job_offered, :payment_received, :approval_received, :job_expired]

  defp handle_event(
         %{type: :job_offered, job_id: job_id, offering: name} = event,
         state,
         defaults
       ) do
    cond do
      defaults.provider_adapter == nil ->
        drop(:job_offered, job_id, %{offering: name}, :no_provider_adapter, state)

      not offering_registered?(name) ->
        drop(:job_offered, job_id, %{offering: name}, :offering_not_registered, state)

      not within_capacity?(defaults) ->
        drop(:job_offered, job_id, %{offering: name}, :at_capacity, state)

      true ->
        offer(event, name, state, defaults)
    end
  end

  defp handle_event(%{type: :payment_received, job_id: job_id} = event, state, _defaults) do
    with_job(:payment_received, job_id, state, fn %{provider: provider, request: request} ->
      JobSession.apply_event(provider.session, :funded, %{payment: Map.get(event, :payload)})

      case Provider.deliver(provider, request) do
        {:ok, _} -> dispatched(:payment_received, job_id, state)
        {:error, reason} -> drop(:payment_received, job_id, %{}, {:handler_error, reason}, state)
      end
    end)
  end

  defp handle_event(%{type: :approval_received, job_id: job_id} = event, state, _defaults) do
    with_job(:approval_received, job_id, state, fn %{provider: provider} ->
      # External evaluator approved on-chain; mirror the terminal status. The
      # session stops itself; drop our context.
      JobSession.apply_event(provider.session, :completed, %{approval: Map.get(event, :payload)})
      _ = dispatched(:approval_received, job_id, state)
      drop_job(state, job_id)
    end)
  end

  defp handle_event(%{type: :job_expired, job_id: job_id} = event, state, _defaults) do
    with_job(:job_expired, job_id, state, fn %{provider: provider} ->
      reason = Map.get(event, :reason, "expired")
      JobSession.apply_event(provider.session, :expired, %{reason: inspect(reason)})
      _ = dispatched(:job_expired, job_id, state)
      drop_job(state, job_id)
    end)
  end

  # A known type reaching here is missing a required field -- malformed.
  defp handle_event(%{type: type} = event, state, _defaults) when type in @known_types do
    drop(type, Map.get(event, :job_id), %{}, :malformed, state)
  end

  defp handle_event(%{type: type} = event, state, _defaults) do
    drop(type, Map.get(event, :job_id), %{}, :unknown_event, state)
  end

  defp handle_event(event, state, _defaults) do
    drop(Map.get(event, :type), Map.get(event, :job_id), %{}, :malformed, state)
  end

  # -- job_offered --

  defp offer(%{job_id: job_id} = event, name, state, defaults) do
    request = Map.get(event, :request, %{})

    case start_session(job_id, defaults) do
      {:ok, session} ->
        {:ok, spec} = OfferingRegistry.lookup(name)
        provider = build_provider(session, spec, event, defaults, job_id)
        budget = AssetToken.usdc(spec.price_usdc, defaults.chain_id)

        case Provider.accept_request(provider, request, budget) do
          {:ok, _} ->
            emit(:dispatched, %{type: :job_offered, job_id: job_id, offering: name})
            put_job(state, job_id, %{provider: provider, request: request})

          {:rejected, reason} ->
            JobSession.apply_event(session, :expired, %{rejected: reason})
            drop(:job_offered, job_id, %{offering: name}, {:rejected, reason}, state)

          {:error, reason} ->
            drop(:job_offered, job_id, %{offering: name}, {:handler_error, reason}, state)
        end

      {:error, reason} ->
        drop(:job_offered, job_id, %{offering: name}, {:start_failed, reason}, state)
    end
  end

  # -- Helpers --

  defp with_job(type, job_id, state, fun) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, ctx} -> fun.(ctx)
      :error -> drop(type, job_id, %{}, :job_not_running, state)
    end
  end

  defp start_session(job_id, defaults) do
    case JobSession.Supervisor.start_session(
           chain_id: defaults.chain_id,
           job_id: job_id,
           role: :provider
         ) do
      {:ok, _pid} -> {:ok, {defaults.chain_id, job_id}}
      {:error, {:already_started, _pid}} -> {:ok, {defaults.chain_id, job_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_provider(session, spec, event, defaults, job_id) do
    Provider.new(
      session: session,
      handler: spec.handler,
      adapter: defaults.provider_adapter,
      chain_id: defaults.chain_id,
      acp_core_address: defaults.acp_core_address,
      job_id: parse_job_id(job_id),
      buyer: Map.get(event, :buyer),
      seller: defaults.seller_address
    )
  end

  # HookClient needs a numeric jobId; the backend id may be a string. A
  # non-numeric id hashes to a stable integer (fine for tests / off-chain).
  defp parse_job_id(id) when is_integer(id), do: id

  defp parse_job_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> :erlang.phash2(id)
    end
  end

  defp offering_registered?(name) do
    match?({:ok, _spec}, OfferingRegistry.lookup(name))
  end

  # Backpressure: cap concurrent JobSessions. Events for jobs already in flight
  # (payment/approval/expiry) are never capped -- only fresh offers.
  defp within_capacity?(%{max_active_jobs: max}) do
    DynamicSupervisor.count_children(JobSession.Supervisor).active < max
  end

  defp put_job(state, job_id, ctx), do: %{state | jobs: Map.put(state.jobs, job_id, ctx)}
  defp drop_job(state, job_id), do: %{state | jobs: Map.delete(state.jobs, job_id)}

  defp dispatched(type, job_id, state) do
    emit(:dispatched, %{type: type, job_id: job_id})
    state
  end

  defp drop(type, job_id, extra, reason, state) do
    emit(:dropped, Map.merge(extra, %{type: type, job_id: job_id, reason: reason}))
    state
  end

  defp emit(suffix, metadata) do
    :telemetry.execute([:raxol, :acp, :seller, :queue, suffix], %{}, metadata)
  end
end
