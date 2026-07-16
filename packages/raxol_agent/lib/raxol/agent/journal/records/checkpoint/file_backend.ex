defmodule Raxol.Agent.Journal.Records.Checkpoint.FileBackend do
  @moduledoc """
  U9 — the file-store backend for `Raxol.Agent.Journal.Records.Checkpoint`
  (AD-10 / AD-3a). Implements the checkpoint **pointer-record** discipline over
  a `Raxol.Agent.Journal.FileStore` session.

  A checkpoint is an in-log pointer, not a second store: the snapshot payload is
  content-addressed and written out-of-line to `<session>/snapshots/<sha256>.json`
  (FI-8 atomic temp+fsync+rename) **before** the pointer record is appended
  through the one single Writer, consuming exactly one offset from the one id
  space (the offset law, JS-FREEZE §1.1). The record body carries only the
  pointer + hash + tip — never model content (FI-10).

  ## Write path (`write/3`)

    1. read the journal (tolerant Reader; STRING-keyed maps);
    2. resolve `tip_offset` (explicit opt, else the derived conversational tip);
    3. reject an invalid tip (`:invalid_tip`) — the named record must exist and
       be CONVERSATIONAL on the branch (N-JS1); **nothing is appended**;
    4. reject a mid-turn / mid-reserve write (`:mid_turn` / `:mid_reserve`, N-JS2);
    5. stage the snapshot file (content-addressed, atomic) — skipped for a
       `nil` model, which is a legal tip-only pointer (OQ-JS1);
    6. append the pointer record through the single Writer ⇒ `{:ok, offset}`.

  ## Restore path (`restore/2`)

  Locate the newest checkpoint (highest offset), then:

    * tip-only pointer (`snapshot_ref == nil`) ⇒ full `fold(0..tip_offset)`;
    * else verify `sha256(bytes) == snapshot_hash` (mismatch ⇒
      `:snapshot_corrupt`; absent file ⇒ `:snapshot_missing`; both leave the
      journal `:ok` and delete nothing, N-JS3), load the snapshot, then fold the
      CONVERSATIONAL tail (records with `id > tip_offset`) forward onto it.

  Restore folds equal a full fold over the persistent slice (P-JS4).

  ## Restore-path hardening (folded in from `harness-parked.md`)

    * **Bounded decode recursion** — the decoded snapshot is validated by a
      depth-bounded structural walk (`@max_decode_depth`); adversarial nesting
      degrades to `:snapshot_corrupt`, never unbounded stack growth.
    * **`$s` deref-gadget guard** — a decoded map carrying a `"$s"` struct-module
      tag is rejected (`:snapshot_corrupt`); this backend NEVER resolves a
      caller-controlled atom to a module or calls `struct/2` on untrusted disk
      data (type-confusion / atom-table-DoS class).
    * **Malformed-pointer reject** — `snapshot_ref` must match
      `snapshots/<64-hex>.json` exactly; anything else (path traversal, wrong
      shape) is refused before any file read, so a hostile pointer can never
      escape the session's `snapshots/` directory.
    * **Snapshot-size ceiling** — a snapshot file over `@max_snapshot_bytes` is
      refused (`:snapshot_corrupt`) rather than loaded whole.

  ## Model fold (surrogate — re-bind to MS when it lands)

  The Snapshot codec (`Raxol.Agent.Snapshot`, #559) owns serialization; this
  backend owns only the pointer discipline. The concrete *fold* (applying
  conversational events onto a model) is not yet frozen against the MS codec on
  this branch, so it is the deterministic surrogate the U9-R red suite pins:
  each CONVERSATIONAL event appends its `id` to `model["applied"]`. Re-bind
  `fold_step/2` (and `dump/1`/`load/1`) to the real MS fold when MS lands — the
  round-trip *equation* (P-JS4) is codec-independent.
  """

  @behaviour Raxol.Agent.Journal.Records.Checkpoint

  alias Raxol.Agent.Journal.FileStore

  @kind Raxol.Agent.Journal.Records.Checkpoint.kind()
  @reasons Raxol.Agent.Journal.Records.Checkpoint.reasons()

  # The frozen CONVERSATIONAL whitelist (JS-FREEZE §1.1 — the closure rule).
  @conversational MapSet.new(~w(
    turn_started item_started item_completed
    turn_completed turn_canceled error approval_requested
  ))

  # A checkpoint's own branch (v1: single linear "main" branch).
  @branch "main"

  # Content-addressed snapshot pointer shape: snapshots/<sha256-hex>.json.
  @ref_re ~r|\Asnapshots/[0-9a-f]{64}\.json\z|

  # Restore-path hardening bounds.
  @max_decode_depth 64
  @max_snapshot_bytes 64 * 1024 * 1024

  # --- write -----------------------------------------------------------------

  @impl true
  def write(%FileStore{} = journal, model, opts) do
    with {:ok, records} <- read_records(journal),
         {:ok, tip} <- resolve_tip(records, opts),
         :ok <- check_turn_boundary(records),
         {:ok, reason} <- validate_reason(opts) do
      append_checkpoint(journal, model, tip, reason)
    end
  end

  def write(_journal, _model, _opts), do: {:error, :invalid_journal}

  defp append_checkpoint(%FileStore{} = journal, model, tip, reason) do
    # File-BEFORE-record (FI-8): a crash after this and before the append leaves
    # a harmless content-addressed orphan (FI-7: never deleted implicitly).
    with {:ok, ref, hash} <- stage_snapshot(journal, model) do
      record = %{
        "kind" => @kind,
        "branch_id" => @branch,
        "session_id" => journal.session_id,
        "ts" => System.system_time(:microsecond),
        "tip_offset" => tip,
        "snapshot_ref" => ref,
        "snapshot_hash" => hash,
        "reason" => reason
      }

      # The single Writer stamps `id` (= the checkpoint's own dense offset) and
      # `schema_version`, consuming one offset from the one counter (offset law).
      FileStore.append(journal, record)
    end
  end

  # nil model ⇒ legal tip-only pointer (OQ-JS1): no snapshot file.
  defp stage_snapshot(%FileStore{}, nil), do: {:ok, nil, nil}

  defp stage_snapshot(%FileStore{dir: dir}, model) do
    bytes = dump(model)
    hash = sha256_hex(bytes)
    ref = "snapshots/#{hash}.json"
    path = Path.join(dir, ref)

    with :ok <- atomic_write(path, bytes) do
      {:ok, ref, hash}
    end
  end

  # --- restore ---------------------------------------------------------------

  @impl true
  def restore(%FileStore{} = journal, _opts) do
    with {:ok, records} <- read_records(journal),
         {:ok, checkpoint} <- newest_checkpoint(records) do
      restore_from(journal, records, checkpoint)
    end
  end

  def restore(_journal, _opts), do: {:error, :invalid_journal}

  defp newest_checkpoint(records) do
    case Enum.filter(records, &(Map.get(&1, "kind") == @kind)) do
      [] ->
        {:error, :no_checkpoint}

      cps ->
        # The Reader is tolerant of a partial record; restore is NOT. Pick the
        # newest without `fetch!` (a missing `id` is sentinel-ranked, never a
        # raise), then require the keys restore dereferences downstream so an
        # adversarial/truncated checkpoint yields a typed reject, not a KeyError.
        cps
        |> Enum.max_by(&Map.get(&1, "id", -1))
        |> validate_checkpoint()
    end
  end

  # A checkpoint restore dereferences `id` (selection), `tip_offset`, and
  # `snapshot_ref`; any missing ⇒ `:malformed_checkpoint` (typed reject, N-JS3
  # class) rather than an unhandled `KeyError` on `Map.fetch!`.
  defp validate_checkpoint(cp) do
    if Enum.all?(~w(id tip_offset snapshot_ref), &Map.has_key?(cp, &1)),
      do: {:ok, cp},
      else: {:error, :malformed_checkpoint}
  end

  # Tip-only pointer: full fold(0..tip_offset) over conversational records.
  defp restore_from(%FileStore{}, records, %{"snapshot_ref" => nil} = cp) do
    tip = Map.fetch!(cp, "tip_offset")
    {:ok, fold(records, &(&1 <= tip))}
  end

  defp restore_from(%FileStore{dir: dir}, records, cp) do
    tip = Map.fetch!(cp, "tip_offset")
    ref = Map.fetch!(cp, "snapshot_ref")

    with :ok <- validate_ref(ref),
         {:ok, bytes} <- read_snapshot(dir, ref),
         :ok <- verify_hash(bytes, Map.get(cp, "snapshot_hash")),
         {:ok, model} <- decode_snapshot(bytes) do
      # Fold the CONVERSATIONAL tail (id > tip) forward onto the restored model.
      {:ok, fold_forward(model, records, &(&1 > tip))}
    end
  end

  # --- tip resolution / validation (N-JS1) -----------------------------------

  defp resolve_tip(records, opts) do
    case Keyword.get(opts, :tip_offset) do
      nil ->
        case conversational_tip(records) do
          :no_tip -> {:error, :no_tip}
          offset -> {:ok, offset}
        end

      explicit ->
        if valid_tip?(records, explicit),
          do: {:ok, explicit},
          else: {:error, :invalid_tip}
    end
  end

  defp conversational_tip(records) do
    records
    |> Enum.filter(&conversational?/1)
    |> case do
      [] -> :no_tip
      convs -> convs |> Enum.map(&Map.fetch!(&1, "id")) |> Enum.max()
    end
  end

  defp valid_tip?(records, offset) do
    case Enum.find(records, &(Map.get(&1, "id") == offset)) do
      nil -> false
      record -> conversational?(record)
    end
  end

  # The frozen tip predicate over a STRING-keyed record map (branch-aware,
  # grandfather-safe: absent kind ⇒ "event", absent branch ⇒ "main").
  defp conversational?(record) do
    Map.get(record, "kind", "event") == "event" and
      Map.get(record, "branch_id", @branch) == @branch and
      Map.get(record, "family") == "loop" and
      MapSet.member?(@conversational, Map.get(record, "type"))
  end

  # --- turn-boundary rule (N-JS2) --------------------------------------------

  defp check_turn_boundary(records) do
    {turns, reserves} =
      Enum.reduce(records, {0, 0}, fn r, {turns, reserves} ->
        case Map.get(r, "type") do
          "turn_started" ->
            {turns + 1, reserves}

          t when t in ["turn_completed", "turn_canceled", "error"] ->
            {max(turns - 1, 0), reserves}

          "reserve" ->
            {turns, reserves + 1}

          t when t in ["settle", "release"] ->
            {turns, max(reserves - 1, 0)}

          _ ->
            {turns, reserves}
        end
      end)

    cond do
      turns > 0 -> {:error, :mid_turn}
      reserves > 0 -> {:error, :mid_reserve}
      true -> :ok
    end
  end

  # --- reason enum -----------------------------------------------------------

  defp validate_reason(opts) do
    # Grow-only enum on WRITE; unknown reasons are tolerated only on READ.
    case to_string(Keyword.get(opts, :reason, "manual")) do
      reason when reason in @reasons -> {:ok, reason}
      other -> {:error, {:unknown_reason, other}}
    end
  end

  # --- snapshot pointer / integrity (N-JS3 + hardening) ----------------------

  defp validate_ref(ref) when is_binary(ref) do
    if Regex.match?(@ref_re, ref), do: :ok, else: {:error, :malformed_pointer}
  end

  defp validate_ref(_), do: {:error, :malformed_pointer}

  defp read_snapshot(dir, ref) do
    path = Path.join(dir, ref)

    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_snapshot_bytes ->
        {:error, :snapshot_corrupt}

      {:ok, _} ->
        case File.read(path) do
          {:ok, bytes} -> {:ok, bytes}
          {:error, _} -> {:error, :snapshot_missing}
        end

      {:error, :enoent} ->
        {:error, :snapshot_missing}

      {:error, _} ->
        {:error, :snapshot_missing}
    end
  end

  defp verify_hash(bytes, hash) when is_binary(hash) do
    if sha256_hex(bytes) == hash, do: :ok, else: {:error, :snapshot_corrupt}
  end

  defp verify_hash(_bytes, _hash), do: {:error, :snapshot_corrupt}

  defp decode_snapshot(bytes) do
    case Jason.decode(bytes) do
      # A snapshot's top-level term is ALWAYS a folded model map (the codec dumps
      # `%{"applied" => ...}`). A scalar/list top-level is adversarial disk data:
      # reject it here, before it can reach `fold_step`'s `Map.update` and raise a
      # `BadMapError` on a non-empty conversational tail (typed-reject, never raise).
      {:ok, term} when is_map(term) ->
        if safe_term?(term, @max_decode_depth),
          do: {:ok, term},
          else: {:error, :snapshot_corrupt}

      {:ok, _non_map} ->
        {:error, :snapshot_corrupt}

      {:error, _} ->
        {:error, :snapshot_corrupt}
    end
  end

  # Depth-bounded structural guard + `$s` deref-gadget reject. A snapshot is a
  # plain JSON-safe term; a `"$s"` struct-module tag on untrusted disk data is
  # refused rather than resolved to a module (parked hardening).
  defp safe_term?(_term, depth) when depth < 0, do: false

  defp safe_term?(map, depth) when is_map(map) do
    not Map.has_key?(map, "$s") and
      Enum.all?(map, fn {_k, v} -> safe_term?(v, depth - 1) end)
  end

  defp safe_term?(list, depth) when is_list(list) do
    Enum.all?(list, &safe_term?(&1, depth - 1))
  end

  defp safe_term?(_scalar, _depth), do: true

  # --- model fold (surrogate — see moduledoc) --------------------------------

  defp fold(records, pred), do: fold_forward(%{"applied" => []}, records, pred)

  defp fold_forward(model, records, pred) do
    records
    |> Enum.filter(fn r -> conversational?(r) and pred.(Map.get(r, "id")) end)
    |> Enum.reduce(model, &fold_step(&2, &1))
  end

  defp fold_step(model, record) do
    id = Map.fetch!(record, "id")
    Map.update(model, "applied", [id], &(&1 ++ [id]))
  end

  defp dump(model), do: Jason.encode!(model)

  # --- journal read / hashing / atomic file write ----------------------------

  defp read_records(%FileStore{} = journal) do
    case FileStore.read(journal) do
      {:ok, records} -> {:ok, records}
      {:error, reason} -> {:error, {:journal, reason}}
    end
  end

  defp sha256_hex(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # FI-8 atomic write: temp + fsync + rename, then best-effort dir fsync.
  defp atomic_write(path, data) do
    dir = Path.dirname(path)

    tmp =
      path <> ".tmp." <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(dir),
         :ok <- write_and_sync(tmp, data),
         :ok <- File.rename(tmp, path) do
      sync_dir(dir)
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, {:snapshot_write_failed, reason}}
    end
  end

  defp write_and_sync(path, data) do
    case :file.open(path, [:write, :raw, :binary]) do
      {:ok, io} ->
        result =
          with :ok <- :file.write(io, data), do: :file.datasync(io)

        :file.close(io)
        result

      {:error, _} = err ->
        err
    end
  end

  defp sync_dir(dir) do
    case :file.open(dir, [:read, :raw]) do
      {:ok, io} ->
        _ = :file.datasync(io)
        :file.close(io)

      _ ->
        :ok
    end

    :ok
  end
end
