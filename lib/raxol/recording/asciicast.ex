defmodule Raxol.Recording.Asciicast do
  @moduledoc """
  Serializes and deserializes asciinema v2 `.cast` files.

  The asciicast v2 format is:
  - Line 1: JSON header with version, width, height, timestamp, env
  - Remaining lines: `[elapsed_seconds, "o", "output_data"]` (newline-delimited JSON)

  See: https://docs.asciinema.org/manual/asciicast/v2/

  ## Concurrency

  `append!/2` assumes a **single writer per file**. It opens the file several
  times (validate header, check/fix the trailing newline, append the body) with
  no cross-process locking, so two concurrent appenders to the same path can
  interleave their bodies or both add a trailing newline. The intended usage
  (e.g. `Evidence.Capture` owning one `.cast` per run) already serializes writes
  through a single process; keep that contract. Do not append to one file from
  multiple processes concurrently.
  """

  require Logger

  alias Raxol.Recording.Session

  @doc "Writes a session to a .cast file."
  @spec write!(Session.t(), Path.t()) :: :ok
  def write!(%Session{} = session, path) do
    content = encode(session)
    File.write!(path, content)
  end

  @doc """
  Appends events to an existing `.cast` file without rewriting its header.

  Validates the existing v2 header, then writes the new event lines to the end
  of the file. Events carry `elapsed_us` relative to the session start (the same
  time base the header's `timestamp` anchors), so their timestamps are preserved
  verbatim. A defensive trailing newline is added first so a header-only file (or
  one whose final byte is not a newline) never fuses the appended line onto the
  previous one.

  Accepts either a list of `Session.event()` tuples or a `Session` (its `events`
  are appended). Raises if the file is missing or its header is not a valid
  asciicast v2 header. Appending an empty event list is a no-op: the file is left
  byte-for-byte untouched (no trailing-newline fixup, no header validation).

  **Single-writer contract:** this is not safe against concurrent appenders to
  the same path (see the module's Concurrency note). Call it from a single owning
  process per file.
  """
  @spec append!([Session.event()] | Session.t(), Path.t()) :: :ok
  def append!(%Session{events: events}, path), do: append!(events, path)

  def append!([], _path), do: :ok

  def append!(events, path) when is_list(events) do
    validate_header!(path)
    ensure_trailing_newline!(path)

    body = Enum.map_join(events, "\n", &encode_event/1) <> "\n"

    File.write!(path, body, [:append])
  end

  @doc "Reads a .cast file into a session. Returns `{:ok, session}` or `{:error, reason}`."
  @spec read(Path.t()) :: {:ok, Session.t()} | {:error, term()}
  def read(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, decode(content)}
    end
  rescue
    # Only expected malformed-input exceptions become `{:error, _}`:
    # a corrupt/empty header raises `Jason.DecodeError`, and a structurally
    # invalid header (e.g. a non-integer `timestamp`) raises `ArgumentError`
    # from `decode/1`. Any other exception is a genuine bug and must propagate
    # rather than be masked as a read failure.
    e in [Jason.DecodeError, ArgumentError, MatchError] -> {:error, e}
  end

  @doc "Reads a .cast file into a session. Raises on failure."
  @spec read!(Path.t()) :: Session.t()
  def read!(path) do
    case read(path) do
      {:ok, session} -> session
      {:error, reason} -> raise "Failed to read #{path}: #{inspect(reason)}"
    end
  end

  @doc "Encodes a session to asciicast v2 format string."
  @spec encode(Session.t()) :: String.t()
  def encode(%Session{} = session) do
    header = encode_header(session)
    events = Enum.map_join(session.events, "\n", &encode_event/1)

    if events == "" do
      header <> "\n"
    else
      header <> "\n" <> events <> "\n"
    end
  end

  @doc """
  Decodes an asciicast v2 format string into a session.

  Torn-tail tolerant: if the file was truncated mid-write (process killed) so the
  final line has no trailing newline, that torn line is dropped *silently* and
  every complete event preceding it is recovered. A line that was fully flushed
  (newline-terminated) but is still unparseable -- whether interior or the last
  event line -- is committed corruption: parsing stops there, returns the events
  collected so far, and logs a warning rather than raising. A valid cast
  round-trips unchanged.

  The header line must be present and valid JSON (it is written in full before
  any event, so a truncated recording still has an intact header). A missing or
  corrupt header raises; call `read/1` for the non-raising `{:ok, _} | {:error, _}`
  variant.
  """
  @spec decode(String.t()) :: Session.t()
  def decode(content) do
    [header_line | event_lines] = String.split(content, "\n")

    header = Jason.decode!(String.trim(header_line))

    events = decode_events(event_lines)

    %Session{
      width: header["width"],
      height: header["height"],
      started_at: parse_timestamp(header["timestamp"]),
      title: header["title"],
      command: header["command"],
      idle_time_limit: header["idle_time_limit"],
      theme: header["theme"],
      env: header["env"] || %{},
      events: events
    }
  end

  # -- Private --

  defp encode_header(%Session{} = s) do
    %{
      "version" => 2,
      "width" => s.width,
      "height" => s.height,
      "timestamp" => DateTime.to_unix(s.started_at)
    }
    |> maybe_put("title", s.title)
    |> maybe_put("command", s.command)
    |> maybe_put("idle_time_limit", s.idle_time_limit)
    |> maybe_put("theme", s.theme)
    |> maybe_put("env", if(s.env == %{}, do: nil, else: s.env))
    |> Jason.encode!()
  end

  defp encode_event({elapsed_us, type, data}) do
    seconds = elapsed_us / 1_000_000

    type_str =
      case type do
        :input -> "i"
        _ -> "o"
      end

    Jason.encode!([seconds, type_str, data])
  end

  # Parses event lines, distinguishing two failure shapes at the tail:
  #
  #   * `rest == []` -- the unparseable line had no trailing newline, i.e. the
  #     writer was killed mid-write. This is a genuinely torn tail; drop it
  #     silently and recover the complete events before it.
  #
  #   * anything else (an interior line, or `rest == [""]` where the final line
  #     WAS newline-terminated and fully flushed but is still unparseable) --
  #     that is real corruption of a committed line, so log a warning.
  #
  # In both cases parsing stops and everything recovered so far is returned.
  defp decode_events(lines), do: decode_events(lines, [])

  defp decode_events([], acc), do: Enum.reverse(acc)

  defp decode_events([line | rest], acc) do
    cond do
      blank?(line) ->
        decode_events(rest, acc)

      true ->
        case decode_event(line) do
          {:ok, event} ->
            decode_events(rest, [event | acc])

          :error when rest == [] ->
            # No trailing newline: torn mid-write. Expected when the writer was
            # killed; drop it silently and return the complete events.
            Enum.reverse(acc)

          :error ->
            # Either an interior malformed line or a newline-terminated (fully
            # flushed) but unparseable final line -- committed corruption, alarm.
            Logger.warning(
              "Raxol.Recording.Asciicast: malformed event line, stopping decode " <>
                "and returning #{length(acc)} recovered event(s)"
            )

            Enum.reverse(acc)
        end
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp decode_event(line) do
    case Jason.decode(line) do
      {:ok, [seconds, type, data]}
      when is_number(seconds) and is_binary(type) and is_binary(data) ->
        {:ok, {round(seconds * 1_000_000), decode_event_type(type), data}}

      _ ->
        :error
    end
  end

  defp decode_event_type("i"), do: :input
  defp decode_event_type(_), do: :output

  defp validate_header!(path) do
    line =
      path
      |> File.stream!()
      |> Enum.take(1)
      |> List.first()

    case line && Jason.decode(String.trim(line)) do
      {:ok, %{"version" => 2}} ->
        :ok

      _ ->
        raise ArgumentError,
              "cannot append to #{path}: not a valid asciicast v2 file (missing or invalid header)"
    end
  end

  # O(1): stat the size and read only the final byte, so appending to a large
  # recording stays cheap. Reading the whole file here would make incremental
  # append O(n^2) over a session (`Evidence.Capture` appends once per run).
  defp ensure_trailing_newline!(path) do
    case last_byte(path) do
      :empty ->
        :ok

      {:ok, "\n"} ->
        :ok

      {:ok, _other} ->
        File.write!(path, "\n", [:append])

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp last_byte(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: 0}} ->
        :empty

      {:ok, %File.Stat{size: size}} ->
        pread_last_byte(path, size)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp pread_last_byte(path, size) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, io} ->
        result = :file.pread(io, size - 1, 1)
        :file.close(io)

        case result do
          {:ok, byte} -> {:ok, byte}
          :eof -> :empty
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
  end

  # The header parsed as JSON but its `timestamp` is the wrong shape (a string,
  # float, list, ...). Raise a descriptive `ArgumentError` so `read/1` reports a
  # structurally-invalid header distinctly, instead of leaking a
  # `FunctionClauseError` that the old catch-all masked as a plain read failure.
  defp parse_timestamp(other) do
    raise ArgumentError,
          "invalid asciicast header: timestamp must be an integer Unix time, " <>
            "got: #{inspect(other)}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
