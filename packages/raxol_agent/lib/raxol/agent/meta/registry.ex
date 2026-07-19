defmodule Raxol.Agent.Meta.Registry do
  @moduledoc """
  U11 meta-event type registry — the **frozen** type table as data (see
  `docs/harness/architecture.md`, "The event contract").

  This is the U11 *enabler*: the table is real, checked-in data so the U11-R
  red suite (and, later, the U11-I implementation) both read one source of
  truth for "which meta types exist, what payload keys each requires, and what
  scope each carries". The registry is **grow-only**: entries are immutable, new
  types are appended, and no registered type is ever renamed, repurposed, or
  type-narrowed.

  ## What lives here vs. what is U11-I work

  Only the *table* is frozen here. The **seams** that consume it — the
  producer-strict validator, the reader-tolerant decoder, and the taint /
  actor / precedence folds — live in `Raxol.Agent.Meta` and return
  `:not_implemented` until U11-I lands. The red suite asserts those seams meet
  the frozen contract; they fail until implemented (that is the point of a
  failing-first suite).
  """

  @typedoc "A registry entry: the required payload keys and the event scope."
  @type entry :: %{required: [atom()], scope: :session | :global}

  # The frozen v1 meta type registry (protocol §3-meta). `refs` is the uniform
  # annotation key required on EVERY meta type — a list of journal offsets. Do
  # not reorder or repurpose; additions go at the end of the map.
  @types %{
    gate_decision: %{
      required: [:gate, :score, :threshold, :choice, :seed, :refs],
      scope: :session
    },
    extract: %{required: [:class, :op, :item, :refs], scope: :session},
    residual: %{required: [:description, :refs], scope: :session},
    calibrate: %{
      required: [:gate, :observed_score, :quantile, :new_threshold, :refs],
      scope: :session
    },
    verdict: %{
      required: [:family, :drift_score, :advice, :refs],
      scope: :session
    },
    research: %{required: [:conclusion, :refs], scope: :session},
    # The ONLY :global type; additionally requires refs != [] (provenance-mandatory).
    promote: %{required: [:item, :justification, :refs], scope: :global},
    probe_run: %{
      required: [:probe, :run_id, :status, :charge, :refs],
      scope: :session
    },
    attach: %{
      required: [:from_offset, :history_policy, :surface, :refs],
      scope: :session
    },
    speculation: %{
      required: [:phase, :branch_ref, :outcome, :refs],
      scope: :session
    },
    approval_decided: %{
      required: [:request_ref, :decision, :refs],
      scope: :session
    },
    policy_amended: %{
      required: [:scope, :rule_id, :before, :after, :source, :refs],
      scope: :session
    }
  }

  # Grow-only provenance source registry (§2.1). Readers render unknown sources
  # as opaque labels; this list is for the producer/audit side only.
  @sources [
    :primary,
    :surface,
    :probe_c1_gate,
    :probe_c2_rules,
    :probe_c2_residual,
    :probe_c6_verdict,
    :probe_c7,
    :probe_c5,
    :probe_meta_adr
  ]

  @doc "The whole frozen table (type => entry)."
  @spec types() :: %{atom() => entry()}
  def types, do: @types

  @doc "Every registered meta type, as a list."
  @spec type_names() :: [atom()]
  def type_names, do: Map.keys(@types)

  @doc "Whether `type` is a registered meta type."
  @spec known?(atom()) :: boolean()
  def known?(type), do: Map.has_key?(@types, type)

  @doc "The required payload keys for `type`, or `nil` if unknown."
  @spec required_keys(atom()) :: [atom()] | nil
  def required_keys(type) do
    case @types do
      %{^type => %{required: keys}} -> keys
      _ -> nil
    end
  end

  @doc "The frozen scope for `type`, or `nil` if unknown."
  @spec scope(atom()) :: :session | :global | nil
  def scope(type) do
    case @types do
      %{^type => %{scope: scope}} -> scope
      _ -> nil
    end
  end

  @doc "The known provenance sources (grow-only)."
  @spec sources() :: [atom()]
  def sources, do: @sources
end
