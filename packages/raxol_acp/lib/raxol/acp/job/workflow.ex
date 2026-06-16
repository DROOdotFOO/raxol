defmodule Raxol.ACP.Job.Workflow do
  @moduledoc """
  `Raxol.Workflow` graph mirroring `Raxol.ACP.Job.StateMachine`.

  Compiles a graph
  that has the same state-machine shape as the current `Job.Server`
  implementation. Each transition dispatches exactly one
  `Raxol.ACP.Directive.CreateMemo`, the workflow
  checkpoints after every memo write, and waiting phases interrupt
  to wait for the next inbound event.

  ## Topology

      :__start__ -> :wait_request
        :wait_request -[event]-> :memo_negotiation | :memo_rejected | :memo_expired
          :memo_negotiation -> :wait_negotiation
            :wait_negotiation -[event]-> :memo_transaction | :memo_expired
              :memo_transaction -> :wait_transaction
                :wait_transaction -[event]-> :memo_evaluation | :memo_expired
                  :memo_evaluation -> :wait_evaluation
                    :wait_evaluation -[event]-> :memo_completed | :memo_expired
                      :memo_completed -> :__end__
        :memo_rejected -> :__end__
        :memo_expired -> :__end__

  ## Why two kinds of nodes

  Each non-terminal phase splits into two nodes:

    * `:wait_*` -- pure interrupt; no side effects. On first invocation
      it throws to pause the run; on resume it pops the event tuple
      from the scratchpad and writes it into state.
    * `:memo_*` -- side-effecting dispatch of a
      `Raxol.ACP.Directive.CreateMemo` through
      `Raxol.ACP.Directive.Helper.execute_sync/2`. No interrupt.
      Eligible for `failure_policy: :retry` because re-running it does
      not re-pop the scratchpad.

  Combining them in one node would break retry: the workflow's
  retry loop re-runs the whole node body, and `Workflow.interrupt/1`
  cannot be re-popped on retry (the scratchpad value was consumed by
  the first attempt). The split keeps memo writes retryable and
  interrupts side-effect-free.

  ## State shape

  The workflow threads a single state map through every node:

      %{
        job_id: ContractClient.job_id(),
        memos: [Raxol.ACP.Job.Server.memo()],
        pending_event: atom() | nil,
        pending_payload: any() | nil,
        pending_signature: binary() | nil,
        current_state: Raxol.ACP.Job.StateMachine.state(),
        next_state: Raxol.ACP.Job.StateMachine.state() | nil
      }

  `pending_*` is written by a `:wait_*` node when it pops the event
  from the scratchpad; the following `:memo_*` node reads those
  fields, fires the on-chain call, appends to `memos`, and clears
  `pending_*`. `current_state` advances after each successful memo
  write; `next_state` is the routing target the conditional edges
  read.

  ## Resume semantics

  `Compiled.resume/4` looks up the latest checkpoint, hydrates the
  state, and resumes from the node after the checkpoint's node. For
  this workflow that means: the last successful `:memo_*` node wrote
  a checkpoint, the runtime resumes by traversing into the next
  `:wait_*` node, the wait node pops the scratchpad value (the new
  event) and the run continues. Phase A's `Job.Server` facade calls
  resume with the event tuple as the resume value.

  ## Out of scope for this module

  - Wiring this graph into `Raxol.ACP.Job.Server` (Phase A PR 2).
  - Per-phase interrupt reasons in the seller protocol (Phase B).
  - `TypedNode` per phase (a polish refactor after Phase A stabilises).
  """

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.Directive
  alias Raxol.ACP.Directive.Helper, as: DirectiveHelper
  alias Raxol.ACP.Job.StateMachine
  alias Raxol.Workflow
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  @type event ::
          :accept_request
          | :accept_payment
          | :deliver
          | :approve
          | :reject
          | :expire
  @type resume_value :: {event(), payload :: any(), signature :: binary() | nil}

  @type state :: %{
          job_id: ContractClient.job_id(),
          memos: [map()],
          pending_event: event() | nil,
          pending_payload: any() | nil,
          pending_signature: binary() | nil,
          current_state: StateMachine.state(),
          next_state: StateMachine.state() | nil
        }

  @default_max_attempts 3
  @default_retry_backoff_ms 200

  @doc """
  Compile the canonical ACP Job workflow.

  ## Options

    * `:saver` -- forwarded to `Raxol.Workflow.Graph.compile/2`.
      Defaults to `nil` (volatile; no resume support). Production
      usage should pass `{Raxol.Workflow.Checkpoint.Saver.Dets, %{...}}`
      or `{Saver.Postgrex, %{conn: ..., table: ...}}`.
    * `:max_attempts` / `:retry_backoff_ms` -- forwarded to the
      retry policy. Defaults `3` and `200ms`.

  Returns the compiled graph or a structured error from
  `Raxol.Workflow.Graph.compile/2`.
  """
  @spec compile(keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  def compile(opts \\ []) do
    Graph.new(:acp_job)
    |> add_phase_nodes()
    |> add_phase_edges()
    |> Graph.compile(compile_opts(opts))
  end

  defp add_phase_nodes(graph) do
    graph
    |> Graph.add_node(:wait_request, &wait_request/1)
    |> Graph.add_node(:wait_negotiation, &wait_negotiation/1)
    |> Graph.add_node(:wait_transaction, &wait_transaction/1)
    |> Graph.add_node(:wait_evaluation, &wait_evaluation/1)
    |> Graph.add_node(:memo_negotiation, memo_node(:negotiation))
    |> Graph.add_node(:memo_transaction, memo_node(:transaction))
    |> Graph.add_node(:memo_evaluation, memo_node(:evaluation))
    |> Graph.add_node(:memo_completed, memo_node(:completed))
    |> Graph.add_node(:memo_rejected, memo_node(:rejected))
    |> Graph.add_node(:memo_expired, memo_node(:expired))
  end

  defp add_phase_edges(graph) do
    graph
    |> Graph.add_edge(:__start__, :wait_request)
    |> Graph.add_conditional_edge(
      :wait_request,
      [:memo_negotiation, :memo_rejected, :memo_expired],
      &route_from_request/1
    )
    |> Graph.add_edge(:memo_negotiation, :wait_negotiation)
    |> Graph.add_conditional_edge(
      :wait_negotiation,
      [:memo_transaction, :memo_expired],
      &route_from_negotiation/1
    )
    |> Graph.add_edge(:memo_transaction, :wait_transaction)
    |> Graph.add_conditional_edge(
      :wait_transaction,
      [:memo_evaluation, :memo_expired],
      &route_from_transaction/1
    )
    |> Graph.add_edge(:memo_evaluation, :wait_evaluation)
    |> Graph.add_conditional_edge(
      :wait_evaluation,
      [:memo_completed, :memo_expired],
      &route_from_evaluation/1
    )
    |> Graph.add_edge(:memo_completed, :__end__)
    |> Graph.add_edge(:memo_rejected, :__end__)
    |> Graph.add_edge(:memo_expired, :__end__)
  end

  defp compile_opts(opts) do
    [
      failure_policy: :retry,
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      retry_backoff_ms:
        Keyword.get(opts, :retry_backoff_ms, @default_retry_backoff_ms)
    ]
    |> maybe_put_saver(opts)
  end

  @doc """
  Build the initial state for a fresh job invocation.
  """
  @spec initial_state(ContractClient.job_id()) :: state()
  def initial_state(job_id) do
    %{
      job_id: job_id,
      memos: [],
      pending_event: nil,
      pending_payload: nil,
      pending_signature: nil,
      current_state: StateMachine.initial(),
      next_state: nil
    }
  end

  # --- Wait node bodies ---
  #
  # Each wait node simply interrupts to pause for the next event,
  # then on resume pops the event tuple from the scratchpad and
  # writes it to `pending_*`. The following conditional edge reads
  # those fields to pick the destination `:memo_*` node.

  defp wait_request(state), do: pop_event(state, :awaiting_request_response)
  defp wait_negotiation(state), do: pop_event(state, :awaiting_buyer_payment)
  defp wait_transaction(state), do: pop_event(state, :awaiting_delivery)

  defp wait_evaluation(state),
    do: pop_event(state, :awaiting_evaluator_approval)

  @doc """
  Canonical list of pause-reason atoms emitted by `wait_*` nodes.

  Surfaces the pause-reason contract so dashboards and
  filters can enumerate the expected reasons without scraping the
  module source. Order mirrors the ACP phase ladder.
  """
  @spec pause_reasons() :: [
          :awaiting_request_response
          | :awaiting_buyer_payment
          | :awaiting_delivery
          | :awaiting_evaluator_approval
        ]
  def pause_reasons do
    [
      :awaiting_request_response,
      :awaiting_buyer_payment,
      :awaiting_delivery,
      :awaiting_evaluator_approval
    ]
  end

  # The wait node always returns `{:ok, _}` so that the workflow's
  # `failure_policy: :retry` does not re-enter `Workflow.interrupt/1`
  # on a node whose scratchpad value has already been popped. Event
  # validation lives at the edge: unknown events route to
  # `:memo_expired` so the run terminates cleanly rather than
  # cycling. Callers (`Job.Server` facade in Phase A PR 2) are
  # responsible for sending valid events.
  defp pop_event(state, reason) do
    {event, payload, signature} =
      case Workflow.interrupt(reason) do
        {e, p, s} -> {e, p, s}
        other -> {{:bad_resume_value, other}, nil, nil}
      end

    {:ok,
     %{
       state
       | pending_event: event,
         pending_payload: payload,
         pending_signature: signature
     }}
  end

  # --- Conditional-edge choosers ---

  defp route_from_request(%{pending_event: :accept_request}),
    do: :memo_negotiation

  defp route_from_request(%{pending_event: :reject}), do: :memo_rejected
  defp route_from_request(_), do: :memo_expired

  defp route_from_negotiation(%{pending_event: :accept_payment}),
    do: :memo_transaction

  defp route_from_negotiation(_), do: :memo_expired

  defp route_from_transaction(%{pending_event: :deliver}), do: :memo_evaluation
  defp route_from_transaction(_), do: :memo_expired

  defp route_from_evaluation(%{pending_event: :approve}), do: :memo_completed
  defp route_from_evaluation(_), do: :memo_expired

  # --- Memo node bodies ---
  #
  # A memo node fires one `Raxol.ACP.Directive.CreateMemo` for the
  # phase it is named after, appends a memo record to state, advances
  # `current_state`, and clears the pending fields. No interrupts;
  # this node is retry-safe. The on-chain call routes
  # through the directive protocol so the canonical operation is the
  # Directive struct, not the raw ContractClient call.

  defp memo_node(next_phase) do
    fn state -> write_memo(state, next_phase) end
  end

  defp write_memo(state, next_phase) do
    event = state.pending_event
    payload = state.pending_payload
    signature = state.pending_signature
    memo_type = memo_type_for_event(event)
    content = encode_content(payload)

    directive =
      Directive.create_memo(
        job_id: state.job_id,
        content: content,
        memo_type: memo_type,
        is_secured: false,
        next_phase: next_phase
      )

    case DirectiveHelper.execute_sync(directive) do
      {:ok, tx_hash} ->
        memo = %{
          next_phase: next_phase,
          memo_type: memo_type,
          content: content,
          is_secured: false,
          payload: ensure_payload(payload),
          signature: signature,
          tx_hash: tx_hash,
          transitioned_at: DateTime.utc_now()
        }

        # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
        new_memos = state.memos ++ [memo]

        {:ok,
         %{
           state
           | memos: new_memos,
             current_state: next_phase,
             next_state: nil,
             pending_event: nil,
             pending_payload: nil,
             pending_signature: nil
         }}

      {:error, _reason} = err ->
        err
    end
  end

  # --- Helpers (mirror Job.Server private fns) ---

  defp memo_type_for_event(:accept_payment), do: :txhash
  defp memo_type_for_event(:approve), do: :txhash
  defp memo_type_for_event(_), do: :message

  defp encode_content(nil), do: ""
  defp encode_content(payload) when is_binary(payload), do: payload
  defp encode_content(payload) when is_map(payload), do: Jason.encode!(payload)

  defp ensure_payload(payload) when is_map(payload), do: payload
  defp ensure_payload(_), do: nil

  defp maybe_put_saver(opts, caller_opts) do
    case Keyword.get(caller_opts, :saver) do
      nil -> opts
      saver -> Keyword.put(opts, :saver, saver)
    end
  end
end
