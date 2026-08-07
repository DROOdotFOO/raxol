defmodule Raxol.Agent.Journal.Records.Checkpoint do
  @moduledoc """
  U9 — checkpoint pointer records (AD-10 / AD-3a).

  A checkpoint is an **in-log pointer record**, not a second store. The snapshot
  payload lives content-addressed and out-of-line at
  `<session>/snapshots/<sha256-hex>.json`; the `checkpoint` record carries only
  the pointer + hash + the conversational tip it was taken at. It is appended
  through the **same single Writer** as every other record, consuming exactly one
  offset from the one id space (JS-FREEZE §1.1 — the offset law;
  single-counter lockstep).

  This module began as the enabler skeleton for the permanent U9-R red suite:
  the frozen record shape (`t/0`) and the `write/3` / `restore/2` seam were
  declared ahead of implementation so the red suite could compile and pin the
  contract. The implementation has since landed: the default backend (no
  registration) is the file-store `FileBackend` below, and `write`/`restore`
  dispatch to it. `{:error, :not_implemented}` remains only the explicit
  nil-backend opt-out.

  ## Write discipline (frozen — JS-FREEZE §1.1)

    * The snapshot file is written **before** the record is appended (a record
      cannot be named by its own offset before it exists — chicken/egg), via the
      FI-8 atomic temp+fsync+rename. A crash between file-write and record-append
      leaves a harmless orphan file (FI-7: never deleted implicitly).
    * `snapshot_hash` = lowercase-hex `sha256` of the snapshot file bytes; it is
      verified at restore. A missing file → `{:error, :snapshot_missing}`; a
      hash mismatch → `{:error, :snapshot_corrupt}` — and in **both** cases the
      journal stays `:ok` and nothing is deleted.
    * `snapshot_ref: nil` is a legal tip-only pointer (OQ-JS1 RULED LEGAL);
      restore then falls back to a full `fold(0..tip_offset)`.
    * `tip_offset` is frozen at write time and validated at write time: the
      record it names MUST satisfy `conversational?/1` on the checkpoint's own
      branch, else `{:error, :invalid_tip}` and **nothing is appended**.
    * A checkpoint MUST NOT be appended mid-turn (between `turn_started` and its
      close) nor mid-reserve (between a spend-gate reserve and its terminal),
      else `{:error, :mid_turn}` / `{:error, :mid_reserve}`.
    * FI-10: the record body carries **no model content** — pointer + hash only.
      Snapshot-content sanitization + MS secret exclusion bind to the MS codec,
      which is not yet landed: the interim surrogate codec typed-rejects any
      non-JSON-native model (`{:error, :surrogate_backend_unbound}`) and writes
      a JSON-safe model **verbatim, with no redaction** — see the "FI-10 scope
      note" in `Checkpoint.FileBackend`'s moduledoc. Re-bind redaction together
      with the codec when MS lands.
  """

  alias Raxol.Agent.Journal.FileStore

  @kind "checkpoint"

  # Grow-only `reason` enum (JS-FREEZE §1.1). Unknown reasons are tolerated on
  # READ (forward-compat, reader-seam tolerance); only these are ever emitted.
  @reasons ~w(manual compaction auto)

  # The complete frozen field set of a checkpoint record (string keys on disk).
  # Used by the red suite's FI-10 contour to assert the record body carries no
  # model content — pointer + hash only.
  @record_keys ~w(id schema_version kind branch_id session_id ts tip_offset snapshot_ref snapshot_hash reason)

  @typedoc """
  A `checkpoint` record — the frozen on-disk shape (string keys on disk; this is
  the Elixir-side view). Every field below is frozen by JS-FREEZE §1.1: none is
  ever renamed, repurposed, type-narrowed, or flipped optional→required.
  """
  @type t :: %{
          id: non_neg_integer(),
          schema_version: String.t(),
          kind: String.t(),
          branch_id: String.t(),
          session_id: String.t(),
          ts: integer(),
          tip_offset: pos_integer(),
          snapshot_ref: String.t() | nil,
          snapshot_hash: String.t() | nil,
          reason: String.t()
        }

  @typedoc "A folded harness model (MS-owned snapshot content; opaque to JS-FREEZE)."
  @type model :: term()

  @doc "The record `kind` string every checkpoint carries."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc "The v1 grow-only `reason` enum accepted by the producer seam."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "The complete frozen key set (plus the defaulted `branch_id`) of a checkpoint record."
  @spec record_keys() :: [String.t()]
  def record_keys, do: @record_keys

  # --- behaviour (alternate backends may implement the same seam) -------------

  @doc """
  Write a checkpoint for `journal` capturing `model`.

  Snapshot-file-before-record, single-Writer append, tip validated at write,
  turn-boundary enforced. Returns `{:ok, offset}` (the checkpoint's own dense
  journal offset) or a typed `{:error, reason}`
  (`:invalid_tip` | `:mid_turn` | `:mid_reserve` | ...).

  Options: `:reason` (one of `reasons/0`, default `"manual"`), `:tip_offset`
  (explicit tip to freeze; derived from the journal's conversational tip when
  absent), `:base_dir`.
  """
  @callback write(journal :: term(), model :: model(), opts :: keyword()) ::
              {:ok, FileStore.offset()} | {:error, term()}

  @doc """
  Restore the model captured by the latest healthy checkpoint of `journal`.

  Locates the latest healthy checkpoint, verifies `sha256(bytes) ==
  snapshot_hash`, loads the snapshot (MS codec), and folds the journal forward
  from `tip_offset` — equal to a full fold over the persistent slice (P-JS4). A
  missing/corrupt snapshot surfaces
  `{:error, :snapshot_missing | :snapshot_corrupt}` with the journal left `:ok`
  and nothing deleted. A tip-only checkpoint (`snapshot_ref: nil`) falls
  back to a full `fold(0..tip_offset)`.
  """
  @callback restore(journal :: term(), opts :: keyword()) ::
              {:ok, model()} | {:error, term()}

  @doc """
  Restore the model captured by ONE specific already-read `checkpoint` record of
  `journal` (the hardened single-checkpoint restore).

  This is the seam U10 compaction resume delegates to for its newest-first walk:
  it applies the SAME restore-path hardening as `restore/2`
  (`tip_offset`/`snapshot_ref` presence guard ⇒ `:malformed_checkpoint`;
  `@ref_re` path-traversal reject ⇒ `:malformed_pointer`; snapshot size ceiling,
  depth-bounded decode, `$s` deref-gadget guard ⇒ `:snapshot_corrupt`; hash
  verify ⇒ `:snapshot_corrupt`; absent file ⇒ `:snapshot_missing`) — the journal
  stays `:ok` and nothing is deleted on any failure. `restore/2` is
  exactly `restore_checkpoint/3` applied to the newest checkpoint.
  """
  @callback restore_checkpoint(
              journal :: term(),
              records :: [map()],
              checkpoint :: map()
            ) :: {:ok, model()} | {:error, term()}

  @doc """
  The GC-protected floor for `journal`'s already-read `records`: the `tip_offset`
  of the newest **healthy** checkpoint (its snapshot present + hash-verified,
  restore succeeds). Records at or above this offset MUST NEVER be truncated.
  `:none` when no healthy checkpoint exists.
  """
  @callback protected_floor(journal :: term(), records :: [map()]) ::
              {:offset, pos_integer()} | :none

  # --- backend seam ----------------------------------------------------------

  # A backend implementing `c:write/3` / `c:restore/2` may be injected via
  # `:persistent_term` under this key (how an alternate storage backend slots in
  # behind the behaviour). The DEFAULT (no registration) is the landed
  # `FileBackend` — the U9 file-store implementation. `put_backend(nil)` forces
  # the inert `{:error, :not_implemented}` seam back on (e.g. to disable
  # checkpointing in a constrained deployment).
  @backend_key {__MODULE__, :backend}
  @default_backend Raxol.Agent.Journal.Records.Checkpoint.FileBackend

  @doc """
  Register a module implementing this behaviour as the active backend, or `nil`
  to force the inert `{:error, :not_implemented}` seam. Absence ⇒ the default
  `FileBackend`.
  """
  @spec put_backend(module() | nil) :: :ok
  def put_backend(backend), do: :persistent_term.put(@backend_key, backend)

  @doc "See `c:write/3`. Dispatches to the active backend (default `FileBackend`)."
  @spec write(term(), model(), keyword()) ::
          {:ok, FileStore.offset()} | {:error, term()}
  def write(journal, model, opts \\ []) do
    case backend() do
      nil -> {:error, :not_implemented}
      mod -> mod.write(journal, model, opts)
    end
  end

  @doc "See `c:restore/2`. Dispatches to the active backend (default `FileBackend`)."
  @spec restore(term(), keyword()) :: {:ok, model()} | {:error, term()}
  def restore(journal, opts \\ []) do
    case backend() do
      nil -> {:error, :not_implemented}
      mod -> mod.restore(journal, opts)
    end
  end

  @doc "See `c:restore_checkpoint/3`. Dispatches to the active backend (default `FileBackend`)."
  @spec restore_checkpoint(term(), [map()], map()) ::
          {:ok, model()} | {:error, term()}
  def restore_checkpoint(journal, records, checkpoint) do
    case backend() do
      nil -> {:error, :not_implemented}
      mod -> mod.restore_checkpoint(journal, records, checkpoint)
    end
  end

  defp backend, do: :persistent_term.get(@backend_key, @default_backend)

  # --- GC protection floor (Drew MEDIUM; JS-FREEZE §1.1-GC) ------------------

  @doc """
  The GC-protected floor for `journal`'s already-read `records`: records at or
  above this offset MUST NEVER be truncated, so the checkpoint restore path
  stays intact (**frozen law: GC never orphans checkpoints**, JS-FREEZE §1.1).

  It is the `tip_offset` of the newest **healthy** checkpoint — the one resume
  actually restores from. "Healthy" means its snapshot is present and
  hash-verified (restore succeeds); a corrupt newest is skipped so the floor
  lands on the older healthy checkpoint U10's fall-back restores from, never on
  a corrupt newest's higher tip (which would let GC truncate records the
  fall-back fold still needs — an orphaned fall-back tip). `:none` when no
  healthy checkpoint exists (nothing to protect).

  A future `gc`/truncation writer MUST consult this and reject any proposal
  whose truncation range reaches this offset — rejected at the same synchronous
  admission seam as `:invalid_tip`, never accepted-then-marked.

  Dispatches to the active backend (default `FileBackend`) because health is a
  snapshot-file property, not a record-only one. This arity is the
  authoritative floor for a truncation admission decision;
  `protected_floor/1` is the record-only conservative variant for callers
  without a journal handle.
  """
  @spec protected_floor(term(), [map()]) :: {:offset, pos_integer()} | :none
  def protected_floor(journal, records) when is_list(records) do
    case backend() do
      nil -> :none
      mod -> mod.protected_floor(journal, records)
    end
  end

  @doc """
  Record-only variant of `protected_floor/2` for callers WITHOUT a journal
  handle: it can validate record shape but cannot probe snapshot health, so it
  returns the newest well-formed checkpoint's tip. On its own it is NOT
  sufficient for a truncation admission decision under the fall-back resume
  model — a shape-valid checkpoint whose snapshot file is corrupt keeps its
  higher tip here, while `protected_floor/2` lands the floor on the older
  healthy tip resume actually falls back to. A GC writer with a journal handle
  MUST use `protected_floor/2`.

  **Fail-closed on malformed checkpoints** (adversarial-review hardening): the
  tolerant Reader accepts a truncated/adversarial checkpoint record missing
  `id`/`tip_offset` (or carrying non-integer junk). Restore typed-rejects
  those (`:malformed_checkpoint`); this floor — the "never orphan a
  checkpoint" safety check — must not raise a `KeyError` on the same records.
  When ANY checkpoint record is malformed the floor is unknowable, so it
  degrades to `{:offset, 1}`: the entire journal is protected and every
  truncation proposal is rejected. Protecting too much is safe; guessing is
  not.
  """
  @spec protected_floor([map()]) :: {:offset, pos_integer()} | :none
  def protected_floor(records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, "kind") == @kind))
    |> case do
      [] ->
        :none

      cps ->
        if Enum.all?(cps, &floor_fields_healthy?/1) do
          newest = Enum.max_by(cps, &Map.fetch!(&1, "id"))
          {:offset, Map.fetch!(newest, "tip_offset")}
        else
          {:offset, 1}
        end
    end
  end

  # The two fields the floor dereferences, present AND well-typed (positive
  # integers — ids/offsets start at 1).
  defp floor_fields_healthy?(cp) do
    id = Map.get(cp, "id")
    tip = Map.get(cp, "tip_offset")
    is_integer(id) and id > 0 and is_integer(tip) and tip > 0
  end
end
