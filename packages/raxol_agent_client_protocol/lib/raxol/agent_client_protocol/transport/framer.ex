defmodule Raxol.AgentClientProtocol.Transport.Framer do
  @moduledoc """
  A pure, process-free NDJSON (newline-delimited JSON) line framer.

  ACP's stdio transport is a stream of bytes, not a stream of messages:
  reads arrive in arbitrary chunk sizes (one byte, one line, ten lines,
  half a line) with no guarantee that chunk boundaries line up with frame
  boundaries. This module buffers partial data and yields exactly the
  complete lines a chunk boundary reveals — nothing more, nothing less.

  This is intentionally *just* the byte-splitting layer: it does not
  parse JSON (that is `Raxol.AgentClientProtocol.Rpc.Message.decode/1`'s
  job) and it is not a process (no GenServer, no mailbox) — a caller
  (e.g. the stdio transport) owns reading bytes off the wire and threads
  the returned state through successive `push/2` calls.

  ## Line splitting

  Frames are delimited by `\\n` (LF). A trailing `\\r` immediately before
  the `\\n` is trimmed, so CRLF- and LF-terminated peers interoperate
  transparently — including within the same stream.

  Empty lines (a bare `\\n`, or `\\r\\n` with nothing before it) are
  skipped rather than yielded as empty frames: some peers send bare
  newlines as a keep-alive, and an empty line is never a valid JSON-RPC
  frame.

  ## Oversized frames

  `:max_frame_bytes` (default `#{67_108_864}` = 64 MiB) bounds how much
  unterminated data this module will buffer while waiting for the next
  `\\n`. A line whose length crosses that bound yields
  `{:error, {:frame_too_large, size}}` in the returned list, in the
  position that frame would otherwise have occupied — and then the
  framer *resyncs*: it discards bytes up through the next `\\n` it finds
  (which may span several more `push/2` calls) and resumes normal
  framing from there. One oversized frame never corrupts, drops, or
  merges with the frames that follow it. `size` is the number of bytes
  observed at the moment the bound was crossed (for a frame whose
  terminator hasn't arrived yet, this is a lower bound on the frame's
  true length, not necessarily its final length).

  ## Usage

      framer = Framer.new()
      {frames, framer} = Framer.push(framer, "{\\"a\\":1}\\n{\\"b\\":2")
      # frames == ["{\\"a\\":1}"]
      {frames, framer} = Framer.push(framer, "}\\n")
      # frames == ["{\\"b\\":2}"]
  """

  @default_max_frame_bytes 67_108_864

  @enforce_keys [:max_frame_bytes]
  defstruct buffer: "", max_frame_bytes: @default_max_frame_bytes, skipping: false

  @type t :: %__MODULE__{
          buffer: binary(),
          max_frame_bytes: pos_integer(),
          skipping: boolean()
        }

  @typedoc "One complete, decoded-from-bytes frame (still a raw JSON string, not yet parsed)."
  @type frame :: binary()

  @typedoc "A frame, or an oversized-frame error occupying that frame's position in the list."
  @type frame_or_error :: frame() | {:error, {:frame_too_large, non_neg_integer()}}

  @doc """
  Create a fresh framer with an empty buffer.

  Options:

    * `:max_frame_bytes` — maximum bytes buffered for a single
      unterminated line before it is reported as oversized (see
      moduledoc). Defaults to #{@default_max_frame_bytes} (64 MiB).
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    max_frame_bytes = Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes)

    if not (is_integer(max_frame_bytes) and max_frame_bytes > 0) do
      raise ArgumentError,
            "max_frame_bytes must be a positive integer, got: #{inspect(max_frame_bytes)}"
    end

    %__MODULE__{max_frame_bytes: max_frame_bytes}
  end

  @doc """
  Feed a chunk of bytes (of any size, including empty) into the framer.

  Returns `{frames, framer}`: `frames` is the (possibly empty) list of
  complete frames and/or oversized-frame errors revealed by this chunk,
  in wire order; `framer` is the updated state to pass to the next call.
  """
  @spec push(t(), binary()) :: {[frame_or_error()], t()}
  def push(%__MODULE__{} = framer, chunk) when is_binary(chunk) do
    framer
    |> append(chunk)
    |> drain([])
  end

  # -- Internal ---------------------------------------------------------

  # While skipping (mid-resync after an oversized frame), incoming bytes
  # are never accumulated into the buffer — only scanned for the next
  # `\n`, which cannot itself span a chunk boundary. This keeps memory
  # bounded regardless of how long the oversized line turns out to be.
  @spec append(t(), binary()) :: t()
  defp append(%__MODULE__{skipping: true} = framer, chunk), do: %{framer | buffer: chunk}

  defp append(%__MODULE__{buffer: buffer} = framer, chunk),
    do: %{framer | buffer: buffer <> chunk}

  @spec drain(t(), [frame_or_error()]) :: {[frame_or_error()], t()}
  defp drain(%__MODULE__{skipping: true, buffer: buffer} = framer, acc) do
    case :binary.split(buffer, "\n") do
      [_discarded, rest] ->
        drain(%{framer | buffer: rest, skipping: false}, acc)

      [_no_newline_yet] ->
        {Enum.reverse(acc), %{framer | buffer: ""}}
    end
  end

  defp drain(%__MODULE__{skipping: false, buffer: buffer, max_frame_bytes: max} = framer, acc) do
    case :binary.split(buffer, "\n") do
      [raw_line, rest] ->
        drain(%{framer | buffer: rest}, emit(raw_line, max, acc))

      [pending] ->
        if byte_size(pending) > max do
          acc = [{:error, {:frame_too_large, byte_size(pending)}} | acc]
          {Enum.reverse(acc), %{framer | buffer: "", skipping: true}}
        else
          {Enum.reverse(acc), %{framer | buffer: pending}}
        end
    end
  end

  # A line whose terminator has already been found: emit it (stripped of
  # any trailing CR), an oversized-frame error, or nothing (blank line).
  @spec emit(binary(), pos_integer(), [frame_or_error()]) :: [frame_or_error()]
  defp emit(raw_line, max, acc) do
    line = strip_trailing_cr(raw_line)

    cond do
      byte_size(line) > max -> [{:error, {:frame_too_large, byte_size(line)}} | acc]
      line == "" -> acc
      true -> [line | acc]
    end
  end

  @spec strip_trailing_cr(binary()) :: binary()
  defp strip_trailing_cr(line) do
    size = byte_size(line)

    if size > 0 and :binary.at(line, size - 1) == ?\r do
      :binary.part(line, 0, size - 1)
    else
      line
    end
  end
end
