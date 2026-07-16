defmodule Raxol.Agent.Journal.Records.Checkpoint do
  @moduledoc """
  U9 — checkpoint pointer records (AD-10 / AD-3a).

  A checkpoint is an **in-log pointer record**, not a second store. The snapshot
  payload lives content-addressed and out-of-line at
  `<session>/snapshots/<sha256-hex>.json`; the `checkpoint` record carries only
  the pointer + hash + the conversational tip it was taken at. It is appended
  through the **same single Writer** as every other record, consuming exactly one
  offset from the one id space (JS-FREEZE §1.1 — the offset law; N-JS6
  single-counter lockstep).

  This module is the **enabler skeleton** for the permanent U9-R red suite: the
  frozen record shape (`t/0`) and the `write/3` / `restore/2` seam are declared
  here, ahead of implementation, so the red suite compiles and pins the contract.
  Both entry points return `{:error, :not_implemented}` until U9 lands — the red
  suite (`@moduletag :harness_red`, excluded from CI) asserts the *correct*
  behaviour and is therefore RED against this skeleton by construction.

  See `docs/proposals/in-flight/harness-freeze-contracts.md` §1.1 (checkpoint
  record — frozen fields, the offset law, the turn-boundary rule, the
  conversational tip) and §1.2/§1.3 (P-JS1/P-JS4 + N-JS1/N-JS2/N-JS3/N-JS6).

  ## Write discipline (frozen — JS-FREEZE §1.1)

    * The snapshot file is written **before** the record is appended (a record
      cannot be named by its own offset before it exists — chicken/egg), via the
      FI-8 atomic temp+fsync+rename. A crash between file-write and record-append
      leaves a harmless orphan file (FI-7: never deleted implicitly).
    * `snapshot_hash` = lowercase-hex `sha256` of the snapshot file bytes; it is
      verified at restore. A missing file → `{:error, :snapshot_missing}`; a
      hash mismatch → `{:error, :snapshot_corrupt}` — and in **both** cases the
      journal stays `:ok` and nothing is deleted (N-JS3).
    * `snapshot_ref: nil` is a legal tip-only pointer (OQ-JS1 RULED LEGAL);
      restore then falls back to a full `fold(0..tip_offset)`.
    * `tip_offset` is frozen at write time and validated at write time: the
      record it names MUST satisfy `conversational?/1` on the checkpoint's own
      branch, else `{:error, :invalid_tip}` and **nothing is appended** (N-JS1).
    * A checkpoint MUST NOT be appended mid-turn (between `turn_started` and its
      close) nor mid-reserve (between a spend-gate reserve and its terminal),
      else `{:error, :mid_turn}` / `{:error, :mid_reserve}` (N-JS2).
    * FI-10: the record body carries **no model content** — pointer + hash only;
      the snapshot file passes sanitize + MS secret exclusion before hashing.
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
  and nothing deleted (N-JS3). A tip-only checkpoint (`snapshot_ref: nil`) falls
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
  stays `:ok` and nothing is deleted on any failure (N-JS3). `restore/2` is
  exactly `restore_checkpoint/3` applied to the newest checkpoint.
  """
  @callback restore_checkpoint(
              journal :: term(),
              records :: [map()],
              checkpoint :: map()
            ) :: {:ok, model()} | {:error, term()}

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
end
