defmodule Raxol.Agent.Meta do
  @moduledoc """
  The U11 meta-event family seam — producer-strict emit + reader-tolerant
  decode, plus the provenance / taint / actor / fingerprint folds
  (`docs/proposals/in-flight/harness-freeze-contracts.md` §2, FI-5).

  `Raxol.Agent.Meta.Registry` carries the frozen v1 type table as data; this
  module is the algebra that consumes it. Every fold derives from the journal
  records themselves — never a side table — so a fold over a journal is the same
  whether the journal is live or replayed from disk.

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

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Meta.Registry

  @default_provenance %{source: :primary, trust: :trusted}

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

  A loud reject means nothing is journaled and nothing reaches the bus. A
  non-meta event (or one with no `:type`) is always `:ok` — this seam only
  governs the meta family.
  """
  @spec validate(Event.t() | map()) ::
          :ok
          | {:error, {:unknown_meta_type, atom()}}
          | {:error, {:invalid_meta_payload, atom(), [atom()]}}
          | {:error, :provenance_required}
          | {:error, {:scope_violation, atom()}}
  def validate(%Event{family: family, type: type, payload: payload, scope: scope}) do
    validate(%{family: family, type: type, payload: payload, scope: scope})
  end

  def validate(%{family: :meta, type: type, payload: payload} = event) do
    scope = Map.get(event, :scope, :session)

    cond do
      not Registry.known?(type) ->
        {:error, {:unknown_meta_type, type}}

      (missing = missing_keys(type, payload)) != [] ->
        {:error, {:invalid_meta_payload, type, missing}}

      type == :promote and Map.get(payload, :refs, []) == [] ->
        {:error, :provenance_required}

      scope == :global and Registry.scope(type) != :global ->
        {:error, {:scope_violation, type}}

      true ->
        :ok
    end
  end

  def validate(_non_meta), do: :ok

  defp missing_keys(type, payload) do
    (Registry.required_keys(type) || [])
    |> Enum.reject(fn k -> Map.has_key?(payload, k) end)
  end

  # --- reader seam (tolerant) ------------------------------------------------

  @doc """
  Decode a journal record into an `Event` (reader-tolerant seam).

  Always `{:ok, event}` — a KNOWN meta type / source / status resolves to its
  interned atom, while an UNKNOWN token is preserved RAW as a binary (never
  materialized into a fresh atom — an atom-table DoS guard) and the payload is
  kept as-is; the seam never errors. Missing envelope keys decode to the frozen
  grandfather defaults
  (`scope: :session`, `provenance: %{source: :primary, trust: :trusted}`,
  `actor: nil`).
  """
  @spec decode(jrecord()) :: {:ok, Event.t()}
  def decode(record) when is_map(record) do
    {:ok,
     %Event{
       v: Map.get(record, "v", 0),
       id: Map.get(record, "id", 0),
       session_id: Map.get(record, "session_id"),
       turn_id: Map.get(record, "turn_id"),
       ts: Map.get(record, "ts", 0),
       family: decode_token(Map.get(record, "family"), :loop),
       type: decode_token(Map.get(record, "type"), nil),
       tier: decode_token(Map.get(record, "tier"), :durable),
       payload: Map.get(record, "payload") || %{},
       scope: decode_token(Map.get(record, "scope"), :session),
       provenance: decode_provenance(Map.get(record, "provenance")),
       actor: decode_actor_field(Map.get(record, "actor")),
       # branch_id is written omit-when-"main" (I2); absent decodes back to the
       # frozen default so a non-default branch round-trips off disk. Without
       # this READ side a non-default branch_id landed on disk but was stranded.
       branch_id: Map.get(record, "branch_id", "main")
     }}
  end

  @doc """
  Encode an `Event` to a JSON binary, post-sanitize (codec round-trip surface).

  Round-tripping every registry meta type through `encode/1` |> `decode/1` is
  byte-stable: the struct serializes in a fixed field order and the payload is
  sanitized to a JSON-encodable shape at the boundary.
  """
  @spec encode(Event.t()) :: binary()
  def encode(%Event{payload: payload} = event) do
    Jason.encode!(%{event | payload: Contract.sanitize_payload(payload || %{})})
  end

  # --- taint algebra (FI-5) --------------------------------------------------

  @doc """
  Derive the trust of every `family: :meta` event by the frozen taint algebra:
  tainted-absorbing over the events named in `refs` (recursively).

  Returns `%{offset => trust}` for meta events only. Loop events anchor the fold
  with their stamped (entry-point) trust — taint enters at `tool_result`. There
  is no laundering in v1: a meta event any of whose refs reach a tainted record
  is `:tainted`, and no path ever upgrades `:tainted → :trusted`.
  """
  @spec derive_taint([jrecord()]) :: %{non_neg_integer() => trust()}
  def derive_taint(records) do
    idx = index(records)

    for r <- records, meta?(r), into: %{} do
      {offset(r), derived_trust(r, idx, MapSet.new())}
    end
  end

  # Recursive tainted-absorbing meet over refs (cycle-guarded). Loop events
  # anchor with their stored trust; meta events derive from their refs.
  defp derived_trust(record, idx, seen) do
    id = offset(record)

    cond do
      MapSet.member?(seen, id) ->
        :trusted

      not meta?(record) ->
        stored_trust(record)

      true ->
        seen = MapSet.put(seen, id)

        tainted? =
          record
          |> refs()
          |> Enum.any?(fn ref ->
            case Map.get(idx, ref) do
              nil -> false
              ref_rec -> derived_trust(ref_rec, idx, seen) == :tainted
            end
          end)

        if tainted?, do: :tainted, else: :trusted
    end
  end

  @doc """
  Where a record's STORED trust disagrees with `derive_taint/1`.

  Returns a list of `%{offset, stored, derived}` `:taint_violation` markers.
  Per OQ-U11.3 this is an alarm + observable fold marker, NEVER a hard reject or
  journal damage — replay of a violated journal stays `{:ok, _}`.
  """
  @spec taint_violations([jrecord()]) ::
          [%{offset: non_neg_integer(), stored: trust(), derived: trust()}]
  def taint_violations(records) do
    derived = derive_taint(records)

    for r <- records, meta?(r), derived[offset(r)] != stored_trust(r) do
      %{offset: offset(r), stored: stored_trust(r), derived: derived[offset(r)]}
    end
  end

  # --- actor / scope / precedence folds --------------------------------------

  @doc """
  Envelope actor per `kind: "event"` record; absent actor folds to
  `%{kind: :system}` by rule (never inferred as human/agent). Non-event records
  (checkpoint/schedule pointers) carry no actor and are skipped.
  """
  @spec fold_actors([jrecord()]) :: %{non_neg_integer() => map()}
  def fold_actors(records) do
    for r <- records, event?(r), into: %{}, do: {offset(r), fold_actor(r)}
  end

  # Absent actor => system, BY RULE (never inferred as human/agent).
  defp fold_actor(%{"actor" => %{"kind" => k} = a}) do
    %{kind: decode_token(k, :system), id: Map.get(a, "id")}
  end

  defp fold_actor(_), do: %{kind: :system}

  @doc """
  Scope-discipline check over a journal: `scope: :global` appears only on
  `promote`, and every `promote` has `refs != []`. Returns `:ok` or a list of
  violation markers.
  """
  @spec check_scope([jrecord()]) :: :ok | [map()]
  def check_scope(records) do
    violations =
      for r <- records, meta?(r), v <- scope_violations(r), do: v

    if violations == [], do: :ok, else: violations
  end

  defp scope_violations(record) do
    type = type(record)

    global_violation =
      if scope(record) == :global and type != :promote,
        do: [%{offset: offset(record), violation: {:scope_violation, type}}],
        else: []

    promote_violation =
      if type == :promote and refs(record) == [],
        do: [%{offset: offset(record), violation: :provenance_required}],
        else: []

    global_violation ++ promote_violation
  end

  @doc """
  The loop-only fold projection: `{offset, type}` of every `family: :loop`
  record, in journal order. Meta events are filtered out before any loop-typed
  logic, so folding over an interleaved journal equals folding over the
  meta-stripped one.
  """
  @spec loop_projection([jrecord()]) :: [{non_neg_integer(), atom()}]
  def loop_projection(records) do
    for r <- records, family(r) == :loop, do: {offset(r), type(r)}
  end

  @doc """
  The fingerprint governing "what produced this content" for the record at
  `offset`: the `item_completed` fingerprint wins over any `turn_started`
  override (which governs "what was asked") and the session head config
  (defaults only). Returns the fingerprint map or `nil`.
  """
  @spec what_produced([jrecord()], non_neg_integer()) :: map() | nil
  def what_produced(records, offset) do
    case Enum.find(records, fn r -> offset(r) == offset end) do
      %{"payload" => %{"fingerprint" => fp}} -> fp
      _ -> nil
    end
  end

  # --- record accessors (string-keyed, Reader-shaped) ------------------------

  defp index(records), do: Map.new(records, fn r -> {offset(r), r} end)

  defp family(%{"family" => f}) when is_binary(f), do: decode_token(f, :loop)
  defp family(%{"family" => f}) when is_atom(f) and not is_nil(f), do: f
  defp family(_), do: :loop

  defp meta?(r), do: family(r) == :meta

  defp type(%{"type" => t}) when is_binary(t), do: decode_token(t, nil)
  defp type(%{"type" => t}) when is_atom(t), do: t
  defp type(_), do: nil

  defp offset(%{"id" => id}), do: id
  defp offset(_), do: nil

  defp refs(%{"payload" => %{"refs" => refs}}) when is_list(refs), do: refs
  defp refs(_), do: []

  defp scope(%{"scope" => s}) when is_binary(s), do: decode_token(s, :session)
  defp scope(%{"scope" => s}) when is_atom(s) and not is_nil(s), do: s
  defp scope(_), do: :session

  defp event?(r), do: Map.get(r, "kind", "event") == "event"

  # STORED trust on a record's provenance. Fail-CLOSED (§2.1 taint law pt.1):
  # only the exact known-trusted token reads :trusted; a PRESENT-but-unrecognized
  # trust value (unknown string, garbage, a future lattice point) reads :tainted.
  # ABSENT provenance is the frozen grandfather default (:trusted) — distinct
  # from a present-but-unrecognized value. This anchors the taint fold's leaves,
  # so a laundered entry point can no longer read trusted.
  defp stored_trust(%{"provenance" => %{"trust" => trust}}), do: trust_token(trust)
  defp stored_trust(%{"provenance" => p}) when is_map(p), do: :trusted
  defp stored_trust(_), do: :trusted

  # The frozen v1 trust lattice is exactly two points; every other token —
  # unknown, garbage, or a future lattice value — fails CLOSED to :tainted
  # (§2.1 taint law pt.1, forward-compat §2.4 "readers fail-closed to :tainted").
  defp trust_token("trusted"), do: :trusted
  defp trust_token(:trusted), do: :trusted
  defp trust_token("tainted"), do: :tainted
  defp trust_token(:tainted), do: :tainted
  defp trust_token(_unknown), do: :tainted

  # --- decode helpers --------------------------------------------------------

  # Decode a PRESENT provenance. Trust fails CLOSED (§2.1 taint law pt.1): an
  # unknown/garbage trust value decodes to :tainted, never laundered to :trusted
  # (a present-but-unrecognized value must NOT read as trusted — §2.4). Absent
  # provenance is handled by the grandfather clause below (:trusted default).
  defp decode_provenance(%{"trust" => trust} = p) do
    %{source: decode_token(Map.get(p, "source"), :primary), trust: trust_token(trust)}
  end

  defp decode_provenance(%{source: _, trust: _} = provenance), do: provenance
  defp decode_provenance(_), do: @default_provenance

  defp decode_actor_field(%{"kind" => k} = a) do
    %{kind: decode_token(k, :system), id: Map.get(a, "id")}
  end

  defp decode_actor_field(%{kind: _} = actor), do: actor
  defp decode_actor_field(_), do: nil

  # Bounded, non-atom-creating decode of a journal token. Every registered
  # family / type / tier / scope / source / actor-kind is already interned, so a
  # KNOWN token resolves to its atom; an UNKNOWN token from a version-skewed,
  # corrupt, or oversized journal is PRESERVED RAW as a binary (contract §0.2
  # "preserve raw", not "materialize atom"), never turned into a fresh atom.
  # `String.to_atom/1` on unbounded journal input exhausts the atom table and
  # crashes the VM — a DoS this codebase forbids exactly (command.ex:75,
  # frame.ex:110). Never raises: the reader seam is tolerant.
  defp decode_token(nil, default), do: default
  defp decode_token(value, _default) when is_atom(value), do: value

  defp decode_token(value, _default) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end
end
