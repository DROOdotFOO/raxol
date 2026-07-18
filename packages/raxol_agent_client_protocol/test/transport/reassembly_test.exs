defmodule Raxol.AgentClientProtocol.Transport.ReassemblyTest do
  @moduledoc """
  F8 — envelope wrap/unwrap round-trip + seq-strip, and reassembly
  reordering for the unordered-transport design-stub class. Canonical
  statement lives in `test/INVARIANTS.md` (CORE › Framing/transport, `F8`
  row). This is the buildable stub of a class no shipped transport uses
  yet (`Transport.Envelope` + `Transport.Reassembly`), pure and
  process-free like `Transport.Framer`'s F1-F6 suite:

    * F8a — `Envelope.wrap/2` / `Envelope.unwrap/1` round-trip for any
      frame/tseq pair; the sequence number never leaks into the unwrapped
      frame (seq-strip); a non-enveloped or malformed map is rejected.
    * F8b — `Reassembly.push/3` releases a tseq-enveloped frame sequence
      in original order for ANY arrival permutation (property); duplicates
      (already-released or already-buffered) are dropped with no extra
      release; a contiguous run already buffered cascades in one `push/3`
      call; crossing either watermark (frame-count or byte) yields
      `{:closed, {:transport, :reassembly_overflow}}` and never grows past
      it; nothing here is timer-bounded (no `Process.sleep`/`after`
      anywhere in this file — determinism is asserted by construction, not
      by racing a clock).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.AgentClientProtocol.Transport.Envelope
  alias Raxol.AgentClientProtocol.Transport.Reassembly

  describe "F8a Envelope: wrap/unwrap round-trip, seq-strip, rejection" do
    property "unwrap(wrap(frame, tseq)) == {:ok, tseq, frame} for any frame/tseq" do
      check all(
              frame <- frame_generator(),
              tseq <- positive_integer()
            ) do
        assert Envelope.unwrap(Envelope.wrap(frame, tseq)) == {:ok, tseq, frame}
      end
    end

    test "the wire shape is exactly {acpenv, s, f}" do
      wrapped = Envelope.wrap(%{"method" => "session/update"}, 17)

      assert wrapped == %{
               "acpenv" => 1,
               "s" => 17,
               "f" => %{"method" => "session/update"}
             }
    end

    test "the sequence number never appears inside the unwrapped frame (seq-strip)" do
      frame = %{"jsonrpc" => "2.0", "method" => "session/update", "params" => %{"a" => 1}}
      wrapped = Envelope.wrap(frame, 42)

      {:ok, _tseq, unwrapped} = Envelope.unwrap(wrapped)

      refute Map.has_key?(unwrapped, "acpenv")
      refute Map.has_key?(unwrapped, "s")
      assert unwrapped == frame
    end

    test "a plain, un-enveloped frame is rejected" do
      assert Envelope.unwrap(%{"jsonrpc" => "2.0", "method" => "initialize"}) ==
               {:error, :not_enveloped}
    end

    test "an unknown envelope version is rejected" do
      assert Envelope.unwrap(%{"acpenv" => 2, "s" => 1, "f" => %{}}) ==
               {:error, :not_enveloped}
    end

    test "a non-positive or non-integer sequence is rejected" do
      assert Envelope.unwrap(%{"acpenv" => 1, "s" => 0, "f" => %{}}) == {:error, :not_enveloped}
      assert Envelope.unwrap(%{"acpenv" => 1, "s" => -1, "f" => %{}}) == {:error, :not_enveloped}
      assert Envelope.unwrap(%{"acpenv" => 1, "s" => "1", "f" => %{}}) == {:error, :not_enveloped}
    end

    test "a non-map frame field is rejected" do
      assert Envelope.unwrap(%{"acpenv" => 1, "s" => 1, "f" => "not a map"}) ==
               {:error, :not_enveloped}
    end

    test "an arbitrary non-map value is rejected" do
      assert Envelope.unwrap("just a string") == {:error, :not_enveloped}
      assert Envelope.unwrap(42) == {:error, :not_enveloped}
    end
  end

  describe "F8b Reassembly: in-order release under scrambled push order" do
    test "in-order arrival releases each frame immediately, one at a time" do
      buf = Reassembly.new()

      {:ok, [f1], buf} = Reassembly.push(buf, 1, %{"n" => 1})
      {:ok, [f2], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, [f3], _buf} = Reassembly.push(buf, 3, %{"n" => 3})

      assert [f1, f2, f3] == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
    end

    test "a single out-of-order frame is buffered, then released on cascade" do
      buf = Reassembly.new()

      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, released, _buf} = Reassembly.push(buf, 1, %{"n" => 1})

      assert released == [%{"n" => 1}, %{"n" => 2}]
    end

    test "a full reverse-order arrival cascades in one final push" do
      buf = Reassembly.new()

      {:ok, [], buf} = Reassembly.push(buf, 5, %{"n" => 5})
      {:ok, [], buf} = Reassembly.push(buf, 4, %{"n" => 4})
      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, released, _buf} = Reassembly.push(buf, 1, %{"n" => 1})

      assert released == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}, %{"n" => 4}, %{"n" => 5}]
    end

    test "duplicate of an already-released tseq is dropped silently" do
      buf = Reassembly.new()

      {:ok, [_f1], buf} = Reassembly.push(buf, 1, %{"n" => 1})
      {:ok, released, buf} = Reassembly.push(buf, 1, %{"n" => 1})
      assert released == []

      # buffer keeps working normally afterwards
      {:ok, [f2], _buf} = Reassembly.push(buf, 2, %{"n" => 2})
      assert f2 == %{"n" => 2}
    end

    test "duplicate of an already-buffered (not yet released) tseq is dropped silently" do
      buf = Reassembly.new()

      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2, "copy" => :first})
      {:ok, released, buf} = Reassembly.push(buf, 2, %{"n" => 2, "copy" => :second})
      assert released == []

      # the first copy is the one that is eventually released
      {:ok, [_f1, f2], _buf} = Reassembly.push(buf, 1, %{"n" => 1})
      assert f2 == %{"n" => 2, "copy" => :first}
    end

    property "for any permutation of a contiguous tseq run, the concatenation of every push's released frames reproduces the original order, with no loss and no duplication" do
      check all(
              n <- integer(1..40),
              seed <- integer(0..1_000_000)
            ) do
        frames = for i <- 1..n, do: %{"n" => i}
        order = deterministic_shuffle(1..n, seed)

        {released, final_buf} =
          Enum.reduce(order, {[], Reassembly.new()}, fn tseq, {acc, buf} ->
            frame = Enum.at(frames, tseq - 1)
            {:ok, new_released, buf} = Reassembly.push(buf, tseq, frame)
            {acc ++ new_released, buf}
          end)

        assert released == frames
        assert final_buf.buffer == %{}
        assert final_buf.buffered_bytes == 0
        assert final_buf.next_expected == n + 1
      end
    end

    test "duplicates interleaved with a scrambled arrival still reproduce the original order exactly once" do
      buf = Reassembly.new()

      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, released1, buf} = Reassembly.push(buf, 1, %{"n" => 1})
      {:ok, released2, _buf} = Reassembly.push(buf, 1, %{"n" => 1})

      assert released1 == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
      assert released2 == []
    end
  end

  describe "F8b Reassembly: overflow-bounded (never timer-bounded)" do
    test "crossing the frame-count watermark closes with reassembly_overflow" do
      buf = Reassembly.new(max_buffered_frames: 3)

      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      {:ok, [], buf} = Reassembly.push(buf, 4, %{"n" => 4})

      assert Reassembly.push(buf, 5, %{"n" => 5}) ==
               {:closed, {:transport, :reassembly_overflow}}
    end

    test "staying at or under the frame-count watermark never overflows" do
      buf = Reassembly.new(max_buffered_frames: 3)

      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      {:ok, [], buf} = Reassembly.push(buf, 4, %{"n" => 4})

      # releasing frees buffer slots; a subsequent buffered frame at the
      # same watermark is fine because the count never exceeds max.
      {:ok, released, buf} = Reassembly.push(buf, 1, %{"n" => 1})
      assert released == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}, %{"n" => 4}]
      assert buf.buffer == %{}
    end

    test "crossing the byte watermark closes with reassembly_overflow" do
      # each frame's approximate external size is well under 200 bytes;
      # a tiny byte cap forces overflow on the very first buffered frame.
      buf = Reassembly.new(max_buffered_bytes: 10)

      assert Reassembly.push(buf, 2, %{"payload" => String.duplicate("x", 100)}) ==
               {:closed, {:transport, :reassembly_overflow}}
    end

    test "the buffer never grows past the watermark (bounded, not merely detected late)" do
      buf = Reassembly.new(max_buffered_frames: 2)

      {:ok, [], buf} = Reassembly.push(buf, 2, %{"n" => 2})
      {:ok, [], buf} = Reassembly.push(buf, 3, %{"n" => 3})
      assert map_size(buf.buffer) == 2

      assert Reassembly.push(buf, 4, %{"n" => 4}) ==
               {:closed, {:transport, :reassembly_overflow}}
    end

    test "new/1 rejects non-positive options" do
      assert_raise ArgumentError, fn -> Reassembly.new(max_buffered_frames: 0) end
      assert_raise ArgumentError, fn -> Reassembly.new(max_buffered_bytes: -1) end
      assert_raise ArgumentError, fn -> Reassembly.new(start: 0) end
    end

    test "new/1 honors a non-default :start" do
      buf = Reassembly.new(start: 100)

      {:ok, [], buf} = Reassembly.push(buf, 101, %{"n" => 101})
      {:ok, released, _buf} = Reassembly.push(buf, 100, %{"n" => 100})

      assert released == [%{"n" => 100}, %{"n" => 101}]
    end
  end

  # -- Helpers --------------------------------------------------------------

  defp frame_generator do
    gen all(
          method <- member_of(["session/update", "initialize", "session/prompt"]),
          id <- one_of([integer(), string(:alphanumeric, max_length: 8)]),
          extra <-
            map_of(string(:alphanumeric, min_length: 1, max_length: 6), integer(), max_length: 4)
        ) do
      Map.merge(%{"jsonrpc" => "2.0", "method" => method, "id" => id}, extra)
    end
  end

  # Deterministic per-seed Fisher-Yates shuffle so a property failure is
  # reproducible from the printed `n`/`seed` pair alone. Threads its own
  # `:rand` state explicitly (`seed_s`/`uniform_s`) rather than touching
  # the process's global random state, so it never perturbs StreamData's
  # own generation of subsequent `n`/`seed` values within the same run.
  defp deterministic_shuffle(enumerable, seed) do
    state = :rand.seed_s(:exsss, {seed, seed, seed})
    {shuffled, _state} = shuffle_with(Enum.to_list(enumerable), [], state)
    shuffled
  end

  defp shuffle_with([], acc, state), do: {acc, state}

  defp shuffle_with(list, acc, state) do
    {index, state} = :rand.uniform_s(length(list), state)
    {elem, rest} = List.pop_at(list, index - 1)
    shuffle_with(rest, [elem | acc], state)
  end
end
