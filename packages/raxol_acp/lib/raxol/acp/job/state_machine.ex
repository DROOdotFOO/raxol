defmodule Raxol.ACP.Job.StateMachine do
  @moduledoc """
  Pure functional state machine for an ACP job.

  Per the Virtuals ACP spec, every job moves through:

      :request -> :negotiation -> :transaction -> :evaluation -> :completed

  Any non-terminal state can also transition to `:expired` (SLA breach
  or buyer cancellation). `:completed` and `:expired` are terminal --
  no further transitions are valid.

  This module is intentionally a pure module, not a `:gen_statem` --
  no precedent for `:gen_statem` exists in the raxol codebase, and the
  per-job process (`Raxol.ACP.Job.Server`) holds the current state in
  its own struct field, calling `next/2` here for transition validation.

  ## Events

  - `:accept_request` -- seller accepts the buyer's request
  - `:accept_payment` -- buyer's payment authorization is recorded;
    escrow holds funds
  - `:deliver` -- seller submits the deliverable
  - `:approve` -- evaluator (or buyer) approves the deliverable
  - `:expire` -- timeout / cancellation; valid from any non-terminal state
  """

  @type state :: :request | :negotiation | :transaction | :evaluation | :completed | :expired
  @type event :: :accept_request | :accept_payment | :deliver | :approve | :expire

  @states [:request, :negotiation, :transaction, :evaluation, :completed, :expired]
  @events [:accept_request, :accept_payment, :deliver, :approve, :expire]
  @terminal [:completed, :expired]
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

  @doc "Return `true` for terminal states (`:completed`, `:expired`)."
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
  def next(:negotiation, :accept_payment), do: {:ok, :transaction}
  def next(:transaction, :deliver), do: {:ok, :evaluation}
  def next(:evaluation, :approve), do: {:ok, :completed}

  def next(state, :expire) when state in @non_terminal, do: {:ok, :expired}

  def next(state, event), do: {:error, {:invalid_transition, state, event}}
end
