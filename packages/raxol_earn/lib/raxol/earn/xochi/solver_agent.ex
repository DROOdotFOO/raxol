defmodule Raxol.Earn.Xochi.SolverAgent do
  @moduledoc """
  Runtime that drives a Xochi cross-chain transfer ACP job from acceptance
  through settlement, as the storefront PROVIDER.

  Subscribes to a `Raxol.Earn.Agent`, filters for plain jobs whose `provider` is
  this solver's wallet address, and runs the lifecycle:

  1. **`job.created`** -- record the job, wait for the buyer's requirement
     message.
  2. **`message` (contentType "requirement")** -- parse the requirement JSON
     against `Raxol.Earn.Xochi.Offering.requirement_schema/0` (which carries the
     buyer's signed intent bundle), compute the storefront fee (default 8 bps
     via `:fee_bps`), and propose the budget on-chain via
     `Raxol.Earn.HookClient.set_budget/6`. This is a PLAIN job (hook =
     `address(0)`), so `set_budget` carries no hook data -- the budget is the
     storefront fee, not the transfer. The transfer moves through Xochi
     off-escrow, so the ACP core's take never bites it.
  3. **`budget.set`** (echoed back via SSE) -- no-op for the solver; observe.
  4. **`job.funded`** -- run `settle_fn` (default: a `Raxol.Earn.Xochi.Settler`
     relay) which relays the buyer's pre-signed intent through Xochi and, on
     success, submits the deliverable (the settlement tx hashes) on-chain.
  5. **`job.completed`** -- provider nets `budget*0.90`. Cleanup local state.

  ## Configuration

      Raxol.Earn.Xochi.SolverAgent.start_link(
        agent: my_acp_agent,
        provider: my_provider_adapter,
        wallet_address: "0xfeed...",
        evaluator_address: "0xevaluator...",
        chain_id: 8453,
        acp_core_address: "0x238E541BfefD82238730D00a2208E5497F1832E0",
        fee_bps: 8,
        settle_fn: Raxol.Earn.Xochi.Settler.build(xochi_config: %{base_url: "..."})
      )

  ## Sessions

  One internal `session_state()` per active job. Stored in process
  state keyed by `{chain_id, job_id}`. State machine:

      :awaiting_requirement -> :budget_proposed -> :awaiting_fund
        -> :settling -> :submitted -> :completed

  ## Telemetry

  Emits `[:raxol, :earn, :xochi, :solver, :event]` on every entry it
  acts on, with metadata `%{chain_id, job_id, event, action}`.
  """

  use GenServer

  require Logger

  alias Raxol.Earn.{Agent, HookClient, ProviderAdapter}
  alias Raxol.Earn.Transport.SSE.Parser
  alias Raxol.Earn.Xochi.{IntentDeriver, Offering}
  alias Raxol.Payments.Assets

  # On-chain AgenticCommerceV3 JobStatus for a funded job. Verified on Base
  # mainnet (job 70759: `getJob().status == 1` once funded). The memoryless
  # reattach path settles only at exactly this status.
  @onchain_status_funded 1

  # The smallest fee worth escrowing, in the ACP payment token's base units.
  # `budget_for/2` truncates through `div/2`, so below this a fee that was meant
  # to be charged has rounded away to an escrow that can never pay.
  @default_min_fee_atomic 1

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
          provider: Raxol.Earn.ProviderAdapter.adapter(),
          wallet_address: String.t(),
          evaluator_address: String.t(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          fee_bps: non_neg_integer(),
          min_fee_atomic: non_neg_integer(),
          settle_fn: fun(),
          history_fn:
            (Raxol.Earn.Transport.job_key() ->
               {:ok, [map()]} | {:error, term()})
            | nil,
          xochi_config: map(),
          sessions: %{Raxol.Earn.Transport.job_key() => session_state()}
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
    history_fn: nil,
    fee_bps: 8,
    min_fee_atomic: 1,
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
  @spec session(GenServer.server(), Raxol.Earn.Transport.job_key()) ::
          session_state() | nil
  def session(server, key), do: GenServer.call(server, {:session, key})

  # -- GenServer callbacks --

  @impl GenServer
  def init(opts) do
    case validate_min_fee(configured_min_fee(opts)) do
      {:ok, min_fee_atomic} -> start_solver(opts, min_fee_atomic)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp configured_min_fee(opts) do
    Keyword.get_lazy(opts, :min_fee_atomic, fn ->
      Application.get_env(:raxol_earn, :solver_min_fee_atomic, @default_min_fee_atomic)
    end)
  end

  defp start_solver(opts, min_fee_atomic) do
    state = %__MODULE__{
      agent: Keyword.fetch!(opts, :agent),
      provider: Keyword.fetch!(opts, :provider),
      wallet_address: normalize_address(Keyword.fetch!(opts, :wallet_address)),
      evaluator_address: Keyword.fetch!(opts, :evaluator_address),
      chain_id: Keyword.fetch!(opts, :chain_id),
      acp_core_address: Keyword.fetch!(opts, :acp_core_address),
      fee_bps: Keyword.get(opts, :fee_bps, 8),
      min_fee_atomic: min_fee_atomic,
      settle_fn: Keyword.get(opts, :settle_fn, &default_settle/1),
      history_fn: Keyword.get(opts, :history_fn),
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
  def handle_info({Raxol.Earn.Agent, _agent_pid, session_pid, entry}, state) do
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
      Logger.info("[xochi.solver] accepted job.created key=#{inspect(key)}; awaiting requirement")
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
    key = job_key(entry)
    live_status = live_session_status(state, key)

    emit(state, key, :job_funded, %{session_status: live_status})

    Logger.info(
      "[xochi.solver] job.funded key=#{inspect(key)} live_session=#{inspect(live_status)}"
    )

    case settle_target(state.sessions, key) do
      {:ok, key, session} ->
        settle(state, key, session)

      :none ->
        # No settleable in-memory session. If the solver restarted between
        # setBudget and fund (deploy/reschedule), the session is gone and the
        # live-only SSE stream never replays the earlier entries -- so without a
        # reattach the funded job stays stuck forever (issue #772). Rebuild from
        # job history and settle. A session that exists but is NOT fundable
        # (already settling/submitted/completed/failed) is a duplicate/late
        # funded event and is left untouched.
        if live_status == :absent do
          reattach_and_settle(entry, key, state)
        else
          Logger.info(
            "[xochi.solver] job.funded ignored for #{inspect(key)} (session #{inspect(live_status)})"
          )

          state
        end
    end
  end

  defp live_session_status(state, key) do
    case Map.fetch(state.sessions, key) do
      {:ok, %{status: status}} -> status
      :error -> :absent
    end
  end

  # Rebuild the lost session from the ACP job history and settle it. The history
  # (fetched off the Virtuals server) is authoritative: it carries the original
  # `job.created` (confirming this solver is the provider) and the buyer's
  # `requirement` message (carrying the signed intent bundle we relay). Before
  # spending, it independently confirms on-chain that the job is actually funded
  # (`confirm_funded_onchain/3`). Fails closed and stays silent on-chain if any of
  # that can't be recovered, the job isn't ours, or it isn't funded on-chain --
  # reattach never invents a settlement.
  defp reattach_and_settle(entry, key, state) do
    Logger.info("[xochi.solver] no live session for #{inspect(key)}; reattaching from history")

    with {:ok, session} <- rebuild_session(entry, key, state),
         :ok <- confirm_funded_onchain(state, key, session) do
      emit(state, key, :reattached, :from_history)
      Logger.info("[xochi.solver] reattached #{inspect(key)} from history; settling")
      settle(put_session(state, key, session), key, session)
    else
      {:error, reason} ->
        emit(state, key, :reattach_failed, reason)
        Logger.warning("[xochi.solver] reattach aborted for #{inspect(key)}: #{inspect(reason)}")
        state
    end
  end

  # Defense-in-depth for the memoryless reattach path: `job.funded` is the trusted
  # SSE trigger, but reattach fires for a job this process has no record of, so
  # before settle/3 spends real funds it reads `getJob(jobId).status` on-chain and
  # proceeds only when it is EXACTLY `funded`. A status below funded means the
  # event was premature; a status past funded (submitted/completed) means the job
  # was already settled -- both fail closed. An unreadable status fails closed too.
  # The in-memory happy path (a live :budget_proposed/:awaiting_fund session) does
  # not run this and is unchanged.
  defp confirm_funded_onchain(state, key, %{job_id_uint: job_id_uint}) do
    case job_status_onchain(state, job_id_uint) do
      {:ok, @onchain_status_funded} ->
        :ok

      {:ok, other} ->
        Logger.warning(
          "[xochi.solver] reattach #{inspect(key)}: on-chain status #{inspect(other)} != funded; not settling"
        )

        {:error, {:not_funded_onchain, other}}

      {:error, reason} ->
        {:error, {:job_status_unavailable, reason}}
    end
  end

  # Read `getJob(jobId).status` off the ACP Core via the provider's eth_call seam.
  defp job_status_onchain(state, job_id_uint) do
    params = %{
      address: state.acp_core_address,
      signature: "getJob(uint256)",
      args: [{"uint256", job_id_uint}]
    }

    with {:ok, raw} <- ProviderAdapter.read_contract(state.provider, state.chain_id, params) do
      decode_job_status(raw)
    end
  end

  # getJob(uint256) -> (client, status, provider, expiredAt, evaluator, hook,
  # budget, description): a dynamic-struct return, so a leading offset word
  # precedes the head. `status` is head field 1, i.e. word index 2 overall --
  # skip the offset word + `client`. An integer is accepted for a canned mock read.
  defp decode_job_status(status) when is_integer(status) and status >= 0, do: {:ok, status}

  defp decode_job_status("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(2 * 32), status::unsigned-big-integer-size(256), _::binary>>} ->
        {:ok, status}

      _ ->
        {:error, :undecodable_job_status}
    end
  end

  defp decode_job_status(other), do: {:error, {:unexpected_job_status, other}}

  defp rebuild_session(entry, key, state) do
    with {:ok, entries} <- fetch_history(state, key),
         normalized = Enum.map(entries, &Parser.normalize/1),
         :ok <- confirm_provider(normalized, state),
         {:ok, requirement} <- requirement_from_history(normalized),
         {:ok, %{from_amount: transfer_atomic}} <-
           IntentDeriver.resolve(state.xochi_config, requirement) do
      {:ok, reattached_session(entry, key, requirement, transfer_atomic)}
    else
      # IntentDeriver returns {:reject, _} | {:error, _}; the history seams return
      # {:error, _}. Normalize all to {:error, reason} so reattach fails closed.
      {_reject_or_error, reason} ->
        {:error, reason}
    end
  end

  defp reattached_session(entry, {chain_id, job_id}, requirement, transfer_atomic) do
    id = entry["jobId"] || job_id

    %{
      job_id: id,
      chain_id: entry["chainId"] || chain_id,
      job_id_uint: parse_job_id(id),
      status: :awaiting_fund,
      requirement: requirement,
      transfer_amount_atomic: transfer_atomic
    }
  end

  defp fetch_history(%{history_fn: history_fn}, key) when is_function(history_fn, 1) do
    history_fn.(key)
  end

  defp fetch_history(state, key), do: Agent.get_history(state.agent, key)

  # Only settle a job whose recorded provider is this solver -- reattach must not
  # spend on a job we never accepted. The provider is read from the historical
  # `job.created` entry (authoritative), not the funded event, which may not
  # carry it.
  defp confirm_provider(entries, state) do
    created =
      Enum.find(entries, fn
        %{"kind" => "system", "event" => "job.created"} -> true
        _ -> false
      end)

    case created do
      %{"provider" => provider} when is_binary(provider) ->
        if normalize_address(provider) == state.wallet_address,
          do: :ok,
          else: {:error, :not_our_job}

      _ ->
        {:error, :no_created_in_history}
    end
  end

  # The buyer's requirement (carrying the signed intent bundle) is the last
  # valid `requirement` message in the history.
  defp requirement_from_history(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"kind" => "message", "contentType" => "requirement", "content" => content} ->
        case decode_requirement(content) do
          {:ok, requirement} -> {:ok, requirement}
          {:error, _} -> nil
        end

      _ ->
        nil
    end)
    |> case do
      {:ok, requirement} -> {:ok, requirement}
      nil -> {:error, :no_requirement_in_history}
    end
  end

  @doc false
  # Pure routing decision behind `handle_job_funded/2`: a funded event settles
  # the session at its own `{chain_id, job_id}` and only when that session is
  # awaiting funding. Any other key -- absent, or in a non-fundable state --
  # returns `:none`. Selecting anything but the named key would re-open the
  # fan-settle hole. Exposed for property tests.
  @spec settle_target(%{optional(Raxol.Earn.Transport.job_key()) => session_state()}, term()) ::
          {:ok, Raxol.Earn.Transport.job_key(), session_state()} | :none
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
  #
  # The fee is sized on the AUTHORITATIVE amount the buyer signed -- read from
  # Xochi by the intent id, never the relayed `amount_atomic` a buyer could
  # understate (`IntentDeriver`). Fails the job closed if the intent can't be
  # resolved rather than proposing a budget on an untrusted number.
  defp propose_budget(state, key, session, requirement) do
    with {:ok, %{intent: intent, from_amount: transfer_atomic}} <-
           IntentDeriver.resolve(state.xochi_config, requirement),
         {:ok, budget_atomic} <- fee_budget(state, intent, transfer_atomic) do
      set_budget(state, key, session, requirement, transfer_atomic, budget_atomic)
    else
      {reject_or_error, reason} when reject_or_error in [:reject, :error] ->
        emit(state, key, :requirement_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  # The budget is `fee_bps` of the intent's `from_amount`, escrowed as the ACP
  # payment token (USDC, 6dp). `from_amount` is denominated in the ORIGIN token's
  # base units, so that arithmetic only means anything when the origin leg is
  # itself a 6dp USD stablecoin.
  #
  # Rescaling by decimals cannot rescue a non-stablecoin: 1 WETH is 1e18 base
  # units, and reading that as 1e6-scaled USDC understates the fee by roughly the
  # ETH price. Sizing this correctly needs a price oracle, so until there is one
  # the sound answer is to refuse the corridor rather than escrow a wrong number.
  #
  # An unregistered token is refused for the same reason: `Assets.decimals/2`
  # answers 6 for anything it does not know, so an unlisted 18dp token would
  # silently size a budget ~1e12 times too small.
  #
  # The USDC public offering gates both legs to USDC and is unaffected; this is
  # the generic `xochi_cross_chain_transfer` path, which gates nothing. See #666.
  @fee_base_symbols ~w(USDC USDT USDG)

  # The scale the fee arithmetic assumes, asserted rather than trusted. Every
  # registered @fee_base_symbols token is 6dp on every corridor chain today, so
  # the symbol check alone happens to be right -- but the argument above is about
  # DECIMALS, and a symbol is only a proxy for them. Registering an 18dp variant
  # under one of these symbols would pass a symbol-only gate and size a budget
  # ~1e12 too small. The symbol check still has to come first: `Assets.decimals/2`
  # answers 6 for tokens it does not know, so on its own it would wave through
  # every unregistered token.
  @fee_base_decimals 6

  # Returns the budget it validated, so the number that was checked is the
  # number that gets escrowed. Recomputing it in `set_budget/6` would leave the
  # gate guarding a value nothing downstream is bound to.
  defp fee_budget(state, intent, transfer_atomic) do
    budget_atomic = budget_for(transfer_atomic, state.fee_bps)

    with :ok <- ensure_stable_origin(intent),
         :ok <- ensure_fee_floor(budget_atomic, state.fee_bps, state.min_fee_atomic) do
      {:ok, budget_atomic}
    end
  end

  defp ensure_stable_origin(%{from_chain_id: chain, from_token: token}) do
    with symbol when symbol in @fee_base_symbols <- Assets.symbol_for(chain, token),
         @fee_base_decimals <- Assets.decimals(chain, token) do
      :ok
    else
      decimals when is_integer(decimals) ->
        {:reject, {:unsupported_fee_base_decimals, chain, token, decimals}}

      _ ->
        {:reject, {:unsupported_fee_base, chain, token}}
    end
  end

  defp ensure_stable_origin(_intent), do: {:reject, {:unsupported_fee_base, nil, nil}}

  # `budget_for/2` truncates through `div/2`, so a small enough transfer rounds
  # the fee to zero. A zero budget is an escrow that can never pay, and the
  # generic path has no order-size band of its own (the USDC public offering
  # carries a 1 USDC floor), so reject rather than propose it.
  #
  # Two different zeros: a storefront configured with `fee_bps: 0` is charging
  # nothing deliberately and its zero budget is the intended outcome. The floor
  # is for the other one, where a fee was meant to be charged and truncated away.
  defp ensure_fee_floor(_budget_atomic, 0, _min), do: :ok

  defp ensure_fee_floor(budget_atomic, _fee_bps, min) do
    if budget_atomic >= min,
      do: :ok,
      else: {:reject, {:fee_below_min, budget_atomic, min}}
  end

  # Read and checked once, at start_link, rather than per job. `>=` against a
  # non-integer does not raise -- Erlang term order puts every number below every
  # atom and binary, so `5000 >= "1"` and `5000 >= :infinity` are both false. A
  # mistyped value would silently reject every job on this path, which is the
  # worst way for a storefront to be down. Refusing to start says so instead.
  @spec validate_min_fee(term()) :: {:ok, non_neg_integer()} | {:error, term()}
  defp validate_min_fee(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_min_fee(other), do: {:error, {:invalid_solver_min_fee_atomic, other}}

  defp set_budget(state, key, session, requirement, transfer_atomic, budget_atomic) do
    case HookClient.set_budget(
           state.provider,
           state.chain_id,
           state.acp_core_address,
           session.job_id_uint,
           budget_atomic
         ) do
      {:ok, tx_hash} ->
        emit(state, key, :budget_proposed, %{tx_hash: tx_hash, budget_atomic: budget_atomic})

        Logger.info(
          "[xochi.solver] setBudget #{budget_atomic} for #{inspect(key)} tx=#{tx_hash}; awaiting fund"
        )

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
    Logger.info("[xochi.solver] settling #{inspect(key)} via Xochi relay")

    case state.settle_fn.(%{
           requirement: session.requirement,
           signed_intent: session.requirement["signed_intent"],
           transfer_amount_atomic: session.transfer_amount_atomic
         }) do
      {:ok, %{intent_id: intent_id} = deliverable} ->
        Logger.info("[xochi.solver] settled #{inspect(key)} intent=#{intent_id}; submitting")
        submit_deliverable(state, key, session, deliverable, intent_id)

      {:error, reason} ->
        emit(state, key, :settle_error, reason)
        Logger.error("[xochi.solver] settle failed for #{inspect(key)}: #{inspect(reason)}")
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
        Logger.info("[xochi.solver] submitted deliverable for #{inspect(key)} tx=#{tx_hash}")

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
        Logger.error("[xochi.solver] submit failed for #{inspect(key)}: #{inspect(reason)}")
        put_session(state, key, %{session | status: :failed})
    end
  end

  # -- Default settle (test-only) --

  # In production, callers pass a `Raxol.Earn.Xochi.Settler` relay closure via
  # :settle_fn. The default below produces a deterministic stub so the
  # SolverAgent can be exercised in tests without a live Xochi server.
  defp default_settle(%{transfer_amount_atomic: transfer_atomic}) do
    {:ok,
     %{
       intent_id: ("stub-intent-" <> :erlang.unique_integer([:positive])) |> to_string(),
       quote_id: "stub-quote",
       settlement_tx_hash: "0x" <> String.duplicate("a", 64),
       receiving_tx_hash: "0x" <> String.duplicate("b", 64),
       status: "settled",
       fee_atomic: "0",
       dst_amount_atomic: transfer_atomic && to_string(transfer_atomic)
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
      [:raxol, :earn, :xochi, :solver, :event],
      %{},
      %{key: key, event: event, payload: payload}
    )
  end
end
