defmodule Raxol.AgentClientProtocol.Transport.FramerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.AgentClientProtocol.Transport.Framer

  describe "basic framing" do
    test "a single push containing one complete line yields that frame" do
      {frames, _framer} = Framer.new() |> Framer.push(~s({"a":1}\n))
      assert frames == [~s({"a":1})]
    end

    test "no newline yet yields no frames and buffers the partial data" do
      {frames, framer} = Framer.new() |> Framer.push(~s({"a":1}))
      assert frames == []

      {frames, _framer} = Framer.push(framer, "\n")
      assert frames == [~s({"a":1})]
    end

    test "multiple frames in a single chunk are all yielded, in order" do
      chunk = ~s({"a":1}\n{"b":2}\n{"c":3}\n)
      {frames, _framer} = Framer.new() |> Framer.push(chunk)
      assert frames == [~s({"a":1}), ~s({"b":2}), ~s({"c":3})]
    end

    test "a frame split across two chunks is reassembled" do
      framer = Framer.new()
      {frames1, framer} = Framer.push(framer, ~s({"a":))
      assert frames1 == []
      {frames2, _framer} = Framer.push(framer, ~s(1}\n))
      assert frames2 == [~s({"a":1})]
    end

    test "one-byte-at-a-time feeding reconstructs frames exactly" do
      payload = ~s({"a":1}\n{"b":2}\n)

      {frames, _framer} =
        payload
        |> String.to_charlist()
        |> Enum.reduce({[], Framer.new()}, fn byte, {acc, framer} ->
          {new_frames, framer} = Framer.push(framer, <<byte>>)
          {acc ++ new_frames, framer}
        end)

      assert frames == [~s({"a":1}), ~s({"b":2})]
    end

    test "an empty push yields no frames and does not disturb the buffer" do
      framer = Framer.new()
      {frames1, framer} = Framer.push(framer, ~s({"a":1}))
      assert frames1 == []
      {frames2, framer} = Framer.push(framer, "")
      assert frames2 == []
      {frames3, _framer} = Framer.push(framer, "\n")
      assert frames3 == [~s({"a":1})]
    end
  end

  describe "CRLF handling" do
    test "a trailing CR before the LF is trimmed" do
      {frames, _framer} = Framer.new() |> Framer.push("{\"a\":1}\r\n")
      assert frames == [~s({"a":1})]
    end

    test "LF and CRLF terminated lines can be mixed in the same stream" do
      chunk = "{\"a\":1}\r\n{\"b\":2}\n{\"c\":3}\r\n"
      {frames, _framer} = Framer.new() |> Framer.push(chunk)
      assert frames == [~s({"a":1}), ~s({"b":2}), ~s({"c":3})]
    end

    test "a CR split from its LF across chunks is still trimmed" do
      framer = Framer.new()
      {frames1, framer} = Framer.push(framer, "{\"a\":1}\r")
      assert frames1 == []
      {frames2, _framer} = Framer.push(framer, "\n")
      assert frames2 == [~s({"a":1})]
    end
  end

  describe "empty line skipping" do
    test "a bare newline is skipped, not yielded as an empty frame" do
      {frames, _framer} = Framer.new() |> Framer.push("\n")
      assert frames == []
    end

    test "a bare CRLF is skipped" do
      {frames, _framer} = Framer.new() |> Framer.push("\r\n")
      assert frames == []
    end

    test "keep-alive newlines interleaved with real frames are dropped, order preserved" do
      chunk = "\n{\"a\":1}\n\n{\"b\":2}\n\n"
      {frames, _framer} = Framer.new() |> Framer.push(chunk)
      assert frames == [~s({"a":1}), ~s({"b":2})]
    end
  end

  describe "oversized frames" do
    test "a line exceeding max_frame_bytes yields a frame_too_large error" do
      framer = Framer.new(max_frame_bytes: 10)
      oversized = String.duplicate("x", 20)
      {frames, _framer} = Framer.push(framer, oversized <> "\n")

      assert [{:error, {:frame_too_large, size}}] = frames
      assert size == 20
    end

    test "an oversized frame does not corrupt the frame that follows it (same chunk)" do
      framer = Framer.new(max_frame_bytes: 15)
      oversized = String.duplicate("x", 20)
      chunk = oversized <> "\n" <> ~s({"ok":true}) <> "\n"

      {frames, _framer} = Framer.push(framer, chunk)

      assert [{:error, {:frame_too_large, 20}}, ~s({"ok":true})] == frames
    end

    test "resync works when the oversized line's terminator arrives in a later chunk" do
      framer = Framer.new(max_frame_bytes: 20)

      # First chunk alone already exceeds the limit with no newline yet:
      # the framer must flag it immediately (not wait indefinitely) and
      # enter resync mode.
      {frames1, framer} = Framer.push(framer, String.duplicate("x", 25))
      assert [{:error, {:frame_too_large, 25}}] = frames1

      # More of the same oversized line, still no newline: silently
      # discarded while resyncing, no further errors.
      {frames2, framer} = Framer.push(framer, String.duplicate("y", 100))
      assert frames2 == []

      # The oversized line finally terminates, and a valid frame follows
      # in the same chunk: resync completes and framing resumes cleanly.
      {frames3, framer} = Framer.push(framer, "\n" <> ~s({"ok":true}) <> "\n")
      assert frames3 == [~s({"ok":true})]

      # Framer keeps working normally afterwards.
      {frames4, _framer} = Framer.push(framer, ~s({"still":"fine"}\n))
      assert frames4 == [~s({"still":"fine"})]
    end

    test "resync across one-byte-at-a-time feeding of an oversized line" do
      framer = Framer.new(max_frame_bytes: 15)
      oversized = String.duplicate("z", 50)
      trailer = ~s({"ok":true}\n)

      {frames, _framer} =
        (String.to_charlist(oversized) ++ [?\n] ++ String.to_charlist(trailer))
        |> Enum.reduce({[], framer}, fn byte, {acc, framer} ->
          {new_frames, framer} = Framer.push(framer, <<byte>>)
          {acc ++ new_frames, framer}
        end)

      assert [{:error, {:frame_too_large, 16}}, ~s({"ok":true})] == frames
    end

    test "a frame exactly at the limit is not flagged as oversized" do
      framer = Framer.new(max_frame_bytes: 10)
      exact = String.duplicate("x", 10)
      {frames, _framer} = Framer.push(framer, exact <> "\n")
      assert frames == [exact]
    end

    test "a 5MB frame under the default 64MiB limit passes through untouched" do
      big = String.duplicate("a", 5 * 1024 * 1024)
      chunk = ~s({"data":") <> big <> ~s("}\n)

      {frames, _framer} = Framer.new() |> Framer.push(chunk)

      assert [frame] = frames
      assert byte_size(frame) == byte_size(chunk) - 1
    end

    test "new/1 rejects a non-positive max_frame_bytes" do
      assert_raise ArgumentError, fn -> Framer.new(max_frame_bytes: 0) end
      assert_raise ArgumentError, fn -> Framer.new(max_frame_bytes: -1) end
    end
  end

  describe "volume" do
    test "no data loss across 10k frames, fed in randomly sized chunks" do
      lines = for i <- 1..10_000, do: ~s({"seq":#{i}})
      payload = Enum.join(lines, "\n") <> "\n"

      {frames, framer} = feed_in_random_chunks(payload, Framer.new())

      assert frames == lines
      assert framer.buffer == ""
    end
  end

  describe "properties" do
    property "any re-chunking of concatenated JSON lines yields the original frames in order" do
      check all(
              lines <- list_of(json_line_generator(), min_length: 0, max_length: 50),
              max_runs: 50
            ) do
        payload = Enum.map_join(lines, "\n", & &1) <> if(lines == [], do: "", else: "\n")

        {frames, framer} = feed_in_random_chunks(payload, Framer.new())

        assert frames == lines
        assert framer.buffer == ""
      end
    end

    property "CRLF and LF terminators mixed at random yield identical frames either way" do
      check all(
              lines <- list_of(json_line_generator(), min_length: 1, max_length: 30),
              terminators <- list_of(member_of(["\n", "\r\n"]), length: length(lines)),
              max_runs: 50
            ) do
        payload =
          lines
          |> Enum.zip(terminators)
          |> Enum.map_join(fn {line, term} -> line <> term end)

        {frames, framer} = feed_in_random_chunks(payload, Framer.new())

        assert frames == lines
        assert framer.buffer == ""
      end
    end

    property "an oversized frame errors then resyncs; every frame after it still parses" do
      check all(
              before_lines <- list_of(json_line_generator(), max_length: 5),
              after_lines <- list_of(json_line_generator(), min_length: 1, max_length: 5),
              max_runs: 30
            ) do
        # Comfortably larger than any before_lines/after_lines entry the
        # generator can produce (map_of with max_length 4, keys/values
        # each small), so only the deliberately oversized line trips it.
        max_frame_bytes = 4096
        oversized = String.duplicate("o", max_frame_bytes + 512)

        payload =
          Enum.map_join(before_lines, "", &(&1 <> "\n")) <>
            oversized <>
            "\n" <>
            Enum.map_join(after_lines, "", &(&1 <> "\n"))

        {frames, framer} =
          feed_in_random_chunks(payload, Framer.new(max_frame_bytes: max_frame_bytes))

        # The reported size is only a lower bound at the moment the bound
        # was crossed (it may be reported before the oversized line's own
        # terminator has even arrived, depending on how the bytes were
        # chunked), so pin its shape/bound rather than its exact value —
        # what matters is that resync recovers exactly the surrounding
        # good frames, in order, with no loss or duplication.
        n_before = length(before_lines)
        {prefix, [error_frame | suffix]} = Enum.split(frames, n_before)

        assert prefix == before_lines
        assert suffix == after_lines
        assert {:error, {:frame_too_large, size}} = error_frame
        assert size > max_frame_bytes
        assert size <= byte_size(oversized)
        assert framer.buffer == ""
      end
    end
  end

  # -- Helpers ------------------------------------------------------------

  defp json_line_generator do
    gen all(term <- json_term_generator()) do
      Jason.encode!(term)
    end
  end

  defp json_term_generator do
    one_of([
      integer(),
      boolean(),
      string(:alphanumeric, max_length: 12),
      map_of(string(:alphanumeric, min_length: 1, max_length: 8), integer(), max_length: 4)
    ])
  end

  # Feeds `payload` into `framer` via a sequence of randomly sized chunks
  # (including possible zero-length and single-byte chunks), returning the
  # accumulated frames (in order) and the final framer state.
  defp feed_in_random_chunks(payload, framer) do
    chunks = random_chunks(payload)

    Enum.reduce(chunks, {[], framer}, fn chunk, {acc, framer} ->
      {new_frames, framer} = Framer.push(framer, chunk)
      {acc ++ new_frames, framer}
    end)
  end

  defp random_chunks(""), do: [""]

  defp random_chunks(payload) do
    total = byte_size(payload)
    do_random_chunks(payload, total, [])
  end

  defp do_random_chunks(<<>>, _total, acc), do: Enum.reverse(acc)

  defp do_random_chunks(rest, total, acc) do
    remaining = byte_size(rest)
    take = Enum.random(1..min(remaining, max(1, div(total, 3) + 1)))
    <<chunk::binary-size(^take), tail::binary>> = rest
    do_random_chunks(tail, total, [chunk | acc])
  end
end
