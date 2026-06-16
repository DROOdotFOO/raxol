defmodule Raxol.Symphony.PauseReason do
  @moduledoc """
  Canonical formatter and registry for paused-run interrupt reasons.

  Codifies the vocabulary half of the operator-flow contract from
  ADR-0018: pause reasons are atoms in the `:awaiting_<subject>`
  shape, where `<subject>` names the *external party* the run is
  waiting on. Surfaces (Terminal, LiveView, Telegram, Watch, MCP)
  display them through `format/1`; the same fallback chain runs
  everywhere so the rendered string never drifts.

  Before this module, four `format_reason/1` private helpers were
  open-coded across the surfaces. They all agreed by coincidence;
  this module makes the agreement deliberate.

  ## ADR-0018 canonical set

  The atoms documented as canonical at the time ADR-0018 was written:

      iex> Raxol.Symphony.PauseReason.canonical()
      [
        :awaiting_request_response,
        :awaiting_buyer_payment,
        :awaiting_delivery,
        :awaiting_evaluator_approval,
        :awaiting_approval,
        :awaiting_review
      ]

  The vocabulary is open: new runners introduce new atoms without a
  registry update. `format/1` accepts ANY atom and falls back to
  `Atom.to_string/1` so unknown reasons render verbatim and the
  surface remains usable.

  ## Usage

      iex> Raxol.Symphony.PauseReason.format(:awaiting_buyer_payment)
      "awaiting_buyer_payment"

      iex> Raxol.Symphony.PauseReason.format(nil)
      "(unspecified)"

      iex> Raxol.Symphony.PauseReason.format("ad-hoc-string")
      "ad-hoc-string"

      iex> Raxol.Symphony.PauseReason.format({:nonstandard, :tuple})
      "{:nonstandard, :tuple}"
  """

  @canonical [
    :awaiting_request_response,
    :awaiting_buyer_payment,
    :awaiting_delivery,
    :awaiting_evaluator_approval,
    :awaiting_approval,
    :awaiting_review
  ]

  @typedoc """
  Pause reason as it appears in a paused-entry map. `nil` is allowed
  (some pre-Phase-25 callers omit it); arbitrary atoms / strings are
  accepted to preserve forward-compatibility.
  """
  @type t :: atom() | binary() | nil | term()

  @doc """
  Canonical list of interrupt-reason atoms documented in ADR-0018.

  Used by tests to enforce the convention; surfaces should NOT
  filter on this list -- the vocabulary is open.
  """
  @spec canonical() :: [atom()]
  def canonical, do: @canonical

  @doc """
  Predicate that returns true for atoms matching the
  `:awaiting_<subject>` convention.

      iex> Raxol.Symphony.PauseReason.awaiting?(:awaiting_buyer_payment)
      true

      iex> Raxol.Symphony.PauseReason.awaiting?(:waiting_for_buyer)
      false

      iex> Raxol.Symphony.PauseReason.awaiting?(:awaiting_)
      false

      iex> Raxol.Symphony.PauseReason.awaiting?("awaiting_x")
      false
  """
  @spec awaiting?(term()) :: boolean()
  def awaiting?(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom) do
    case Atom.to_string(atom) do
      "awaiting_" <> rest when rest != "" -> true
      _ -> false
    end
  end

  def awaiting?(_), do: false

  @doc """
  Format a pause reason for surface display.

  Atoms are stringified, binaries pass through, nil renders as
  `"(unspecified)"`, and anything else is `inspect/1`-ed so the
  surface stays robust even when a runner emits an unexpected
  shape.
  """
  @spec format(t()) :: String.t()
  def format(nil), do: "(unspecified)"
  def format(reason) when is_atom(reason), do: Atom.to_string(reason)
  def format(reason) when is_binary(reason), do: reason
  def format(other), do: inspect(other)
end
