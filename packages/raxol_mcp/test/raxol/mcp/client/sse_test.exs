defmodule Raxol.MCP.Client.SSETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.MCP.Client.SSE

  # ADR-0037 validation item 5, framing tolerance: `data:` with and without the
  # following space, `\n\n` and `\r\n\r\n` separators, frames split at every
  # byte boundary, and interleaved `event:` and `id:` fields.

  # A payload may contain anything except the bytes that end a frame: a `\n\n`
  # inside a data payload IS a frame boundary, and generating one would be
  # generating a different stream than the one being asserted about.
  defp payload do
    string(:alphanumeric, min_length: 1, max_length: 24)
  end

  defp separator, do: member_of(["\n\n", "\r\n\r\n", "\r\r"])
  defp eol, do: member_of(["\n", "\r\n", "\r"])
  defp data_prefix, do: member_of(["data: ", "data:"])

  # One frame: a `data:` line, optionally preceded by `event:` and `id:` lines,
  # with the line endings and the `data:` spelling drawn independently. That
  # independence is the point: the two measured upstreams differ in exactly one
  # of these choices.
  defp frame(payload) do
    gen all(
          prefix <- data_prefix(),
          line_end <- eol(),
          event <- one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 8)]),
          id <- one_of([constant(nil), string(:alphanumeric, min_length: 1, max_length: 8)])
        ) do
      [
        if(event, do: "event: #{event}#{line_end}"),
        if(id, do: "id:#{id}#{line_end}"),
        "#{prefix}#{payload}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join()
    end
  end

  defp stream do
    gen all(
          payloads <- list_of(payload(), min_length: 1, max_length: 6),
          frames <- fixed_list(Enum.map(payloads, &frame/1)),
          separators <- list_of(separator(), length: length(frames))
        ) do
      {assemble(frames, separators), payloads}
    end
  end

  defp assemble(frames, separators) do
    frames
    |> Enum.zip(separators)
    |> Enum.map_join(fn {frame, separator} -> frame <> separator end)
  end

  defp feed(bytes, size) do
    bytes
    |> chunk_every(size)
    |> Enum.reduce({[], ""}, fn chunk, {payloads, buffer} ->
      {parsed, remainder} = SSE.payloads(buffer <> chunk)
      {payloads ++ parsed, remainder}
    end)
  end

  defp chunk_every(bytes, size) do
    Stream.unfold(bytes, fn
      "" -> nil
      rest -> {binary_part(rest, 0, min(size, byte_size(rest))), rest_after(rest, size)}
    end)
  end

  defp rest_after(rest, size) do
    taken = min(size, byte_size(rest))
    binary_part(rest, taken, byte_size(rest) - taken)
  end

  property "every payload survives every framing, whole" do
    check all({bytes, payloads} <- stream()) do
      assert {^payloads, ""} = SSE.payloads(bytes)
    end
  end

  property "a stream split at every byte boundary parses identically" do
    # One byte at a time is the worst case a chunked response can produce, and
    # it is where a parser that trims an ambiguous trailing `\r` loses a frame:
    # `\r` alone is a proper prefix of both `\r\r` and `\r\n\r\n`.
    check all({bytes, payloads} <- stream()) do
      assert {^payloads, ""} = feed(bytes, 1)
    end
  end

  property "an arbitrary chunking parses identically" do
    check all(
            {bytes, payloads} <- stream(),
            size <- integer(1..48)
          ) do
      assert {^payloads, ""} = feed(bytes, size)
    end
  end

  describe "the three deliberate differences from the earn parser" do
    test "data: is accepted with and without the following space" do
      assert {[~s({"a":1})], ""} = SSE.payloads(~s(data: {"a":1}\n\n))
      assert {[~s({"a":1})], ""} = SSE.payloads(~s(data:{"a":1}\n\n))
    end

    test "exactly one space is stripped, so a payload keeps its own leading space" do
      assert {[" indented"], ""} = SSE.payloads("data:  indented\n\n")
    end

    test "event: and id: are retained rather than dropped" do
      assert {:ok, frame} = SSE.parse_frame("event: message\r\nid: 42\r\ndata: {}")
      assert frame.event == "message"
      assert frame.id == "42"
      assert frame.data == "{}"
    end

    test "CRLF and bare CR frames parse like LF ones" do
      assert {["one", "two"], ""} = SSE.payloads("data: one\r\n\r\ndata: two\r\n\r\n")
      assert {["one"], ""} = SSE.payloads("data: one\r\r")
    end
  end

  describe "frames that carry no payload" do
    test "a comment-only keepalive yields nothing and is not an error" do
      assert {[], ""} = SSE.payloads(": keepalive\n\n")
      assert {:error, :no_data} = SSE.parse_frame(": keepalive")
    end

    test "an event with no data yields nothing" do
      assert {[], ""} = SSE.payloads("event: endpoint\n\n")
    end

    test "multiple data lines in one frame are one payload joined with a newline" do
      assert {["{\n}"], ""} = SSE.payloads("data: {\ndata: }\n\n")
    end
  end

  describe "the remainder" do
    test "an unterminated frame is held, not emitted" do
      assert {["one"], "data: two"} = SSE.payloads("data: one\n\ndata: two")
    end

    test "a partial separator is held whole" do
      # Held rather than consumed: the next chunk may complete it.
      assert {[], "data: one\r\n\r"} = SSE.payloads("data: one\r\n\r")
      assert {["one"], ""} = SSE.payloads("data: one\r\n\r" <> "\n")
    end
  end

  # A one-shot HTTP response body is every byte there will ever be, so its
  # unterminated tail is the last frame rather than a partial one. Dropping it
  # discarded the WHOLE response from a server that omits the trailing blank
  # line, with no reply and no log, stalling the caller for its full
  # `call_timeout`.
  describe "a complete body" do
    test "yields a lone frame that was never terminated" do
      assert SSE.complete_payloads(~s(data: {"id":1})) == [~s({"id":1})]
    end

    test "yields the terminated frames and the unterminated tail, in order" do
      assert SSE.complete_payloads("data: one\n\ndata: two") == ["one", "two"]
    end

    test "agrees with payloads/1 when the body is properly terminated" do
      body = "data: one\n\ndata: two\n\n"
      assert {payloads, ""} = SSE.payloads(body)
      assert SSE.complete_payloads(body) == payloads
    end

    test "a trailing keepalive comment is still not a payload" do
      assert SSE.complete_payloads("data: one\n\n: keepalive") == ["one"]
      assert SSE.complete_payloads("") == []
    end
  end
end
