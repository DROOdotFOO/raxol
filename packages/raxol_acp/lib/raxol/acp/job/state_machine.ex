defmodule Raxol.ACP.Job.StateMachine do
  @moduledoc """
  Pure functional state machine for an ACP job.

  Per the Virtuals ACP spec (mirrored from `AcpJobPhase` in the
  canonical `openclaw-acp` SDK), every job moves through:

      :request -> :negotiation -> :transaction -> :evaluation -> :completed

  A buyer's `:request` can be `:reject`ed by the seller (state 5 in the
  canonical enum), and any non-terminal state can `:expire` (SLA breach
  or buyer cancellation). `:completed`, `:rejected`, and `:expired` are
  terminal -- no further transitions are valid.

  ## State -> canonical phase id mapping

  | raxol state    | AcpJobPhase enum | id |
  |----------------|------------------|----|
  | :request       | REQUEST          | 0  |
  | :negotiation   | NEGOTIATION      | 1  |
  | :transaction   | TRANSACTION      | 2  |
  | :evaluation    | EVALUATION       | 3  |
  | :completed     | COMPLETED        | 4  |
  | :rejected      | REJECTED         | 5  |
  | :expired       | EXPIRED          | 6  |

  This module is intentionally a pure module, not a `:gen_statem` --
  no precedent for `:gen_statem` exists in the raxol codebase, and the
  per-job process (`Raxol.ACP.Job.Server`) holds the current state in
  its own struct field, calling `next/2` here for transition validation.

  ## Events

  - `:accept_request` -- seller accepts the buyer's request
  - `:reject` -- seller rejects the buyer's request; valid only from `:request`
  - `:accept_payment` -- buyer's payment authorization is recorded;
    escrow holds funds
  - `:deliver` -- seller submits the deliverable
  - `:approve` -- evaluator (or buyer) approves the deliverable
  - `:expire` -- timeout / cancellation; valid from any non-terminal state
  """

  @type state ::
          :request | :negotiation | :transaction | :evaluation | :completed | :rejected | :expired
  @type event :: :accept_request | :reject | :accept_payment | :deliver | :approve | :expire

  @states [:request, :negotiation, :transaction, :evaluation, :completed, :rejected, :expired]
  @events [:accept_request, :reject, :accept_payment, :deliver, :approve, :expire]
  @terminal [:completed, :rejected, :expired]
  @non_terminal [:request, :negotiation, :transaction, :evaluation]

  @doc "Return the canonical initial state for a fresh job."
  @spec initial() :: state()
  def initial, do: :request

  @doc "Return all defined states."
  @spec states() :: [state()]
  def states, do: @states

  @doc "Return all defined events."
  @spec events() :: [event()]
  def events, do: @events

  @doc "Return `true` for terminal states (`:completed`, `:rejected`, `:expired`)."
  @spec terminal?(state()) :: boolean()
  def terminal?(state) when state in @terminal, do: true
  def terminal?(state) when state in @non_terminal, do: false

  @doc """
  Compute the next state for a given current state and event.

  Returns `{:ok, new_state}` for a valid transition or
  `{:error, {:invalid_transition, state, event}}` otherwise.
  """
  @spec next(state(), event()) ::
          {:ok, state()} | {:error, {:invalid_transition, state(), event()}}
  def next(:request, :accept_request), do: {:ok, :negotiation}
  def next(:request, :reject), do: {:ok, :rejected}
  def next(:negotiation, :accept_payment), do: {:ok, :transaction}
  def next(:transaction, :deliver), do: {:ok, :evaluation}
  def next(:evaluation, :approve), do: {:ok, :completed}

  def next(state, :expire) when state in @non_terminal, do: {:ok, :expired}

  def next(state, event), do: {:error, {:invalid_transition, state, event}}

  @doc """
  Map a state atom to the canonical `AcpJobPhase` numeric id (matches
  `openclaw-acp`'s on-the-wire enum).
  """
  @spec phase_id(state()) :: 0..6
  def phase_id(:request), do: 0
  def phase_id(:negotiation), do: 1
  def phase_id(:transaction), do: 2
  def phase_id(:evaluation), do: 3
  def phase_id(:completed), do: 4
  def phase_id(:rejected), do: 5
  def phase_id(:expired), do: 6

  @doc "Inverse of `phase_id/1`. Returns `:error` for unknown ids."
  @spec from_phase_id(non_neg_integer()) :: {:ok, state()} | :error
  def from_phase_id(0), do: {:ok, :request}
  def from_phase_id(1), do: {:ok, :negotiation}
  def from_phase_id(2), do: {:ok, :transaction}
  def from_phase_id(3), do: {:ok, :evaluation}
  def from_phase_id(4), do: {:ok, :completed}
  def from_phase_id(5), do: {:ok, :rejected}
  def from_phase_id(6), do: {:ok, :expired}
  def from_phase_id(_), do: :error
end
