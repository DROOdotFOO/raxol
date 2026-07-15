defmodule Raxol.Harness.Fixture.Event do
  @moduledoc """
  The decoded `body` of a fixture `Envelope` — one observable step of an
  agent run, per `harness-spec-protocol.md` §3.

  Field names are aligned with the shipped `Raxol.Agent.Contract.Event`
  (PR #542, `packages/raxol_agent/lib/raxol/agent/contract.ex`): `id`,
  `turn_id`, `ts`, `family`, `type`, `tier`, `payload` match exactly.
  `scope` and `provenance` are not yet in Contract v0 — they are optional
  here and filled with defaults by `Raxol.Harness.Fixture.Upcast` so
  fixtures recorded before those fields existed still load (the upcast
  story, 06-projection §1.2).
  """

  @enforce_keys [:id, :ts, :family, :type, :tier, :payload]
  defstruct [
    :id,
    :turn_id,
    :ts,
    :family,
    :type,
    :tier,
    :scope,
    :provenance,
    :payload
  ]

  @type family :: :loop | :meta
  @type tier :: :ephemeral | :durable
  @type scope :: :session | :global
  @type provenance :: %{source: String.t(), trust: :trusted | :tainted}

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          turn_id: String.t() | nil,
          ts: integer(),
          family: family(),
          type: atom(),
          tier: tier(),
          scope: scope() | nil,
          provenance: provenance() | nil,
          payload: map()
        }
end
