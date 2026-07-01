defmodule Raxol.ACP.Job.Server do
  @moduledoc """
  GenServer holding the in-flight state for a single ACP job.

  One process per active job, registered by job ID via
  `Raxol.ACP.Job.Registry`. Two layers of API:

  - **Low-level** -- `transition/4` accepts event + payload + opaque
    signature. Validates against `Raxol.ACP.Job.StateMachine`, creates
    an on-chain memo via `Raxol.ACP.ContractClient`, appends to memo
    history, emits telemetry.

  - **Orchestration** -- `accept_request/1`, `deliver/1`,
    `accept_payment/3`, `approve/3`. Active when the server is
    configured with a `:handler` (any module implementing
    `Raxol.ACP.Offering.Handler`). The orchestration helpers invoke
    the handler at the right state and fire the next transition.

  ## Signatures

  The `signature` argument on `transition/4`, `accept_payment/3`, and
  `approve/3` is the **buyer's** authorization (e.g. ERC-3009 for
  payments) and is kept in the local memo log for record-keeping. It
  is NOT sent on-chain by `createMemo` -- the canonical ACP contract
  does not accept a separate memo signature; the transaction itself
  is signed by the calling wallet.

  Terminates with `:normal` on a transition into a terminal state
  (`:completed` or `:expired`). Combined with the transient restart in
  `Raxol.ACP.Job.Supervisor`, completed jobs do not resurrect.

  ## Telemetry

  Emits `[:raxol, :acp, :job, :transition]` on every successful
  transition with metadata
  `%{job_id, from, to, memo_type, tx_hash}`. The underlying
  `Raxol.Workflow` runtime also emits per-node telemetry on
  `[:raxol, :workflow, :*]`.

  ## Persistence

  Each transition runs through a `Raxol.ACP.Job.Workflow` graph, which
  writes a checkpoint to the configured Saver after every memo. On a
  transient restart the new process hydrates from the Saver's latest
  checkpoint. `Raxol.ACP.Job.Store` receives mirror writes on every
  transition so consumers reading from the Store (the bench runner,
  the seller queue, downstream dashboards) see the same view.

  Saver selection:

      Application.put_env(:raxol_acp, :job_workflow_saver,
        {Raxol.Workflow.Checkpoint.Saver.Dets, %{name: MyDets}})

  Defaults to `Saver.Ets` with a shared named table when no override
  is configured. When `persist?: false`, an ephemeral per-server ETS
  table is minted and torn down on `terminate/2`.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Job.{MemoType, Registry, StateMachine, Store}
  alias Raxol.ACP.Job.Workflow, as: JobWorkflow
  alias Raxol.Workflow.Checkpoint.Saver, as: WorkflowSaver
  alias Raxol.Workflow.Compiled, as: WorkflowCompiled

  @type memo :: %{
          next_phase: StateMachine.state(),
          memo_type: MemoType.t(),
          content: String.t(),
          is_secured: boolean(),
          payload: map() | nil,
          signature: binary() | nil,
          tx_hash: ContractClient.tx_hash(),
          transitioned_at: DateTime.t()
        }

  @type config :: %{
          optional(:handler) => module(),
          optional(:request) => map(),
          optional(:buyer) => String.t(),
          optional(:seller) => String.t()
        }

  @type t :: %__MODULE__{
          job_id: ContractClient.job_id(),
          state: StateMachine.state(),
          memos: [memo()],
          config: config(),
          persist?: boolean(),
          expired_at: non_neg_integer() | nil,
          compiled: WorkflowCompiled.t(),
          ephemeral_saver_table: atom() | nil
        }

  defstruct [
    :job_id,
    :state,
    :compiled,
    :ephemeral_saver_table,
    :expired_at,
    memos: [],
    config: %{},
    persist?: true
  ]

  # -- Public API --

  @doc """
  Start a Job.Server registered under the given job ID.

  ## Required options

  - `:job_id` -- the ACP job id (binary or integer).

  ## Optional orchestration options

  These enable the high-level helpers (`accept_request/1`, `deliver/1`,
  `accept_payment/3`, `approve/3`). Without them, only `transition/4`
  works.

  - `:handler` -- module implementing `Raxol.ACP.Offering.Handler`.
  - `:request` -- the buyer's request map; passed to handler callbacks.
  - `:buyer` -- buyer address (0x string), surfaced in handler ctx.
  - `:seller` -- seller address (0x string), surfaced in handler ctx.

  ## Optional persistence options

  - `:persist?` -- default `true`. When true, every successful
    transition mirrors to `Raxol.ACP.Job.Store` and writes a
    workflow checkpoint to the configured Saver
    (`Application.put_env(:raxol_acp, :job_workflow_saver, ...)`).
    On a transient restart the new process hydrates state + memos
    from the Saver. Set to `false` for tests that exercise raw
    transition semantics; a per-process ephemeral ETS Saver is
    minted automatically so `Compiled.resume/4` still works.

  ## Optional expiry

  - `:expired_at` -- unix timestamp (seconds). When set, the server
    auto-fires `:expire` once the deadline passes and the job is still
    non-terminal, so escrowed funds do not wedge in a job whose
    counterparty abandoned it. Pair with `reclaim/1` to withdraw the
    escrow on-chain. Survives a transient restart (the deadline rides the
    child spec). Omit it to keep the prior behaviour (no timer).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    job_id = Keyword.fetch!(opts, :job_id)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(job_id))
  end

  @doc """
  Drive the state machine forward by `event` with a caller-supplied
  payload and signature. Low-level entry point used by both
  orchestration helpers and tests that want to bypass the handler.
  """
  @spec transition(
          GenServer.server() | binary(),
          StateMachine.event(),
          map(),
          binary()
        ) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def transition(server, event, payload, signature) do
    GenServer.call(resolve(server), {:transition, event, payload, signature})
  end

  @doc """
  Invoke the configured handler's `handle_request/2` callback. On
  `{:accept, response}`, fire `:accept_request` (advancing to
  `:negotiation`). On `{:reject, reason}`, fire `:expire`.

  Requires `:handler` and `:request` in the server's config.
  """
  @spec accept_request(GenServer.server() | binary()) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def accept_request(server) do
    GenServer.call(resolve(server), :accept_request)
  end

  @doc """
  Buyer-side: record the buyer's payment authorization and advance to
  `:transaction`.

  If `payload` is supplied, it becomes the memo content. `signature`
  is the buyer's authorization (e.g. ERC-3009); stored in the local
  memo log for record-keeping but not sent on-chain.
  """
  @spec accept_payment(GenServer.server() | binary(), map(), binary() | nil) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def accept_payment(server, payload, signature \\ nil) do
    GenServer.call(resolve(server), {:accept_payment, payload, signature})
  end

  @doc """
  Invoke the configured handler's `handle_deliver/2` callback. On
  `{:deliver, deliverable}`, fire `:deliver` (advancing to
  `:evaluation`). On `{:error, reason}`, fire `:expire`.
  """
  @spec deliver(GenServer.server() | binary()) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def deliver(server) do
    GenServer.call(resolve(server), :deliver)
  end

  @doc """
  Buyer/evaluator-side: approve the deliverable and finalize the job.

  Same payload/signature semantics as `accept_payment/3`.
  """
  @spec approve(GenServer.server() | binary(), map(), binary() | nil) ::
          {:ok, StateMachine.state()} | {:error, term()}
  def approve(server, payload, signature \\ nil) do
    GenServer.call(resolve(server), {:approve, payload, signature})
  end

  @doc """
  Buyer-side reclaim of the escrowed budget for an expired / undelivered
  job. Calls `Raxol.ACP.ContractClient.withdraw_escrowed_funds/1` through
  the configured client. Intended after the job has passed its
  `expired_at` without delivery; the on-chain contract enforces the timing.
  """
  @spec reclaim(GenServer.server() | binary()) ::
          {:ok, ContractClient.tx_hash()} | {:error, term()}
  def reclaim(server), do: GenServer.call(resolve(server), :reclaim)

  @doc "Return the full Job.Server struct for inspection."
  @spec get_state(GenServer.server() | binary()) :: t()
  def get_state(server), do: GenServer.call(resolve(server), :get_state)

  @doc "Return the current StateMachine state."
  @spec current_state(GenServer.server() | binary()) :: StateMachine.state()
  def current_state(server), do: GenServer.call(resolve(server), :current_state)

  @doc "Return the memo history in submission order."
  @spec memos(GenServer.server() | binary()) :: [memo()]
  def memos(server), do: GenServer.call(resolve(server), :memos)

  @typedoc """
  Dashboard row returned by `list_paused/0,1`. One
  row per job whose latest workflow checkpoint carries an
  `:interrupt_reason`. Resuming a paused job removes it from the next
  query.
  """
  @type paused_job :: %{
          job_id: ContractClient.job_id(),
          interrupt_reason: atom(),
          paused_at: DateTime.t() | nil,
          state: StateMachine.state(),
          memos: [memo()]
        }

  @doc """
  Enumerate ACP jobs that are currently paused waiting on an external
  event (buyer payment, evaluator approval, etc.).

  Reads through the configured workflow Saver (see
  `Application.put_env(:raxol_acp, :job_workflow_saver, ...)`) and
  hydrates each pause checkpoint's state back into the dashboard row.

  ## Options

    * `:limit` -- maximum rows to return (default: 100).
    * `:reason` -- filter the returned rows by `interrupt_reason`
      (e.g. `:awaiting_buyer_payment`). Default returns all reasons.
  """
  @spec list_paused() :: [paused_job()]
  def list_paused, do: list_paused([])

  @spec list_paused(keyword()) :: [paused_job()]
  def list_paused(opts) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 100)
    reason_filter = Keyword.get(opts, :reason)

    case WorkflowSaver.normalize(configured_workflow_saver()) do
      nil ->
        []

      saver_tuple ->
        {:ok, rows} = WorkflowSaver.list_paused(saver_tuple, limit)

        rows
        |> Enum.map(&to_paused_job/1)
        |> Enum.filter(&matches?(&1, reason_filter))
    end
  end

  defp to_paused_job(row) do
    wf_state = row.state

    %{
      job_id: Map.get(wf_state, :job_id) || row.thread_id,
      interrupt_reason: row.interrupt_reason,
      paused_at: row.paused_at,
      state: Map.get(wf_state, :current_state, StateMachine.initial()),
      memos: Map.get(wf_state, :memos, [])
    }
  end

  defp matches?(_row, nil), do: true
  defp matches?(%{interrupt_reason: reason}, reason), do: true
  defp matches?(_row, _reason), do: false

  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name) when is_atom(name), do: name
  defp resolve(job_id) when is_binary(job_id), do: Registry.via(job_id)
  defp resolve({:via, _, _} = via), do: via

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    config =
      opts
      |> Keyword.take([:handler, :request, :buyer, :seller])
      |> Map.new()

    job_id = Keyword.fetch!(opts, :job_id)
    persist? = Keyword.get(opts, :persist?, true)
    expired_at = Keyword.get(opts, :expired_at)

    {state, memos, compiled, ephemeral_table} = hydrate(job_id, persist?)

    maybe_schedule_expiry(expired_at, state)

    {:ok,
     %__MODULE__{
       job_id: job_id,
       state: state,
       memos: memos,
       config: config,
       persist?: persist?,
       expired_at: expired_at,
       compiled: compiled,
       ephemeral_saver_table: ephemeral_table
     }}
  end

  # Compile the canonical ACP graph and either resume from a prior
  # checkpoint or invoke the workflow fresh to create the initial
  # __start__ checkpoint. State is read back from the workflow runtime
  # so it stays the single source of truth; `Raxol.ACP.Job.Store` is
  # kept in sync via mirror writes for consumers that read from it.
  #
  # When `persist?` is false we still need a Saver because
  # `Compiled.resume/4` requires one (`{:error, :no_saver_configured, _}`
  # otherwise). Mint a process-private ETS table for the lifetime of
  # this GenServer; it is deleted in `terminate/2`.
  defp hydrate(job_id, persist?) do
    {saver, ephemeral_table} =
      if persist? do
        {configured_workflow_saver(), nil}
      else
        table =
          :"raxol_acp_job_wf_ephemeral_#{:erlang.unique_integer([:positive])}"

        {{Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}, table}
      end

    {:ok, compiled} = JobWorkflow.compile(saver: saver)

    workflow_state = ensure_workflow_run(compiled, saver, job_id)

    {workflow_state.current_state, workflow_state.memos, compiled, ephemeral_table}
  end

  defp ensure_workflow_run(compiled, saver, job_id) do
    case load_workflow_state(saver, job_id) do
      {:ok, state} ->
        state

      :not_found ->
        initial_state = JobWorkflow.initial_state(job_id)

        case WorkflowCompiled.invoke(compiled, initial_state, run_id: job_id) do
          {:interrupted, _run_id, state, _value} -> state
        end
    end
  end

  defp load_workflow_state({mod, cfg}, job_id) do
    case mod.get_latest(cfg, job_id) do
      {:ok, ckpt} -> {:ok, ckpt.state}
      {:error, :not_found} -> :not_found
    end
  end

  defp configured_workflow_saver do
    Application.get_env(
      :raxol_acp,
      :job_workflow_saver,
      {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: :raxol_acp_job_workflow}}
    )
  end

  @impl GenServer
  def terminate(_reason, %__MODULE__{ephemeral_saver_table: nil}), do: :ok

  def terminate(_reason, %__MODULE__{ephemeral_saver_table: table}) do
    case :ets.whereis(table) do
      :undefined ->
        :ok

      _ref ->
        try do
          :ets.delete(table)
          :ok
        rescue
          ArgumentError -> :ok
        end
    end
  end

  def terminate(_reason, _state), do: :ok

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(
        {:transition, event, payload, signature},
        _from,
        state
      ) do
    do_transition(state, event, payload, signature)
  end

  def handle_manager_call(:accept_request, _from, state) do
    with {:ok, %{handler: handler, request: request}} <-
           need(state.config, [:handler, :request]) do
      case handler.handle_request(request, ctx(state)) do
        {:accept, response} ->
          do_transition(state, :accept_request, response, nil)

        {:reject, reason} ->
          do_transition(state, :expire, %{reason: inspect(reason)}, nil)
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_manager_call({:accept_payment, payload, signature}, _from, state) do
    do_transition(state, :accept_payment, payload, signature)
  end

  def handle_manager_call(:deliver, _from, state) do
    with {:ok, %{handler: handler, request: request}} <-
           need(state.config, [:handler, :request]) do
      case handler.handle_deliver(request, ctx(state)) do
        {:deliver, deliverable} ->
          do_transition(state, :deliver, deliverable, nil)

        {:error, reason} ->
          do_transition(state, :expire, %{reason: inspect(reason)}, nil)
      end
    else
      {:error, _} = err -> {:reply, err, state}
    end
  end

  def handle_manager_call({:approve, payload, signature}, _from, state) do
    do_transition(state, :approve, payload, signature)
  end

  def handle_manager_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_manager_call(:current_state, _from, state),
    do: {:reply, state.state, state}

  def handle_manager_call(:memos, _from, state),
    do: {:reply, state.memos, state}

  def handle_manager_call(:reclaim, _from, state) do
    result = ContractClient.impl().withdraw_escrowed_funds(to_string(state.job_id))
    {:reply, result, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:expiry_deadline, state) do
    handle_expiry_tick(state, System.system_time(:second))
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Private --

  # -- Expiry timer --

  # A job started with `:expired_at` (unix seconds) auto-fires `:expire` when
  # the deadline passes and the job is still non-terminal, so escrowed funds do
  # not wedge in a job whose counterparty abandoned it. Long deadlines re-arm in
  # bounded steps so a single timer never exceeds the BEAM send_after ceiling.
  @max_timer_ms 3_600_000

  defp maybe_schedule_expiry(expired_at, state) do
    if is_integer(expired_at) and not StateMachine.terminal?(state) do
      schedule_expiry(expired_at, System.system_time(:second))
    end

    :ok
  end

  defp schedule_expiry(expired_at, now) do
    remaining_ms = max(0, (expired_at - now) * 1000)
    Process.send_after(self(), :expiry_deadline, min(remaining_ms, @max_timer_ms))
  end

  defp handle_expiry_tick(state, now) do
    cond do
      StateMachine.terminal?(state.state) ->
        {:noreply, state}

      is_integer(state.expired_at) and now >= state.expired_at ->
        expire_now(state)

      is_integer(state.expired_at) ->
        schedule_expiry(state.expired_at, now)
        {:noreply, state}

      true ->
        {:noreply, state}
    end
  end

  # Deadline reached while still non-terminal: fire `:expire` through the
  # workflow (writes the on-chain expired memo, the same path a handler
  # rejection takes) and stop. Emits `[:raxol, :acp, :job, :expired]`.
  defp expire_now(state) do
    :telemetry.execute(
      [:raxol, :acp, :job, :expired],
      %{},
      %{job_id: state.job_id, from: state.state}
    )

    case WorkflowCompiled.resume(
           state.compiled,
           state.job_id,
           {:expire, %{reason: "deadline"}, nil}
         ) do
      {:ok, new_wf_state, _meta} ->
        {:stop, :normal, commit_transition(state, new_wf_state)}

      {:interrupted, _run_id, new_wf_state, _value} ->
        {:noreply, commit_transition(state, new_wf_state)}

      {:error, _reason, _wf_state} ->
        {:noreply, state}
    end
  end

  # The state-machine guard short-circuits with `{:error, {:invalid_transition, _, _}}`
  # for events the current phase does not accept. Successful transitions
  # delegate to `Compiled.resume/4`; on terminal phase, the workflow
  # returns `{:ok, _, _}` and the GenServer stops with `:normal`.
  defp do_transition(state, event, payload, signature) do
    case StateMachine.next(state.state, event) do
      {:ok, _next_state} ->
        dispatch_workflow_resume(state, event, payload, signature)

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  defp dispatch_workflow_resume(state, event, payload, signature) do
    case WorkflowCompiled.resume(
           state.compiled,
           state.job_id,
           {event, payload, signature}
         ) do
      {:interrupted, _run_id, new_wf_state, _value} ->
        finalize_workflow_transition(state, new_wf_state, terminal?: false)

      {:ok, new_wf_state, _meta} ->
        finalize_workflow_transition(state, new_wf_state, terminal?: true)

      {:error, reason, _wf_state} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp finalize_workflow_transition(state, new_wf_state, terminal?: terminal?) do
    new_full_state = commit_transition(state, new_wf_state)

    if terminal? do
      {:stop, :normal, {:ok, new_wf_state.current_state}, new_full_state}
    else
      {:reply, {:ok, new_wf_state.current_state}, new_full_state}
    end
  end

  # Apply a workflow transition's result to the server struct: mirror the memo
  # to the Store, emit transition telemetry, and return the updated struct.
  # Shared by the call-driven transition path and the expiry-timer path.
  defp commit_transition(state, new_wf_state) do
    new_memo = List.last(new_wf_state.memos)

    new_full_state = %{
      state
      | state: new_wf_state.current_state,
        memos: new_wf_state.memos
    }

    if state.persist? and new_memo do
      Store.append_memo(state.job_id, new_wf_state.current_state, new_memo)
    end

    :telemetry.execute(
      [:raxol, :acp, :job, :transition],
      %{},
      %{
        job_id: state.job_id,
        from: state.state,
        to: new_wf_state.current_state,
        memo_type: new_memo && new_memo.memo_type,
        next_phase: new_wf_state.current_state,
        tx_hash: new_memo && new_memo.tx_hash
      }
    )

    new_full_state
  end

  defp ctx(state) do
    %{
      job_id: state.job_id,
      buyer: Map.get(state.config, :buyer),
      seller: Map.get(state.config, :seller),
      state: state.state
    }
  end

  defp need(config, keys) do
    case Enum.reject(keys, &Map.has_key?(config, &1)) do
      [] -> {:ok, Map.take(config, keys)}
      missing -> {:error, {:config_missing, missing}}
    end
  end
end
