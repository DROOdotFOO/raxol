defmodule Raxol.ACP.Event do
  @moduledoc """
  Event-type union for the v2 event-driven model.

  In v1 the seller agent registered two callbacks (`onNewTask`,
  `onEvaluate`); v2 collapses this into a single
  `on("entry", handler)` with role-aware semantics. This module defines
  the canonical event-type strings the v2 SDK emits and the payload
  shapes for each.

  Canonical event-type strings (mirroring `acp-node-v2`):

      "job.created" | "budget.set" | "job.funded"
      "job.submitted" | "job.completed" | "job.rejected" | "job.expired"

  Phase-to-event mapping vs v1:

  | v1 phase     | v2 event       |
  |--------------|----------------|
  | REQUEST      | job.created    |
  | NEGOTIATION  | budget.set     |
  | TRANSACTION  | job.funded     |
  | EVALUATION   | job.submitted  |
  | COMPLETED    | job.completed  |
  | REJECTED     | job.rejected   |
  | (expired)    | job.expired    |
  """

  @type t ::
          {:job_created, payload()}
          | {:budget_set, payload()}
          | {:job_funded, payload()}
          | {:job_submitted, payload()}
          | {:job_completed, payload()}
          | {:job_rejected, payload()}
          | {:job_expired, payload()}

  @type payload :: %{
          required(:job_id) => String.t() | non_neg_integer(),
          required(:chain_id) => pos_integer(),
          required(:actor) => String.t(),
          required(:timestamp_ms) => non_neg_integer(),
          optional(:budget) => Raxol.ACP.AssetToken.t(),
          optional(:transfer_amount) => Raxol.ACP.AssetToken.t(),
          optional(:destination) => String.t(),
          optional(:deliverable) => term(),
          optional(:reason) => String.t(),
          optional(:tx_hash) => String.t(),
          optional(:client) => String.t(),
          optional(:provider) => String.t(),
          optional(:evaluator) => String.t()
        }

  @event_types ~w(job.created budget.set job.funded job.submitted job.completed job.rejected job.expired)

  @doc """
  Decode a wire-format event-type string into the matching atom tuple
  key.

      iex> Raxol.ACP.Event.decode_type("job.created")
      {:ok, :job_created}

      iex> Raxol.ACP.Event.decode_type("nope")
      {:error, :unknown_event_type}
  """
  @spec decode_type(String.t()) :: {:ok, atom()} | {:error, :unknown_event_type}
  def decode_type(string) when is_binary(string) do
    if string in @event_types do
      atom = string |> String.replace(".", "_") |> String.to_atom()
      {:ok, atom}
    else
      {:error, :unknown_event_type}
    end
  end

  @doc "Inverse of `decode_type/1`: render an atom back to its wire string."
  @spec encode_type(atom()) :: String.t()
  def encode_type(:job_created), do: "job.created"
  def encode_type(:budget_set), do: "budget.set"
  def encode_type(:job_funded), do: "job.funded"
  def encode_type(:job_submitted), do: "job.submitted"
  def encode_type(:job_completed), do: "job.completed"
  def encode_type(:job_rejected), do: "job.rejected"
  def encode_type(:job_expired), do: "job.expired"

  @doc "Terminal event types -- the session is done after one of these."
  @spec terminal?(atom()) :: boolean()
  def terminal?(type) when type in [:job_completed, :job_rejected, :job_expired], do: true
  def terminal?(_), do: false

  @doc "All canonical event-type strings, in lifecycle order."
  @spec all_types() :: [String.t()]
  def all_types, do: @event_types
end
