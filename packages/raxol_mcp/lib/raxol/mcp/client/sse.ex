defmodule Raxol.MCP.Client.SSE do
  @moduledoc """
  A tolerant server-sent-events parser for MCP responses over HTTP.

  ADR-0037 decision 3. Modelled on `Raxol.Earn.Transport.SSE.Parser`, which
  splits frames and has the caller buffer the remainder
  (`packages/raxol_earn/lib/raxol/earn/transport/sse/parser.ex:24-32`), with
  three deliberate differences. Copying rather than depending is forced by the
  package graph: `raxol_earn` sits above `raxol_payments`, and this package
  depends only on `raxol_core` and `jason`.

  1. **`data:` is accepted with and without the following space.** TronGrid
     emits `data: {...}` and TronScan emits `data:{...}`, both measured on live
     handshakes on 2026-08-31 (`docs/proposals/web3-upstream-survey.md:79-82`).
     A strict parser breaks on one of them.
  2. **`event:` and `id:` are retained, not dropped.** The earn parser
     discards both, which is right for its one-event-type stream and wrong
     here: legacy HTTP+SSE carries `event: endpoint`, and stream resumption
     needs the last id.
  3. **CRLF and bare CR are accepted.** The earn parser splits frames on
     `"\\n\\n"` and lines on `"\\n"` only. The SSE grammar permits `\\r\\n\\r\\n`
     and bare `\\r`, and both measured upstreams sit behind edges that can
     normalize line endings, so an LF-only parser would turn one rewritten
     response into a single unbounded partial frame that never completes.

  Nothing here is stateful: a caller prepends the remainder of one call to the
  next chunk. That is what makes a response split at an arbitrary byte
  boundary parse the same as one that arrived whole.

  ## Frame boundaries and partial separators

  A frame ends at the first `\\n\\n`, `\\r\\n\\r\\n` or `\\r\\r`, whichever comes
  first, longest match at a given position. Everything after the last complete
  separator is the remainder, INCLUDING a trailing `\\r` or `\\r\\n` that may
  turn out to be the first half of a separator once more bytes arrive. No frame
  is ever emitted on a partial separator, so `split_frames/1` applied
  incrementally and applied once produce the same frames.
  """

  # Leftmost-longest: `:binary.match/2` with a pattern list returns the
  # earliest match and, among matches at the same position, the longest. So
  # `\r\n\r\n` wins over the `\r\r`-shaped read of its own bytes at that
  # position, and a lone `\n\n` inside a CRLF stream is still a boundary.
  @separators ["\r\n\r\n", "\n\n", "\r\r"]
  @line_breaks ["\r\n", "\n", "\r"]

  @type frame :: %{event: String.t() | nil, id: String.t() | nil, data: binary()}

  @doc """
  Split bytes into complete frames plus the unterminated remainder.

      iex> Raxol.MCP.Client.SSE.split_frames("data: 1\\n\\ndata: 2\\n\\n")
      {["data: 1", "data: 2"], ""}

      iex> Raxol.MCP.Client.SSE.split_frames("data: a\\r\\n\\r\\ndata: b")
      {["data: a"], "data: b"}
  """
  @spec split_frames(binary()) :: {[binary()], binary()}
  def split_frames(bytes) when is_binary(bytes), do: split(bytes, [])

  defp split(bytes, frames) do
    case :binary.match(bytes, @separators) do
      {position, length} ->
        frame = binary_part(bytes, 0, position)
        consumed = position + length
        rest = binary_part(bytes, consumed, byte_size(bytes) - consumed)
        split(rest, [frame | frames])

      :nomatch ->
        {Enum.reverse(frames), bytes}
    end
  end

  @doc """
  Parse one frame into its `event`, `id` and concatenated `data`.

  `{:error, :no_data}` for a frame with no `data:` line at all, which is what a
  comment-only keepalive frame is. Multiple `data:` lines are joined with a
  single newline, per the SSE grammar: a JSON body split across two lines is
  one payload, not two.
  """
  @spec parse_frame(binary()) :: {:ok, frame()} | {:error, :no_data}
  def parse_frame(frame) when is_binary(frame) do
    parsed =
      frame
      |> :binary.split(@line_breaks, [:global])
      |> Enum.reduce(%{event: nil, id: nil, data: []}, &field/2)

    case parsed.data do
      [] -> {:error, :no_data}
      lines -> {:ok, %{parsed | data: lines |> Enum.reverse() |> Enum.join("\n")}}
    end
  end

  @doc """
  The data payloads of every complete frame, in order, plus the remainder.

  This is the shape a LIVE stream wants: one JSON string per frame, with
  keepalives and frames that carry only an `event:` dropped rather than
  surfacing as empty messages, and the unterminated tail handed back so the
  next chunk can be prepended to it.
  """
  @spec payloads(binary()) :: {[binary()], binary()}
  def payloads(bytes) when is_binary(bytes) do
    {frames, remainder} = split_frames(bytes)
    {Enum.flat_map(frames, &frame_payload/1), remainder}
  end

  @doc """
  The data payloads of a COMPLETE body, including a final frame the sender
  never terminated.

  A one-shot HTTP response body is all the bytes there will ever be, so an
  unterminated tail is the last frame rather than a partial one waiting for
  more. Taking only `payloads/1`'s frames there discarded the WHOLE response
  from any server that omits the trailing blank line -- a single-response body
  is exactly the case where it is easiest to omit -- with no reply and no log,
  stalling the caller for its full `call_timeout`.

      iex> Raxol.MCP.Client.SSE.complete_payloads("data: 1\\n\\ndata: 2")
      ["1", "2"]
  """
  @spec complete_payloads(binary()) :: [binary()]
  def complete_payloads(bytes) when is_binary(bytes) do
    {payloads, remainder} = payloads(bytes)
    payloads ++ frame_payload(remainder)
  end

  defp frame_payload(frame) do
    case parse_frame(frame) do
      {:ok, %{data: ""}} -> []
      {:ok, %{data: data}} -> [data]
      {:error, :no_data} -> []
    end
  end

  # A field line is `name` `:` optional-space `value`. The space after the
  # colon is optional in the grammar and absent from one of the two measured
  # upstreams, so exactly one leading space is stripped rather than all
  # whitespace: a payload that legitimately begins with two spaces keeps one.
  defp field("data:" <> value, parsed), do: %{parsed | data: [strip(value) | parsed.data]}
  defp field("event:" <> value, parsed), do: %{parsed | event: strip(value)}
  defp field("id:" <> value, parsed), do: %{parsed | id: strip(value)}
  defp field(_other, parsed), do: parsed

  defp strip(" " <> value), do: value
  defp strip(value), do: value
end
