defmodule Raxol.AgentClientProtocol.Telemetry do
  @moduledoc """
  The classified registry of every `:telemetry` event this package emits.

  This module exists because the package already *detected* its own impossible
  states and then did nothing about them: `Session` emits
  `[:raxol, :acp, :zero_updates_turn]` (and logs a warning) when a turn
  completes without a single `session/update` for a non-empty prompt, and a bug
  that did exactly that shipped anyway -- because no test ever asserted on the
  event. Detection without enforcement is not a guard.

  ## The three classes

    * `:invariant` -- can only fire if RAXOL ITSELF is wrong. Enforced: it must
      never fire during our own test run. `Raxol.AgentClientProtocol.Test.InvariantSentinel`
      turns any occurrence into a test failure.
    * `:peer` -- caused by the remote agent/client misbehaving: a malformed
      frame, an unknown notification, a duplicate or late id. Negative tests
      drive these on purpose. Not enforced.
    * `:operational` -- normal life: a delivery decision, backpressure shed, a
      policy verdict, an idle reap. Not enforced.

  ## The classification criterion, applied literally

  If a peer, the network, the filesystem, the clock, or a user of this library
  can cause the event, it is NOT an invariant. Err toward `:peer` or
  `:operational`: a false invariant makes the suite flaky and gets the whole
  mechanism deleted, which is strictly worse than a missed one.

  ## Adding an event

  `test/telemetry_registry_test.exs` parses `lib/` for `[:raxol, ...]` event
  literals and fails if any is missing from `events/0` (or if `events/0` claims
  an event no source file mentions). A new event therefore cannot land without
  someone classifying it here, and the one-line WHY comment on each row below is
  the artifact that author reads.
  """

  @typedoc "Telemetry event name, as passed to `:telemetry.execute/3`."
  @type event :: [atom()]

  @typedoc "Enforcement class. See the moduledoc for the criterion."
  @type class :: :invariant | :peer | :operational

  # Every event emitted from `lib/`, with the WHY for its class. Keep this list
  # sorted by event name so a diff adding a row is easy to read.
  @events %{
    # An attach-policy verdict. A denial is the policy doing its job: the
    # grant was absent, expired, out-of-scope, or the user's policy module
    # said no. All caller/user-driven.
    [:raxol, :acp, :attach, :denied] => :operational,
    # The other half of the same verdict pair; the ordinary allow path.
    [:raxol, :acp, :attach, :granted] => :operational,
    # Emitted for EVERY session/update delivery decision (:emit | :buffer |
    # :gap | :fail, ADR-0030). The happy path fires it, so the event name
    # carries no error signal at all -- the decision is in the metadata.
    [:raxol, :acp, :delivery] => :operational,
    # Replying twice (or after cancel/adopter-DOWN) to one delegated
    # `reply_ref` is OUR bookkeeping error: the Connection owns the
    # reply-obligation table, and no peer or user input can make it discharge
    # an obligation it already consumed.
    [:raxol, :acp, :dup_reply] => :invariant,
    # A peer reusing an id that is still in flight. Purely a peer's framing
    # mistake; Inv-14 drives it deliberately.
    [:raxol, :acp, :duplicate_inflight_id] => :peer,
    # A caller (the agent implementation using this library) tried to stream an
    # empty content chunk. User-side API misuse, rejected at the seam.
    [:raxol, :acp, :empty_chunk_rejected] => :operational,
    # A user-supplied request/notification handler raised or exited. The
    # crashing code is not ours; containing it is.
    [:raxol, :acp, :handler_crash] => :operational,
    # Backpressure: the peer offered more concurrent inbound requests than
    # `max_in`. Load-driven, and shedding is the designed response.
    [:raxol, :acp, :inbound_shed] => :operational,
    # A peer sent something that decoded but is not a legal request frame
    # (e.g. a JSON-RPC batch array). Peer framing.
    [:raxol, :acp, :invalid_request_frame] => :peer,
    # A non-holder Writer observed a turn_completed whose durable append was
    # refused. Reached by concurrent attach topologies the *caller* builds
    # (two surfaces racing one turn), not by a library bug on its own.
    [:raxol, :acp, :journal, :non_holder_turn_completed] => :operational,
    # A response arrived for an id we no longer have pending -- the peer
    # answered after our timeout, or answered twice.
    [:raxol, :acp, :late_response] => :peer,
    # A peer's response object is missing/duplicating result/error. Peer
    # framing.
    [:raxol, :acp, :malformed_response] => :peer,
    # Backpressure on the notification dispatch path; same load argument as
    # `:inbound_shed`.
    [:raxol, :acp, :notification_shed] => :operational,
    # A peer sent bytes that are not JSON. Peer framing, by definition.
    [:raxol, :acp, :parse_error] => :peer,
    # The idle timer fired. Clock-driven and intended.
    [:raxol, :acp, :session_idle_reaped] => :operational,
    # A peer sent a notification method we do not route, or one whose params
    # failed to decode. Peer conformance.
    [:raxol, :acp, :unknown_notification] => :peer,
    # A turn completed normally for a non-empty prompt having posted zero
    # `session/update` notifications (ADR-0030's delivery contract, cleanroom
    # spec 3.3). Inside our own suite the turn runner IS us, so this can only
    # fire when our session/turn/delivery plumbing swallowed the stream -- the
    # exact bug that shipped undetected and the reason this registry exists.
    # A test that legitimately drives a no-update turn declares it with
    # `@tag expect_invariant:`, which asserts the event fires.
    [:raxol, :acp, :zero_updates_turn] => :invariant
  }

  @invariant_events @events
                    |> Enum.filter(fn {_event, class} -> class == :invariant end)
                    |> Enum.map(fn {event, _class} -> event end)
                    |> Enum.sort()

  @doc """
  Every telemetry event this package emits, mapped to its enforcement class.
  """
  @spec events() :: %{event() => class()}
  def events, do: @events

  @doc """
  The `:invariant` subset of `events/0`, sorted. This is what the sentinel arms.
  """
  @spec invariant_events() :: [event()]
  def invariant_events, do: @invariant_events

  @doc """
  The class of `event`, or `nil` when it is not registered.
  """
  @spec classify(event()) :: class() | nil
  def classify(event) when is_list(event), do: Map.get(@events, event)
end
