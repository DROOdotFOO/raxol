defmodule Raxol.Harness.SessionLane do
  @moduledoc """
  The seam between the harness surface (this package, which must NEVER
  depend on `raxol_agent`) and a live agent session lane. A concrete lane
  implementation lives on the agent side (e.g.
  `Raxol.Agent.Harness.SessionLane` in `packages/raxol_agent`) or in a
  test double -- never here.

  ## The asymmetry: `interrupt/2` is event-observed, `steer/2` is a reply

  The two commands this behaviour exposes are deliberately NOT symmetric
  in how their outcome reaches the caller, and that asymmetry is the
  whole point, not an oversight:

    * **`interrupt/2` is fire-and-forget.** Its acknowledgment is
      EVENT-OBSERVED: the staged supervised kill this seam dispatches
      emits durable stage events on the SAME event stream the caller is
      already subscribed to (`:interrupt_signaled`, `:interrupt_waited`,
      `:interrupt_killed`/`:interrupt_kill_failed`, `:turn_canceled`) --
      those events ARE the acknowledgment, so no reply is defined here.
      Every kill stage is durable, journaled, and observable; there is
      nothing a synchronous reply would tell the caller that the event
      stream doesn't already say, more reliably (it survives the calling
      process crashing mid-call).
    * **`steer/2` is a synchronous typed decision.** A stale-turn
      rejection (the turn the caller believed was running already ended,
      or another steer won the compare-and-swap race) is deliberately
      **non-journaled** -- zero model effect, nothing appended to the
      turn's durable history (see `Raxol.Agent.Steer`'s own moduledoc:
      "Nothing is journaled and the state is unchanged"). Because a
      rejection produces no event, there is no event a surface could
      ever observe to learn the outcome -- only a direct reply can carry
      it honestly. Fire-and-forget steer would leave the surface with no
      way to distinguish "accepted" from "silently dropped".

  ## The `session` shape (cross-package law)

  `session()` is a plain MAP, never a struct -- this package's own
  cross-package convention (see the project's `CLAUDE.md`: struct
  patterns across package boundaries use map patterns). A lane
  implementation on the agent side may carry a real `Raxol.Agent.Session`
  struct internally, but what crosses this seam is always the map shape
  below.
  """

  @typedoc """
  A live session handle: at minimum a `:session_id`, optionally the
  session process's `:pid` (used by `monitor/1` and, on the agent side,
  by `Raxol.Agent.Command.route/2`'s `{:harness_command, action}`
  delivery).
  """
  @type session :: %{required(:session_id) => term(), optional(:pid) => pid()}

  @doc """
  Subscribe the CALLING process to this session's live event stream.
  Must be called from the process that wants to receive events -- after
  a `:ok` return, that process receives `{:session_event, session_id,
  event}` messages, where `event` is a map or struct the caller
  normalizes via `Raxol.Harness.EventBoundary.normalize/1` before it ever
  reaches the projection/status-strip pipeline.
  """
  @callback subscribe(session()) :: :ok | {:error, term()}

  @doc """
  Fire-and-forget dispatch of an interrupt command -- the supervised kill
  of the running turn. See the moduledoc: acknowledgment is
  EVENT-OBSERVED (durable stage events on the same stream `subscribe/1`
  delivers), so this callback defines no reply payload beyond dispatch
  success/failure itself.
  """
  @callback interrupt(session(), payload :: map()) :: :ok | {:error, term()}

  @doc """
  Synchronous typed steer decision. `request` carries `:text`,
  `:expected_turn_id`, and `:client_msg_id` (mirroring
  `Raxol.Agent.Steer.Request`). The result vocabulary mirrors the agent
  lane's steer compare-and-swap decision core:

    * `{:ok, {:accepted, ref}}` -- the steer landed in the running turn.
    * `{:ok, {:duplicate, ref}}` -- the same `client_msg_id` was already
      accepted; this re-delivery references the ORIGINAL accept.
    * `{:error, {:stale_turn, expected, actual}}` -- the CAS lost; nothing
      was journaled (see moduledoc).
    * `{:error, :no_live_turn}` -- no turn is currently running.
    * `{:error, :client_msg_id_reuse}` -- the same idempotency key
      arrived carrying different content.
    * `{:error, term()}` -- any other dispatch failure, INCLUDING
      `{:error, :timeout}` for an unbounded wait -- implementations must
      be bounded and translate a timeout rather than hang the caller
      forever.
  """
  @callback steer(session(), request :: map()) ::
              {:ok, {:accepted, map()}}
              | {:ok, {:duplicate, map()}}
              | {:error, term()}

  @doc """
  Fire-and-forget dispatch of a user prompt -- the `:submit` command
  (the composer's Enter). `request` carries at minimum a binary `:text`.

  Like `interrupt/2` (and UNLIKE `steer/2`), acceptance is EVENT-OBSERVED,
  not carried by the reply: a submit the session accepts opens a turn, and
  the `:turn_started` event (payload `%{prompt: ...}`) that lands on the
  SAME stream `subscribe/1` delivers IS the acknowledgment -- the surface
  echoes the prompt into history only when that event is observed, never
  optimistically on this call's return. The reply here therefore reports
  DISPATCH outcome only:

    * `:ok` -- the prompt was handed to the session's inbound command path.
    * `{:error, :busy}` -- the session already has a turn in flight and
      refused a second (ACP's `session/prompt` returns JSON-RPC `-32600`
      here; one turn per session is the honesty invariant the driver ALSO
      guards locally via its `current_turn_id` belief before this call).
    * `{:error, term()}` -- any other dispatch/validation failure (a
      malformed request, no inbound channel, etc.).

  A `{:error, :busy}` (or any error) means no turn opened, so no
  `:turn_started` will follow -- the caller keeps the draft rather than
  echoing a prompt the session never accepted.

  The `session()` is addressed by its `:session_id` (the ACP `session/prompt`
  request is likewise sessionId-addressed) -- the seam carries no
  connection or turn handle, so a lane serving either the Command/
  SessionStreamer stack or an ACP connection can implement it without a
  shape change here.
  """
  @callback submit(session(), request :: map()) :: :ok | {:error, term()}

  @doc """
  Answer a pending approval (the ACP `session/request_permission` the
  agent parked, blocking its turn task). `answer` carries `:request_id`
  (the correlation id echoed back so the agent matches the parked
  request), `:option_id` (the concrete `PermissionOption` the operator
  chose -- the referent, resolved by `Raxol.Harness.Surface` from the
  live block's actual options), and `:decision` (`:allow`/`:deny`, a
  best-effort class hint for the caller's own notice).

  Like `interrupt/2`, this is **fire-and-forget with an EVENT-OBSERVED
  acknowledgment**: the lane replies to the parked ACP request with the
  chosen option AND emits a durable `approval_decided` event on the SAME
  stream `subscribe/1` delivers. That event -- not any reply here -- is
  what folds the decision receipt into the live approval block and
  releases the seal frontier (see `Raxol.Harness.Projection.BlockBuilder`).
  So this callback defines no reply payload beyond dispatch success.

  Fail-closed is INHERITED, not re-implemented here: if the surface dies
  or disconnects before an answer is ever dispatched, the agent-side ACP
  session denies the parked request on its own (its cancel/disconnect
  path replies `{:ok, :cancelled}` to every pending permission). A lane
  need only handle the answers it actually receives.
  """
  @callback answer_permission(session(), answer :: map()) ::
              :ok | {:error, term()}

  @doc """
  Monitor the session process for death honesty (`Process.monitor/1`
  under the hood on the agent side). Returns `nil` when there is no
  `:pid` to monitor -- a session handle that never carried a pid is not
  a failure to monitor, it is simply nothing to watch.
  """
  @callback monitor(session()) :: reference() | nil
end
