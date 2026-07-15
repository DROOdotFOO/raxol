defmodule Raxol.Agent.Journal.FileStore.Reader do
  @moduledoc """
  Tolerant replay of a session's JSONL journal segments (harness-spec-backend
  §4, component 2 — the Reader).

  Segments are replayed in ascending order into an ordered record stream. Two
  failure policies, per the spec:

    * **Torn tail (Ra policy).** A parse failure on the *final* line of the *last*
      segment is a crash mid-write. The torn bytes are truncated away, everything
      before is recovered, and the session stays healthy (`{:ok, records}`).

    * **Interior corruption.** A parse failure anywhere else marks the session
      damaged. A hard alarm fires (`Logger.error` + a telemetry event), **nothing
      is deleted**, and the damaged content is **never** returned — `scan/2`
      returns `{:damaged, records_before}` and callers must not surface it.
  """

  require Logger

  @telemetry_damaged [:raxol, :agent, :journal, :damaged]

  @typedoc "Result of a replay scan."
  @type result :: {:ok, [map()]} | {:damaged, [map()]}

  @doc """
  Replay all journal segments under `dir` in ascending order.

  Returns `{:ok, records}` for a healthy or torn-tail-recovered journal (the
  torn tail is physically truncated as a side effect), or `{:damaged, records}`
  when interior corruption was detected. In the damaged case `records` are only
  the complete records preceding the corruption and MUST NOT be surfaced
  downstream — callers map this to an error.
  """
  @spec scan(Path.t(), keyword()) :: result
  def scan(dir, _opts \\ []) do
    dir
    |> Path.join("journal")
    |> list_segments()
    |> build_entries()
    |> replay([], dir)
  end

  @doc "Highest offset (id) present in a healthy replay, or 0 if empty/damaged."
  @spec last_offset(Path.t()) :: non_neg_integer()
  def last_offset(dir) do
    case scan(dir) do
      {:ok, records} -> records |> List.last() |> record_id()
      {:damaged, _} -> 0
    end
  end

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
          |> Enum.map(fn {line, i} ->
            %{path: path, raw: line, terminated: i < n - 1 or terminated_file?}
          end)
          # A stray blank line is not a record and not corruption — drop it, as
          # the moduledoc promises. (`terminated` on the survivors is unaffected:
          # only the file's true last line can ever be unterminated.)
          |> Enum.reject(&(&1.raw == ""))
      end
    end)
  end

  defp replay([], acc, _dir), do: {:ok, Enum.reverse(acc)}

  # Ra policy, frame-strict: the FINAL line of the LAST segment with no trailing
  # newline is a torn write even when its bytes happen to decode — the frame is
  # the whole line, and leaving decodable-but-unterminated bytes in place would
  # concatenate the next append onto the same line, corrupting the journal one
  # write later. Truncate it, keep the prefix, stay healthy. (Found by the I5
  # byte-cut fuzz in test/invariants/storage_invariants_test.exs.)
  defp replay([%{terminated: false} = entry], acc, _dir) do
    truncate_torn(entry)
    {:ok, Enum.reverse(acc)}
  end

  defp replay([entry | rest], acc, dir) do
    case Jason.decode(entry.raw) do
      {:ok, record} ->
        if continuous?(acc, record) do
          replay(rest, [record | acc], dir)
        else
          # An id gap (or a record without an integer id) means complete
          # records were LOST — a deleted/truncated interior segment. Silently
          # concatenating around the hole would fabricate continuity, so this
          # is damage, exactly like interior corruption. (Found by the I6
          # missing-middle-segment invariant.)
          alarm(dir, entry)
          {:damaged, Enum.reverse(acc)}
        end

      {:error, _} ->
        handle_bad_line(entry, rest, acc, dir)
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

  # Torn tail (Ra policy): the *final* line of the *last* segment has NO trailing
  # newline — a crash mid-`:file.write`. Truncate the incomplete bytes, recover
  # everything before, session stays healthy.
  defp handle_bad_line(%{terminated: false} = entry, [], acc, _dir) do
    truncate_torn(entry)
    {:ok, Enum.reverse(acc)}
  end

  # Everything else is real data loss, not a torn write: an interior bad line, OR
  # a fully-flushed newline-terminated but corrupt final record. Mark damaged —
  # alarm, delete nothing, leak nothing. Silently truncating a terminated record
  # would mask genuine corruption behind a healthy `:ok`.
  defp handle_bad_line(entry, _rest, acc, dir) do
    alarm(dir, entry)
    {:damaged, Enum.reverse(acc)}
  end

  defp truncate_torn(%{path: path, raw: raw, terminated: terminated}) do
    size = File.stat!(path).size
    newline = if terminated, do: 1, else: 0
    keep = max(size - byte_size(raw) - newline, 0)

    {:ok, io} = :file.open(path, [:read, :write, :binary])

    try do
      {:ok, _} = :file.position(io, keep)
      :ok = :file.truncate(io)
      :ok = :file.datasync(io)
    after
      :file.close(io)
    end

    :ok
  end

  defp alarm(dir, %{path: path}) do
    Logger.error(
      "[Journal] interior corruption detected in #{path}; session marked :damaged. " <>
        "Nothing deleted, damaged content withheld from replay."
    )

    :telemetry.execute(@telemetry_damaged, %{count: 1}, %{dir: dir, segment: path})
    :ok
  end
end
