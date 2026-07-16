defmodule Raxol.Agent.Meta do
  @moduledoc """
  The U11 meta-event family seam — producer-strict emit + reader-tolerant
  decode, plus the provenance / taint / actor / fingerprint folds
  (`docs/proposals/in-flight/harness-freeze-contracts.md` §2, FI-5).

  ## Enabler status (U11-R)

  This module is the **enabler skeleton** for the U11 red suite: every seam and
  fold below is declared with its frozen signature and returns `:not_implemented`
  (the folds) / raises-through it, so the failing-first U11-R tests compile and
  fail against the real contract. `Raxol.Agent.Meta.Registry` already carries the
  frozen type table as data; the behaviour here is **U11-I implementation work**.

  Do not "make the reds pass" by hardcoding here without the real algebra — the
  negative controls (`u11_meta_controls_test.exs`) exist precisely to catch a
  seam that pretends to validate/derive but doesn't.

  ## The two seams (frozen strictness, §0 clause 2)

    * **Producer / emit seam (strict)** — `validate/1`: emitting a `family: :meta`
      event whose `type` is unregistered, or whose payload misses a required key,
      is a loud typed reject BEFORE anything is journaled or published.
    * **Reader / decode seam (tolerant)** — `decode/1`: an unknown meta type (or
      unknown provenance source / status) from a future-version journal is
      skipped by typed folds and preserved raw — never an error, never damaged.

  ## The folds (all derive from the journal, never a side table)

    * `derive_taint/1` — the two-point tainted-absorbing taint algebra over
      `refs` (FI-5). Checkable, foldable, no laundering in v1.
    * `taint_violations/1` — where a record's STORED trust disagrees with the
      derived answer: an alarm + `:taint_violation` marker, NEVER a hard reject
      (OQ-U11.3).
    * `fold_actors/1` — envelope actor per event; absent actor folds to
      `%{kind: :system}` by rule.
    * `loop_projection/1` — the loop-only fold; meta events never perturb it.
    * `what_produced/2` — fingerprint precedence: `item_completed` fp wins "what
      produced this content" over a `turn_started` override and the head config.
  """

  alias Raxol.Agent.Contract.Event

  @not_implemented :not_implemented

  @typedoc "A journal record as returned by the tolerant Reader: string-keyed map."
  @type jrecord :: %{optional(String.t()) => term()}

  @typedoc "The frozen taint lattice (v1): two points, tainted-absorbing."
  @type trust :: :trusted | :tainted

  # --- producer seam (strict) ------------------------------------------------

  @doc """
  Validate a meta event about to be emitted (producer-strict seam).

  Frozen return contract:

    * `:ok` — registered type, all required payload keys present, scope legal.
    * `{:error, {:unknown_meta_type, type}}` — type not in the registry.
    * `{:error, {:invalid_meta_payload, type, missing}}` — required key(s) absent.
    * `{:error, :provenance_required}` — `promote` with `refs: []`.
    * `{:error, {:scope_violation, type}}` — `scope: :global` on a non-`promote`.

  Loud reject ⇒ nothing journaled, nothing on the bus. `:not_implemented` until U11-I.
  """
  @spec validate(Event.t() | map()) ::
          :ok
          | {:error, {:unknown_meta_type, atom()}}
          | {:error, {:invalid_meta_payload, atom(), [atom()]}}
          | {:error, :provenance_required}
          | {:error, {:scope_violation, atom()}}
          | :not_implemented
  def validate(_event), do: @not_implemented

  # --- reader seam (tolerant) ------------------------------------------------

  @doc """
  Decode a journal record into an `Event` (reader-tolerant seam).

  Always `{:ok, event}` — an unknown meta type / source / status is preserved
  raw and never errors. Missing envelope keys decode to the frozen defaults
  (`scope: :session`, `provenance: %{source: :primary, trust: :trusted}`,
  `actor: nil`). `:not_implemented` until U11-I.
  """
  @spec decode(jrecord()) :: {:ok, Event.t()} | :not_implemented
  def decode(_record), do: @not_implemented

  @doc """
  Encode an `Event` to a JSON binary, post-sanitize (codec round-trip surface).

  Round-tripping every registry meta type through `encode/1` |> `decode/1` is
  byte-stable. `:not_implemented` until U11-I.
  """
  @spec encode(Event.t()) :: binary() | :not_implemented
  def encode(_event), do: @not_implemented

  # --- taint algebra (FI-5) --------------------------------------------------

  @doc """
  Derive the trust of every `family: :meta` event by the frozen taint algebra:
  tainted-absorbing over the events named in `refs` (and the producer input).

  Returns `%{offset => trust}` for meta events only. Loop events keep their
  stamped trust (the entry point is `tool_result`). No laundering in v1 — trust
  never upgrades `:tainted → :trusted`. `:not_implemented` until U11-I.
  """
  @spec derive_taint([jrecord()]) ::
          %{non_neg_integer() => trust()} | :not_implemented
  def derive_taint(_records), do: @not_implemented

  @doc """
  Where a record's STORED trust disagrees with `derive_taint/1`.

  Returns a list of `%{offset, stored, derived}` `:taint_violation` markers.
  Per OQ-U11.3 this is an alarm + observable fold marker, NEVER a hard reject or
  journal damage — replay of a violated journal stays `{:ok, _}`.
  `:not_implemented` until U11-I.
  """
  @spec taint_violations([jrecord()]) ::
          [%{offset: non_neg_integer(), stored: trust(), derived: trust()}]
          | :not_implemented
  def taint_violations(_records), do: @not_implemented

  # --- actor / scope / precedence folds --------------------------------------

  @doc """
  Envelope actor per `kind: "event"` record; absent actor folds to
  `%{kind: :system}` by rule (never inferred as human/agent). Non-event records
  carry no actor. `:not_implemented` until U11-I.
  """
  @spec fold_actors([jrecord()]) ::
          %{non_neg_integer() => map()} | :not_implemented
  def fold_actors(_records), do: @not_implemented

  @doc """
  Scope-discipline check over a journal: `scope: :global` appears only on
  `promote`, every `promote` has `refs != []`, and each ref resolves to a
  record. Returns `:ok` or a list of violations. `:not_implemented` until U11-I.
  """
  @spec check_scope([jrecord()]) :: :ok | [map()] | :not_implemented
  def check_scope(_records), do: @not_implemented

  @doc """
  The loop-only fold projection: meta events are filtered out before any
  loop-typed logic. Folding over an interleaved journal equals folding over the
  meta-stripped journal. `:not_implemented` until U11-I.
  """
  @spec loop_projection([jrecord()]) :: term()
  def loop_projection(_records), do: @not_implemented

  @doc """
  The fingerprint governing "what produced this content" for the
  `item_completed` at `offset`: the item's own fingerprint wins over any
  `turn_started` override (that governs "what was asked") and the head config
  (defaults only). `:not_implemented` until U11-I.
  """
  @spec what_produced([jrecord()], non_neg_integer()) ::
          map() | nil | :not_implemented
  def what_produced(_records, _offset), do: @not_implemented
end
