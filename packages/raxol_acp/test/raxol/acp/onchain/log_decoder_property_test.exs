defmodule Raxol.ACP.Onchain.LogDecoderPropertyTest do
  @moduledoc """
  Properties for the non-indexed `data` decoding that resolves a job id
  from a `JobCreated` event.

  The bug this locks: the id is a NON-indexed event parameter (in `data`),
  so it must be read as a `data` word, not a topic. An off-by-one in the
  word offset, a padding slip, or reading the wrong slot silently yields a
  wrong job id -- which then mis-targets every downstream on-chain call.
  A roundtrip over arbitrary uint256 words at arbitrary indices pins the
  decoder from an angle no single example covers.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.ACP.Onchain.LogDecoder

  @sig "JobCreated(uint256,address,address,address)"

  # Any uint256, weighted to also hit the large values where padding /
  # slot bugs hide.
  defp uint256 do
    one_of([
      integer(0..1_000),
      integer(0..(2 ** 256 - 1))
    ])
  end

  # ABI-encode a list of uint256 words into a `data` hex blob: each word is
  # 32 bytes (64 hex chars), big-endian, zero-padded on the left.
  defp encode_words(words) do
    hex =
      Enum.map_join(words, "", fn n ->
        n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")
      end)

    "0x" <> hex
  end

  defp log(data) do
    %{
      "topics" => [LogDecoder.event_topic(@sig)],
      "data" => data
    }
  end

  property "extract_data + decode_uint256 round-trips any uint256 at any word index" do
    check all(words <- list_of(uint256(), min_length: 1, max_length: 6)) do
      log = log(encode_words(words))

      # Every word decodes back to exactly its value, independent of its
      # neighbors: word i is not perturbed by words j != i.
      for {n, i} <- Enum.with_index(words) do
        assert {:ok, ^n} = LogDecoder.extract_data([log], @sig, i, :uint256)
      end
    end
  end

  property "reading past the encoded words fails cleanly (no wrong value, no raise)" do
    check all(words <- list_of(uint256(), min_length: 1, max_length: 4)) do
      log = log(encode_words(words))
      past = length(words)

      assert {:error, {:data_word_out_of_range, ^past}} =
               LogDecoder.extract_data([log], @sig, past, :uint256)
    end
  end
end
