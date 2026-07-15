defmodule Raxol.Harness.Fixture.Header do
  @moduledoc """
  Line 1 of a harness fixture JSONL file: schema + provenance tags for the
  whole recorded session (FI-2: every transcript version-tagged).

  See `docs/proposals/in-flight/harness-ui-testing/06-projection.md` §1.1.
  """

  @enforce_keys [
    :schema,
    :envelope_v,
    :harness_version,
    :backend,
    :model,
    :config_hash,
    :kind
  ]
  defstruct [
    :schema,
    :envelope_v,
    :harness_version,
    :backend,
    :model,
    :config_hash,
    :kind,
    :recorded_at,
    :name,
    :notes,
    pathologies: []
  ]

  @type kind :: :golden | :adversarial

  @typedoc """
  One machine-readable corruption entry of an adversarial fixture:
  `class` names the pathology (matches the table in the sibling
  `.notes.md`), `offset` is the 1-based physical line it lives at.
  Downstream tests seek named corruptions via
  `Raxol.Harness.Fixture.Session.pathologies/1` instead of hardcoding
  line numbers.
  """
  @type pathology :: %{class: String.t(), offset: pos_integer()}

  @type t :: %__MODULE__{
          schema: String.t(),
          envelope_v: pos_integer(),
          harness_version: String.t(),
          backend: String.t(),
          model: String.t(),
          config_hash: String.t(),
          kind: kind(),
          recorded_at: String.t() | nil,
          name: String.t() | nil,
          notes: String.t() | nil,
          pathologies: [pathology()]
        }
end
