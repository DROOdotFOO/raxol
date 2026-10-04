defmodule Raxol.Agent.Journal.FileStore.Reader do
  @moduledoc """
  Tolerant replay of a session's JSONL journal segments (see
  `docs/harness/architecture.md`, "Journal and projection").

  Segments are replayed in ascending order into an ordered record stream. Two
  failure policies, per the spec:

    * **Torn tail (Ra policy).** A parse failure on the *final* line of the *last*
      segment is a crash mid-write. The torn bytes are truncated away, everything
      before is recovered, and the session stays healthy (`{:ok, records}`).

    * **Interior corruption.** A parse failure anywhere else marks the session
      damaged. A hard alarm fires (`Logger.error` + a telemetry event), **nothing
      is deleted**, and the damaged content is **never** returned — `scan/2`
      returns `{:damaged, records_before}` and callers must not surface it.

    * **Chain break (chained journals).** A record that does not link to its
      predecessor's hash, does not match its own hash, or is not its own
      canonical JSON (see `Raxol.Agent.Journal.Chain`) is interior corruption.
      So is a journal that ends below the offset `HEAD` anchors, or whose
      anchored record carries a different hash: on a chained journal a torn
      tail can only be a line that was never synced.

    * **Chain downgrade.** A journal is chained when `meta.json` says so, but
      the flag is not the only witness: `HEAD`'s `"tip_hash"` and the first
      record's `"prev_hash"`/`"hash"` are only ever written to a chained
      journal. A journal that carries any of them without the flag had its
      flag removed, which would otherwise switch every check above off; it is
      damaged from offset 1.
  """

  alias Raxol.Agent.Journal.Chain

  require Logger

  @telemetry_damaged [:raxol, :agent, :journal, :damaged]

  @typedoc "Result of a replay scan."
  @type result :: {:ok, [map()]} | {:damaged, [map()]}

  @doc """
  Replay all journal segments under `dir` in ascending order.

  Returns `{:ok, records}` for a healthy or torn-tail-tolerated journal, or
  `{:damaged, records}` when interior corruption was detected. In the damaged
  case `records` are only the complete records preceding the corruption and
  MUST NOT be surfaced downstream — callers map this to an error.

  READS NEVER WRITE. A torn tail is ignored, not repaired: repairing is the
  owning Writer's job (`resume_scan/1`). A reader computes the cut from a file
  it read moments ago, so against a live session it can delete a record the
  Writer already committed and counted — whose next append then lands past the
  hole and leaves the session permanently `{:damaged, _}`. Read-only media is
  the same hazard in a smaller way: the repair could only crash the reader.
  """
  @spec scan(Path.t(), keyword()) :: result
  def scan(dir, opts \\ []) do
    # The chain anchor is read BEFORE the segments: HEAD only moves forward
    # after a datasync, so segments read later always reach at least the
    # anchored offset, even while a live Writer appends.
    case chain_anchor(dir) do
      :downgraded ->
        alarm(dir, %{path: Path.join(dir, "meta.json")})
        {:damaged, []}

      anchor ->
        ctx = %{dir: dir, heal?: Keyword.get(opts, :heal, false), chain: anchor}

        segments =
          dir
          |> Path.join("journal")
          |> list_segments()
          |> Enum.map(&{&1, File.read!(&1)})

        with_heap_for(segments, fn -> replay_segments(segments, [], ctx) end)
    end
  end

  # The decoded records are one list that only grows. Left to the default
  # growth policy, the heap is outgrown -- and the whole list copied by a full
  # collection -- dozens of times on the way up, which is what made a long
  # scan superlinear. Size the heap for the journal up front (about one heap
  # byte per journal byte) and give the caller its own minimum back after.
  defp with_heap_for(segments, fun) do
    bytes = Enum.reduce(segments, 0, fn {_path, raw}, sum -> sum + byte_size(raw) end)
    words = min(div(bytes, :erlang.system_info(:wordsize)), heap_ceiling())
    {:min_heap_size, previous} = Process.info(self(), :min_heap_size)

    if words > previous do
      Process.flag(:min_heap_size, words)

      try do
        fun.()
      after
        Process.flag(:min_heap_size, previous)
      end
    else
      fun.()
    end
  end

  # A caller with a `max_heap_size` keeps it: the minimum stays well below.
  defp heap_ceiling do
    case Process.info(self(), :max_heap_size) do
      {:max_heap_size, %{size: max}} when max > 0 -> div(max, 2)
      _unlimited -> :infinity
    end
  end

  @doc """
  Is the journal under `dir` chained? True when `meta.json` says
  `"chain": true`, and also when it does not but the journal still carries a
  chain marker (see "Chain downgrade") -- such a journal reads as damaged.
  """
  @spec chained?(Path.t()) :: boolean()
  def chained?(dir), do: chain_mode(dir) != :unchained

  defp chain_anchor(dir) do
    case chain_mode(dir) do
      :unchained -> nil
      :downgraded -> :downgraded
      :chained -> anchor(read_json(Path.join(dir, "HEAD")))
    end
  end

  defp anchor({:ok, %{"offset" => offset} = head}) when is_integer(offset),
    do: %{head_offset: offset, head_hash: head["tip_hash"]}

  defp anchor(_head), do: %{head_offset: 0, head_hash: nil}

  defp chain_mode(dir) do
    cond do
      match?({:ok, %{"chain" => true}}, read_json(Path.join(dir, "meta.json"))) -> :chained
      match?({:ok, %{"tip_hash" => _}}, read_json(Path.join(dir, "HEAD"))) -> :downgraded
      first_record_hashed?(dir) -> :downgraded
      true -> :unchained
    end
  end

  defp first_record_hashed?(dir) do
    first =
      dir
      |> Path.join("journal")
      |> list_segments()
      |> Enum.find_value(&first_line/1)

    case first && Jason.decode(first) do
      {:ok, %{} = record} -> Map.has_key?(record, "prev_hash") or Map.has_key?(record, "hash")
      _ -> false
    end
  end

  # The first non-blank line of a segment, nil when it has none. A segment
  # that cannot be opened has no first line here; the scan proper reports it.
  defp first_line(path) do
    case File.open(path, [:read, :binary, :raw, :read_ahead], &read_first_line/1) do
      {:ok, line} -> line
      {:error, _reason} -> nil
    end
  end

  defp read_first_line(io) do
    case :file.read_line(io) do
      {:ok, "\n"} -> read_first_line(io)
      {:ok, line} -> line
      _eof_or_error -> nil
    end
  end

  defp read_json(path) do
    with {:ok, body} <- File.read(path), do: Jason.decode(body)
  end

  @doc """
  `scan/1` for the OWNING Writer at resume, which additionally REPAIRS a torn
  tail.

  The Writer must truncate the torn bytes before it appends again, or the next
  record concatenates onto them and turns a recoverable tail into permanent
  damage. It is the only caller that may: it holds the lock, and nothing else
  is appending while it resumes.
  """
  @spec resume_scan(Path.t()) :: result
  def resume_scan(dir), do: scan(dir, heal: true)

  @doc "Highest offset (id) present in a healthy replay, or 0 if empty/damaged."
  @spec last_offset(Path.t()) :: non_neg_integer()
  def last_offset(dir), do: offset_of(scan(dir))

  @doc "`last_offset/1` for the owning Writer's resume; repairs a torn tail."
  @spec resume_last_offset(Path.t()) :: non_neg_integer()
  def resume_last_offset(dir), do: offset_of(resume_scan(dir))

  defp offset_of({:ok, records}), do: records |> List.last() |> record_id()
  defp offset_of({:damaged, _}), do: 0

  defp record_id(nil), do: 0
  defp record_id(%{"id" => id}) when is_integer(id), do: id
  defp record_id(_), do: 0

  # --- segment discovery -----------------------------------------------------

  @segment_re ~r/^\d{6}\.jsonl$/

  @doc false
  @spec list_segments(Path.t()) :: [Path.t()]
  def list_segments(journal_dir) do
    case File.ls(journal_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@segment_re, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal_dir, &1))

      {:error, _} ->
        []
    end
  end

  # --- replay ----------------------------------------------------------------

  # Segments are walked line by line in place: a line is a sub-binary of its
  # segment, taken only when it is replayed, and nothing but the decoded
  # records accumulates. Blank lines are skipped -- a stray blank line is not a
  # record and not corruption, as the moduledoc promises.
  defp replay_segments([], acc, ctx), do: finish(acc, ctx)

  defp replay_segments([{path, raw} | rest], acc, ctx),
    do: replay_lines(path, raw, 0, rest, acc, ctx)

  defp replay_lines(path, raw, at, segments, acc, ctx) do
    case next_line(raw, at) do
      :eof ->
        replay_segments(segments, acc, ctx)

      {"", next, _terminated?} ->
        replay_lines(path, raw, next, segments, acc, ctx)

      {line, next, terminated?} ->
        # `at` is where this line STARTS, recorded during the read so a repair
        # cuts at a position derived from the same bytes it parsed, rather
        # than from a fresh stat taken afterwards.
        entry = %{path: path, raw: line, at: at}

        # Ra policy, frame-strict: the FINAL line of the journal with no
        # trailing newline is a torn write even when its bytes happen to
        # decode — the frame is the whole line, and leaving
        # decodable-but-unterminated bytes in place would concatenate the next
        # append onto the same line, corrupting the journal one write later.
        # Truncate it, keep the prefix, stay healthy. (Found by the I5
        # byte-cut fuzz in test/invariants/storage_invariants_test.exs.)
        if not terminated? and final?(segments),
          do: torn_tail(entry, acc, ctx),
          else: continue(replay_line(entry, acc, ctx), path, raw, next, segments, ctx)
    end
  end

  defp continue({:ok, acc}, path, raw, next, segments, ctx),
    do: replay_lines(path, raw, next, segments, acc, ctx)

  defp continue(damaged, _path, _raw, _next, _segments, _ctx), do: damaged

  # `{line, next_at, terminated?}` for the line starting at `at`.
  defp next_line(raw, at) when at >= byte_size(raw), do: :eof

  defp next_line(raw, at) do
    case :binary.match(raw, "\n", scope: {at, byte_size(raw) - at}) do
      {nl, 1} -> {binary_part(raw, at, nl - at), nl + 1, true}
      :nomatch -> {binary_part(raw, at, byte_size(raw) - at), byte_size(raw), false}
    end
  end

  # No record follows in any later segment (each is empty or blank lines).
  defp final?(segments), do: Enum.all?(segments, fn {_path, raw} -> blank?(raw) end)

  defp blank?(<<?\n, rest::binary>>), do: blank?(rest)
  defp blank?(rest), do: rest == ""

  # A fully-flushed newline-terminated but corrupt line, interior or final, is
  # real data loss, not a torn write: mark damaged — alarm, delete nothing,
  # leak nothing. Silently truncating a terminated record would mask genuine
  # corruption behind a healthy `:ok`.
  defp replay_line(entry, acc, ctx) do
    with {:ok, record} <- Jason.decode(entry.raw),
         # An id gap (or a record without an integer id) means complete
         # records were LOST — a deleted/truncated interior segment. Silently
         # concatenating around the hole would fabricate continuity, so this
         # is damage, exactly like interior corruption. (Found by the I6
         # missing-middle-segment invariant.)
         true <- continuous?(acc, record),
         true <- linked?(record, entry.raw, acc, ctx) do
      {:ok, [record | acc]}
    else
      _bad ->
        alarm(ctx.dir, entry)
        {:damaged, Enum.reverse(acc)}
    end
  end

  # The writer stamps strictly consecutive integer ids, so any healthy journal
  # replays as prev + 1 steps. The first record anchors the sequence (a later
  # GC unit may legally drop a prefix, so it need not be id 1).
  defp continuous?([], %{"id" => id}) when is_integer(id), do: true

  defp continuous?([%{"id" => prev} | _], %{"id" => id})
       when is_integer(prev) and is_integer(id),
       do: id == prev + 1

  defp continuous?(_acc, _record), do: false

  # Chained journals: the record must link to its predecessor's hash (the
  # first one is id 1 and links to genesis) and be its own canonical bytes.
  defp linked?(_record, _raw, _acc, %{chain: nil}), do: true

  defp linked?(record, raw, acc, _ctx),
    do: Chain.check(record, prev_hash(acc, record), raw) == :ok

  defp prev_hash([], %{"id" => 1}), do: Chain.genesis()
  defp prev_hash([], _record), do: nil
  defp prev_hash([%{"hash" => hash} | _], _record), do: hash
  defp prev_hash(_acc, _record), do: nil

  # Torn tail (Ra policy): the *final* line of the *last* segment has NO trailing
  # newline — a crash mid-`:file.write`. Truncate the incomplete bytes, recover
  # everything before, session stays healthy. On a chained journal only a line
  # ABOVE the HEAD anchor can be torn: the anchor is written after the datasync
  # that made its offset durable, so a cut at or below it lost a committed record.
  defp torn_tail(entry, acc, ctx) do
    if committed?(acc, ctx) do
      alarm(ctx.dir, entry)
      {:damaged, Enum.reverse(acc)}
    else
      if ctx.heal?, do: truncate_torn(entry)
      finish(acc, ctx)
    end
  end

  defp committed?(_acc, %{chain: nil}), do: false

  defp committed?(acc, %{chain: %{head_offset: head}}),
    do: record_id(List.first(acc)) + 1 <= head

  # Chained journals end where HEAD says they do: a shorter journal lost its
  # tail, and the anchored record must carry the anchored hash.
  defp finish(acc, %{chain: nil}), do: {:ok, Enum.reverse(acc)}

  defp finish(acc, %{chain: anchor} = ctx) do
    case anchor_break(acc, anchor) do
      nil ->
        {:ok, Enum.reverse(acc)}

      before ->
        alarm(ctx.dir, %{path: Path.join(ctx.dir, "HEAD")})
        {:damaged, before}
    end
  end

  # nil when the journal reaches its HEAD anchor with the anchored hash, else
  # the records before the break.
  defp anchor_break(acc, %{head_offset: head, head_hash: head_hash}) do
    anchored = Enum.find(acc, &(&1["id"] == head))

    cond do
      head > record_id(List.first(acc)) ->
        Enum.reverse(acc)

      is_binary(head_hash) and anchored != nil and anchored["hash"] != head_hash ->
        acc |> Enum.reverse() |> Enum.take_while(&(&1["id"] < head))

      true ->
        nil
    end
  end

  defp truncate_torn(%{path: path, at: at}) do
    case :file.open(path, [:read, :write, :binary]) do
      {:ok, io} ->
        try do
          {:ok, _} = :file.position(io, at)
          :ok = :file.truncate(io)
          :ok = :file.datasync(io)
        after
          :file.close(io)
        end

        :ok

      # Read-only media, or a mode-bit accident. Declining to repair leaves a
      # tail the next scan tolerates just the same; raising here would kill a
      # Tailer or propagate out of an attach.
      {:error, _reason} ->
        :ok
    end
  end

  defp alarm(dir, %{path: path}) do
    Logger.error(
      "[Journal] interior corruption detected in #{path}; session marked :damaged. " <>
        "Nothing deleted, damaged content withheld from replay."
    )

    :telemetry.execute(@telemetry_damaged, %{count: 1}, %{
      dir: dir,
      segment: path
    })

    :ok
  end
end
