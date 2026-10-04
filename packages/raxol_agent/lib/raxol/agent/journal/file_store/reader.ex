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
    ctx = %{dir: dir, heal?: Keyword.get(opts, :heal, false), chain: chain_anchor(dir)}

    dir
    |> Path.join("journal")
    |> list_segments()
    |> build_entries()
    |> replay([], ctx)
  end

  @doc "Is the journal under `dir` chained (`\"chain\": true` in `meta.json`)?"
  @spec chained?(Path.t()) :: boolean()
  def chained?(dir) do
    case read_json(Path.join(dir, "meta.json")) do
      {:ok, %{"chain" => true}} -> true
      _ -> false
    end
  end

  defp chain_anchor(dir) do
    if chained?(dir) do
      case read_json(Path.join(dir, "HEAD")) do
        {:ok, %{"offset" => offset} = head} when is_integer(offset) ->
          %{head_offset: offset, head_hash: head["tip_hash"]}

        _ ->
          %{head_offset: 0, head_hash: nil}
      end
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

  # Flatten every segment into an ordered list of line entries, dropping empty
  # segments/lines. Each entry records whether its line was newline-terminated,
  # which is needed to compute the truncation offset for a torn tail.
  defp build_entries(segments) do
    Enum.flat_map(segments, fn path ->
      raw = File.read!(path)

      case raw do
        "" ->
          []

        _ ->
          terminated_file? = String.ends_with?(raw, "\n")
          parts = String.split(raw, "\n")
          lines = if terminated_file?, do: Enum.drop(parts, -1), else: parts
          n = length(lines)

          lines
          |> Enum.with_index()
          |> Enum.map_reduce(0, fn {line, i}, at ->
            entry = %{
              path: path,
              raw: line,
              # Where this line STARTS. Recorded during the read so a repair
              # cuts at a position derived from the same bytes it parsed,
              # rather than from a fresh stat taken afterwards.
              at: at,
              terminated: i < n - 1 or terminated_file?
            }

            {entry, at + byte_size(line) + 1}
          end)
          |> elem(0)
          # A stray blank line is not a record and not corruption — drop it, as
          # the moduledoc promises. (`terminated` on the survivors is unaffected:
          # only the file's true last line can ever be unterminated.)
          |> Enum.reject(&(&1.raw == ""))
      end
    end)
  end

  defp replay([], acc, ctx), do: finish(acc, ctx)

  # Ra policy, frame-strict: the FINAL line of the LAST segment with no trailing
  # newline is a torn write even when its bytes happen to decode — the frame is
  # the whole line, and leaving decodable-but-unterminated bytes in place would
  # concatenate the next append onto the same line, corrupting the journal one
  # write later. Truncate it, keep the prefix, stay healthy. (Found by the I5
  # byte-cut fuzz in test/invariants/storage_invariants_test.exs.)
  defp replay([%{terminated: false} = entry], acc, ctx), do: torn_tail(entry, acc, ctx)

  defp replay([entry | rest], acc, ctx) do
    case Jason.decode(entry.raw) do
      {:ok, record} ->
        if continuous?(acc, record) do
          linked(record, entry, rest, acc, ctx)
        else
          # An id gap (or a record without an integer id) means complete
          # records were LOST — a deleted/truncated interior segment. Silently
          # concatenating around the hole would fabricate continuity, so this
          # is damage, exactly like interior corruption. (Found by the I6
          # missing-middle-segment invariant.)
          alarm(ctx.dir, entry)
          {:damaged, Enum.reverse(acc)}
        end

      {:error, _} ->
        handle_bad_line(entry, rest, acc, ctx)
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
  defp linked(record, _entry, rest, acc, %{chain: nil} = ctx),
    do: replay(rest, [record | acc], ctx)

  defp linked(record, entry, rest, acc, ctx) do
    if Chain.check(record, prev_hash(acc, record), entry.raw) == :ok do
      replay(rest, [record | acc], ctx)
    else
      alarm(ctx.dir, entry)
      {:damaged, Enum.reverse(acc)}
    end
  end

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

  defp handle_bad_line(%{terminated: false} = entry, [], acc, ctx),
    do: torn_tail(entry, acc, ctx)

  # Everything else is real data loss, not a torn write: an interior bad line, OR
  # a fully-flushed newline-terminated but corrupt final record. Mark damaged —
  # alarm, delete nothing, leak nothing. Silently truncating a terminated record
  # would mask genuine corruption behind a healthy `:ok`.
  defp handle_bad_line(entry, _rest, acc, ctx) do
    alarm(ctx.dir, entry)
    {:damaged, Enum.reverse(acc)}
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
