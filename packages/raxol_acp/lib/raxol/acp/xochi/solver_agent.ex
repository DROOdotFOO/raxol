defmodule Raxol.ACP.Xochi.SolverAgent do
  @moduledoc """
  Runtime that drives a Xochi cross-chain transfer ACP job from acceptance
  through settlement, as the storefront PROVIDER.

  Subscribes to a `Raxol.ACP.Agent`, filters for plain jobs whose `provider` is
  this solver's wallet address, and runs the lifecycle:

  1. **`job.created`** -- record the job, wait for the buyer's requirement
     message.
  2. **`message` (contentType "requirement")** -- parse the requirement JSON
     against `Raxol.ACP.Xochi.Offering.requirement_schema/0` (which carries the
     buyer's signed intent bundle), compute the storefront fee (default 50 bps
     via `:fee_bps`), and propose the budget on-chain via
     `Raxol.ACP.HookClient.set_budget/6`. This is a PLAIN job (hook =
     `address(0)`), so `set_budget` carries no hook data -- the budget is the
     storefront fee, not the transfer. The transfer moves through Xochi
     off-escrow, so the ACP core's take never bites it.
  3. **`budget.set`** (echoed back via SSE) -- no-op for the solver; observe.
  4. **`job.funded`** -- run `settle_fn` (default: a `Raxol.ACP.Xochi.Settler`
     relay) which relays the buyer's pre-signed intent through Xochi and, on
     success, submits the deliverable (the settlement tx hashes) on-chain.
  5. **`job.completed`** -- provider nets `budget*0.90`. Cleanup local state.

  ## Configuration

      Raxol.ACP.Xochi.SolverAgent.start_link(
        agent: my_acp_agent,
        provider: my_provider_adapter,
        wallet_address: "0xfeed...",
        evaluator_address: "0xevaluator...",
        chain_id: 8453,
        acp_core_address: "0x238E541BfefD82238730D00a2208E5497F1832E0",
        fee_bps: 50,
        settle_fn: Raxol.ACP.Xochi.Settler.build(xochi_config: %{base_url: "..."})
      )

  ## Sessions

  One internal `session_state()` per active job. Stored in process
  state keyed by `{chain_id, job_id}`. State machine:

      :awaiting_requirement -> :budget_proposed -> :awaiting_fund
        -> :settling -> :submitted -> :completed

  ## Telemetry

  Emits `[:raxol, :acp, :xochi, :solver, :event]` on every entry it
  acts on, with metadata `%{chain_id, job_id, event, action}`.
  """

  use GenServer

  alias Raxol.ACP.{Agent, HookClient}
  alias Raxol.ACP.Xochi.Offering

  @type session_status ::
          :awaiting_requirement
          | :budget_proposed
          | :awaiting_fund
          | :settling
          | :submitted
          | :completed
          | :rejected
          | :failed

  @type session_state :: %{
          required(:job_id) => String.t() | non_neg_integer(),
          required(:chain_id) => pos_integer(),
          required(:status) => session_status(),
          required(:job_id_uint) => non_neg_integer(),
          optional(:requirement) => map(),
          optional(:budget_atomic) => non_neg_integer(),
          optional(:transfer_amount_atomic) => non_neg_integer(),
          optional(:deliverable) => map(),
          optional(:settle_tx_hashes) => map()
        }

  @type t :: %__MODULE__{
          agent: pid() | atom(),
          provider: Raxol.ACP.ProviderAdapter.adapter(),
          wallet_address: String.t(),
          evaluator_address: String.t(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          fee_bps: non_neg_integer(),
          settle_fn: fun(),
          xochi_config: map(),
          sessions: %{Raxol.ACP.Transport.job_key() => session_state()}
        }

  defstruct [
    :agent,
    :provider,
    :wallet_address,
    :evaluator_address,
    :chain_id,
    :acp_core_address,
    :xochi_config,
    settle_fn: nil,
    fee_bps: 50,
    sessions: %{}
  ]

  # -- Public API --

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Return the current per-session state map."
  @spec sessions(GenServer.server()) :: map()
  def sessions(server), do: GenServer.call(server, :sessions)

  @doc "Return the state for a specific `{chain_id, job_id}` key, or nil."
  @spec session(GenServer.server(), Raxol.ACP.Transport.job_key()) ::
          session_state() | nil
  def session(server, key), do: GenServer.call(server, {:session, key})

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      agent: Keyword.fetch!(opts, :agent),
      provider: Keyword.fetch!(opts, :provider),
      wallet_address: normalize_address(Keyword.fetch!(opts, :wallet_address)),
      evaluator_address: Keyword.fetch!(opts, :evaluator_address),
      chain_id: Keyword.fetch!(opts, :chain_id),
      acp_core_address: Keyword.fetch!(opts, :acp_core_address),
      fee_bps: Keyword.get(opts, :fee_bps, 50),
      settle_fn: Keyword.get(opts, :settle_fn, &default_settle/1),
      xochi_config: Keyword.get(opts, :xochi_config, %{})
    }

    :ok = Agent.subscribe(state.agent)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  def handle_call({:session, key}, _from, state) do
    {:reply, Map.get(state.sessions, key), state}
  end

  @impl GenServer
  def handle_info({Raxol.ACP.Agent, _agent_pid, session_pid, entry}, state) do
    {:noreply, dispatch(entry, session_pid, state)}
  end

  # Ignore anything we don't recognise.
  def handle_info(_msg, state), do: {:noreply, state}

  # -- Dispatch --

  defp dispatch(%{"kind" => "system", "event" => "job.created"} = entry, _session, state) do
    handle_job_created(entry, state)
  end

  defp dispatch(%{"kind" => "system", "event" => "job.funded"} = entry, _session, state) do
    handle_job_funded(entry, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.completed"} = entry,
         _session,
         state
       ) do
    handle_job_completed(entry, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.rejected"} = entry,
         _session,
         state
       ) do
    finalize(entry, :rejected, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.expired"} = entry,
         _session,
         state
       ) do
    finalize(entry, :failed, state)
  end

  defp dispatch(%{"kind" => "message", "contentType" => "requirement"} = entry, _session, state) do
    handle_requirement(entry, state)
  end

  defp dispatch(_entry, _session, state), do: state

  # -- Handlers --

  defp handle_job_created(entry, state) do
    key = job_key(entry)
    job_id_uint = parse_job_id(entry["jobId"])

    # Filter: only act on jobs where we're the provider.
    if interested?(entry, state) do
      session = %{
        job_id: entry["jobId"],
        chain_id: entry["chainId"],
        job_id_uint: job_id_uint,
        status: :awaiting_requirement
      }

      emit(state, key, :job_created, :await_requirement)
      put_session(state, key, session)
    else
      state
    end
  end

  defp handle_requirement(entry, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, %{status: :awaiting_requirement} = session} ->
        case decode_requirement(entry["content"]) do
          {:ok, req} ->
            propose_budget(state, key, session, req)

          {:error, reason} ->
            emit(state, key, :requirement_error, reason)
            put_session(state, key, %{session | status: :failed})
        end

      _ ->
        state
    end
  end

  # Settle only the session the funded event names. A single job.funded must
  # never fan-settle every pending session -- doing so spends real funds via
  # settle/3 for jobs that were not funded.
  defp handle_job_funded(entry, state) do
    case settle_target(state.sessions, job_key(entry)) do
      {:ok, key, session} -> settle(state, key, session)
      :none -> state
    end
  end

  @doc false
  # Pure routing decision behind `handle_job_funded/2`: a funded event settles
  # the session at its own `{chain_id, job_id}` and only when that session is
  # awaiting funding. Any other key -- absent, or in a non-fundable state --
  # returns `:none`. Selecting anything but the named key would re-open the
  # fan-settle hole. Exposed for property tests.
  @spec settle_target(%{optional(Raxol.ACP.Transport.job_key()) => session_state()}, term()) ::
          {:ok, Raxol.ACP.Transport.job_key(), session_state()} | :none
  def settle_target(sessions, key) do
    case Map.fetch(sessions, key) do
      {:ok, %{status: status} = session} when status in [:budget_proposed, :awaiting_fund] ->
        {:ok, key, session}

      _ ->
        :none
    end
  end

  defp handle_job_completed(entry, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, session} ->
        emit(state, key, :job_completed, :ok)
        put_session(state, key, %{session | status: :completed})

      :error ->
        state
    end
  end

  defp finalize(entry, status, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, session} ->
        emit(state, key, status, :ok)
        put_session(state, key, %{session | status: status})

      :error ->
        state
    end
  end

  # -- Budget proposal --

  @doc false
  # The ACP job budget is the storefront fee only -- `fee_bps` basis points of
  # the transfer amount. The transfer itself flows through Xochi (a buyer-signed
  # intent the storefront relays), NOT through the ACP escrow, so the escrow is
  # never sized to the transfer -- putting the transfer through the escrow would
  # incur the core's 5-10% take on the full amount. Exposed for property tests.
  @spec budget_for(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def budget_for(transfer_atomic, fee_bps)
      when is_integer(transfer_atomic) and transfer_atomic >= 0 and
             is_integer(fee_bps) and fee_bps >= 0 do
    div(transfer_atomic * fee_bps, 10_000)
  end

  # A storefront job is a PLAIN job (hook = address(0)): `set_budget` carries no
  # hook data. The budget is the storefront fee; the transfer settles through
  # Xochi off-escrow, so no FundTransfer hook is involved.
  defp propose_budget(state, key, session, requirement) do
    transfer_atomic = String.to_integer(requirement["amount_atomic"])
    budget_atomic = budget_for(transfer_atomic, state.fee_bps)

    case HookClient.set_budget(
           state.provider,
           state.chain_id,
           state.acp_core_address,
           session.job_id_uint,
           budget_atomic
         ) do
      {:ok, tx_hash} ->
        emit(state, key, :budget_proposed, %{tx_hash: tx_hash, budget_atomic: budget_atomic})

        updated =
          session
          |> Map.put(:status, :budget_proposed)
          |> Map.put(:requirement, requirement)
          |> Map.put(:budget_atomic, budget_atomic)
          |> Map.put(:transfer_amount_atomic, transfer_atomic)

        put_session(state, key, updated)

      {:error, reason} ->
        emit(state, key, :budget_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  # -- Settlement --

  defp settle(state, key, session) do
    session = %{session | status: :settling}
    state = put_session(state, key, session)
    emit(state, key, :settling, :start)

    case state.settle_fn.(%{
           requirement: session.requirement,
           signed_intent: session.requirement["signed_intent"],
           transfer_amount_atomic: session.transfer_amount_atomic
         }) do
      {:ok, %{intent_id: intent_id} = deliverable} ->
        submit_deliverable(state, key, session, deliverable, intent_id)

      {:error, reason} ->
        emit(state, key, :settle_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  defp submit_deliverable(state, key, session, deliverable, intent_id) do
    deliverable_hash = compute_deliverable_hash(deliverable)

    case HookClient.submit(
           state.provider,
           state.chain_id,
           state.acp_core_address,
           session.job_id_uint,
           deliverable_hash
         ) do
      {:ok, tx_hash} ->
        emit(state, key, :submitted, %{tx_hash: tx_hash, intent_id: intent_id})

        session =
          session
          |> Map.put(:status, :submitted)
          |> Map.put(:deliverable, deliverable)
          |> Map.put(:settle_tx_hashes, %{
            submit: tx_hash,
            intent_id: intent_id
          })

        put_session(state, key, session)

      {:error, reason} ->
        emit(state, key, :submit_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  # -- Default settle (test-only) --

  # In production, callers pass a `Raxol.ACP.Xochi.Settler` relay closure via
  # :settle_fn. The default below produces a deterministic stub so the
  # SolverAgent can be exercised in tests without a live Xochi server.
  defp default_settle(%{requirement: req, transfer_amount_atomic: _}) do
    {:ok,
     %{
       intent_id: ("stub-intent-" <> :erlang.unique_integer([:positive])) |> to_string(),
       quote_id: "stub-quote",
       settlement_tx_hash: "0x" <> String.duplicate("a", 64),
       receiving_tx_hash: "0x" <> String.duplicate("b", 64),
       status: "settled",
       fee_atomic: "0",
       dst_amount_atomic: req["amount_atomic"]
     }}
  end

  # -- Helpers --

  defp interested?(entry, state) do
    job_provider =
      entry["provider"] ||
        get_in(entry, ["payload", "provider"]) ||
        get_in(entry, ["data", "provider"])

    case job_provider do
      nil -> false
      addr -> normalize_address(addr) == state.wallet_address
    end
  end

  defp decode_requirement(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, req} when is_map(req) ->
        if Offering.valid_requirement?(req), do: {:ok, req}, else: {:error, :invalid_requirement}

      _ ->
        {:error, :requirement_not_json}
    end
  end

  defp decode_requirement(_), do: {:error, :requirement_missing}

  defp parse_job_id(id) when is_integer(id), do: id

  defp parse_job_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> :erlang.phash2(id)
    end
  end

  defp job_key(entry) do
    {entry["chainId"], entry["jobId"]}
  end

  defp compute_deliverable_hash(deliverable) do
    deliverable
    |> Jason.encode!()
    |> ExKeccak.hash_256()
  end

  defp put_session(state, key, session) do
    %{state | sessions: Map.put(state.sessions, key, session)}
  end

  defp normalize_address(addr) when is_binary(addr), do: String.downcase(addr)

  defp emit(_state, key, event, payload) do
    :telemetry.execute(
      [:raxol, :acp, :xochi, :solver, :event],
      %{},
      %{key: key, event: event, payload: payload}
    )
  end
end
