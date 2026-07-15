defmodule Raxol.Recording.Asciicast do
  @moduledoc """
  Serializes and deserializes asciinema v2 `.cast` files.

  The asciicast v2 format is:
  - Line 1: JSON header with version, width, height, timestamp, env
  - Remaining lines: `[elapsed_seconds, "o", "output_data"]` (newline-delimited JSON)

  See: https://docs.asciinema.org/manual/asciicast/v2/
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
  asciicast v2 header.
  """
  @spec append!([Session.event()] | Session.t(), Path.t()) :: :ok
  def append!(%Session{events: events}, path), do: append!(events, path)

  def append!(events, path) when is_list(events) do
    validate_header!(path)
    ensure_trailing_newline!(path)

    body =
      case Enum.map_join(events, "\n", &encode_event/1) do
        "" -> ""
        joined -> joined <> "\n"
      end

    File.write!(path, body, [:append])
  end

  @doc "Reads a .cast file into a session. Returns `{:ok, session}` or `{:error, reason}`."
  @spec read(Path.t()) :: {:ok, Session.t()} | {:error, term()}
  def read(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, decode(content)}
    end
  rescue
    e -> {:error, e}
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

  Torn-tail tolerant: if the file was truncated mid-write (process killed), the
  final partial/invalid event line is dropped and every complete event preceding
  it is recovered. An invalid *interior* line stops parsing there and returns the
  events collected so far (with a logged warning) rather than raising. A valid
  cast round-trips unchanged.

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

  # Parses event lines, tolerating a truncated/invalid final line at EOF. Stops
  # at the first unparseable line and returns everything recovered so far. The
  # final-line case (the common kill-mid-write outcome) is dropped quietly; an
  # interior malformed line is logged as a warning.
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

          :error when rest == [] or rest == [""] ->
            # Torn final line at EOF: expected when the writer was killed
            # mid-write. Drop it and return the complete events.
            Enum.reverse(acc)

          :error ->
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

  defp ensure_trailing_newline!(path) do
    case File.read(path) do
      {:ok, ""} ->
        :ok

      {:ok, content} ->
        maybe_append_newline!(path, content)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp maybe_append_newline!(path, content) do
    unless String.ends_with?(content, "\n") do
      File.write!(path, "\n", [:append])
    end

    :ok
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(unix) when is_integer(unix) do
    DateTime.from_unix!(unix)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
