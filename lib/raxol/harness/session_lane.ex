defmodule Raxol.Harness.SessionLane do
  @moduledoc """
  The behaviour a live agent session lane implements for the harness
  surface. `raxol_agent` 2.7.0 declares it; nothing in this repository
  implements or calls it.

  `subscribe/1` delivers the session's events to the caller, `interrupt/2`
  and `steer/2` send its two commands, and `monitor/1` watches the session
  process.

  `interrupt/2` has no reply beyond dispatch: its outcome arrives as events
  on the subscribed stream (`:interrupt_signaled`, `:interrupt_waited`,
  `:interrupt_killed` or `:interrupt_kill_failed`, `:turn_canceled`).
  `steer/2` replies, because a lane emits no event for a steer it rejects.

  `session()` is a plain map, never a struct.
  """

  @typedoc """
  A live session handle: at minimum a `:session_id`, optionally the
  session process's `:pid`, which `monitor/1` uses.
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
  `:expected_turn_id`, and `:client_msg_id`. The results:

    * `{:ok, {:accepted, ref}}` -- the steer landed in the running turn.
    * `{:ok, {:duplicate, ref}}` -- the same `client_msg_id` was already
      accepted; this re-delivery references the ORIGINAL accept.
    * `{:error, {:stale_turn, expected, actual}}` -- the CAS lost; nothing
      was journaled.
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
  Monitor the session process for death honesty (`Process.monitor/1`
  under the hood on the agent side). Returns `nil` when there is no
  `:pid` to monitor -- a session handle that never carried a pid is not
  a failure to monitor, it is simply nothing to watch.
  """
  @callback monitor(session()) :: reference() | nil
end
