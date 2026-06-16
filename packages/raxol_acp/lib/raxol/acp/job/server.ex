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
  `%{job_id, from, to, memo_type, tx_hash}`.

  ## Workflow-backed mode (ADR-0016 Phase A)

  Pass `via_workflow: true` (or set
  `Application.put_env(:raxol_acp, :job_via_workflow, true)`) to route
  transitions through `Raxol.ACP.Job.Workflow` instead of the inline
  state machine. The public API is unchanged; internally the
  Phase 25 `Raxol.Workflow` runtime drives each transition, writes a
  checkpoint to the configured Saver after every memo, and emits
  per-node telemetry on `[:raxol, :workflow, :*]` in addition to the
  legacy `[:raxol, :acp, :job, :transition]` event. On a transient
  restart the new process hydrates from the Saver's latest
  checkpoint, matching the existing Store-hydration behavior.

  Saver selection:

      Application.put_env(:raxol_acp, :job_workflow_saver,
        {Raxol.Workflow.Checkpoint.Saver.Dets, %{name: MyDets}})

  Defaults to `Saver.Ets` with a shared named table when no override
  is configured.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Job.{MemoType, Registry, StateMachine, Store}
  alias Raxol.ACP.Job.Workflow, as: JobWorkflow
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
          via_workflow?: boolean(),
          compiled: WorkflowCompiled.t() | nil
        }

  defstruct [
    :job_id,
    :state,
    :compiled,
    memos: [],
    config: %{},
    persist?: true,
    via_workflow?: false
  ]

  # -- Public API --

  @doc """
  Start a Job.Server registered under the given job ID.

  ## Required options

  - `:job_id` -- the ACP job id (binary or integer).

  ## Optional state options

  - `:initial_state` -- defaults to `StateMachine.initial/0`.

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
    transition writes through `Raxol.ACP.Job.Store`, and `init/1`
    hydrates state + memos from the store if a prior record exists for
    this `:job_id`. Set to `false` to bypass persistence (e.g. tests
    that exercise raw transition semantics).
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

  @doc "Return the full Job.Server struct for inspection."
  @spec get_state(GenServer.server() | binary()) :: t()
  def get_state(server), do: GenServer.call(resolve(server), :get_state)

  @doc "Return the current StateMachine state."
  @spec current_state(GenServer.server() | binary()) :: StateMachine.state()
  def current_state(server), do: GenServer.call(resolve(server), :current_state)

  @doc "Return the memo history in submission order."
  @spec memos(GenServer.server() | binary()) :: [memo()]
  def memos(server), do: GenServer.call(resolve(server), :memos)

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
    initial = Keyword.get(opts, :initial_state, StateMachine.initial())

    via_workflow? =
      Keyword.get(
        opts,
        :via_workflow,
        Application.get_env(:raxol_acp, :job_via_workflow, false)
      )

    {state, memos, compiled} =
      if via_workflow? do
        hydrate_via_workflow(job_id, persist?, initial)
      else
        {s, ms} = hydrate(job_id, persist?, initial)
        {s, ms, nil}
      end

    {:ok,
     %__MODULE__{
       job_id: job_id,
       state: state,
       memos: memos,
       config: config,
       persist?: persist?,
       via_workflow?: via_workflow?,
       compiled: compiled
     }}
  end

  # Workflow-backed hydration. Compiles the canonical ACP graph and
  # either resumes from a prior checkpoint or invokes the workflow
  # fresh to create the initial __start__ checkpoint. State is read
  # back from the workflow runtime so it stays the single source of
  # truth while the legacy Store is kept in sync via mirror writes
  # for backward compatibility.
  defp hydrate_via_workflow(job_id, persist?, _initial) do
    saver = if persist?, do: configured_workflow_saver(), else: nil
    {:ok, compiled} = JobWorkflow.compile(maybe_saver_opts(saver))

    workflow_state = ensure_workflow_run(compiled, saver, job_id)
    {workflow_state.current_state, workflow_state.memos, compiled}
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

  defp load_workflow_state(nil, _job_id), do: :not_found

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

  defp maybe_saver_opts(nil), do: []
  defp maybe_saver_opts(saver), do: [saver: saver]

  # Restore prior state + memos from the Store on a transient restart.
  # If persistence is disabled or no record exists, fall back to the
  # caller-supplied initial state with no memo history.
  defp hydrate(job_id, true, initial) do
    case Store.load(job_id) do
      {:ok, %{state: state, memos: memos}} -> {state, memos}
      :error -> {initial, []}
    end
  end

  defp hydrate(_job_id, false, initial), do: {initial, []}

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

  # -- Private --

  defp do_transition(state, event, payload, signature) do
    if state.via_workflow? do
      do_transition_via_workflow(state, event, payload, signature)
    else
      do_transition_legacy(state, event, payload, signature)
    end
  end

  # Workflow-backed transition path. The state-machine guard mirrors
  # the legacy one so callers see the same `{:error, {:invalid_transition, _, _}}`
  # shape for events that the current phase does not accept. Successful
  # transitions delegate to `Compiled.resume/4`; on terminal phase, the
  # workflow returns `{:ok, _, _}` and the GenServer stops with `:normal`.
  defp do_transition_via_workflow(state, event, payload, signature) do
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

    if terminal? do
      {:stop, :normal, {:ok, new_wf_state.current_state}, new_full_state}
    else
      {:reply, {:ok, new_wf_state.current_state}, new_full_state}
    end
  end

  defp do_transition_legacy(state, event, payload, signature) do
    memo_type = memo_type_for_event(event)
    content = encode_content(payload)

    with {:ok, new_state} <- StateMachine.next(state.state, event),
         {:ok, tx_hash} <-
           ContractClient.create_memo(
             state.job_id,
             content,
             memo_type,
             false,
             new_state
           ) do
      memo = %{
        next_phase: new_state,
        memo_type: memo_type,
        content: content,
        is_secured: false,
        payload: ensure_payload(payload),
        signature: signature,
        tx_hash: tx_hash,
        transitioned_at: DateTime.utc_now()
      }

      :telemetry.execute(
        [:raxol, :acp, :job, :transition],
        %{},
        %{
          job_id: state.job_id,
          from: state.state,
          to: new_state,
          memo_type: memo_type,
          next_phase: new_state,
          tx_hash: tx_hash
        }
      )

      new_full_state = %{state | state: new_state, memos: state.memos ++ [memo]}
      maybe_persist(new_full_state, memo)

      if StateMachine.terminal?(new_state) do
        {:stop, :normal, {:ok, new_state}, new_full_state}
      else
        {:reply, {:ok, new_state}, new_full_state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Mirror every successful transition to the Store so a transient
  # restart can pick up where the prior process left off. No-op when
  # persistence is disabled.
  defp maybe_persist(%{persist?: false}, _memo), do: :ok

  defp maybe_persist(%{persist?: true, job_id: job_id, state: state}, memo) do
    Store.append_memo(job_id, state, memo)
  end

  # Default memo type per event. Payment/approval steps reference a
  # transaction hash; everything else is a free-form message. Callers
  # who need a different `MemoType` (e.g. an image_url for a deliverable)
  # should call ContractClient.create_memo/5 directly.
  defp memo_type_for_event(:accept_payment), do: :txhash
  defp memo_type_for_event(:approve), do: :txhash
  defp memo_type_for_event(_), do: :message

  defp encode_content(nil), do: ""
  defp encode_content(payload) when is_binary(payload), do: payload
  defp encode_content(payload) when is_map(payload), do: Jason.encode!(payload)

  defp ensure_payload(payload) when is_map(payload), do: payload
  defp ensure_payload(_), do: nil

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
