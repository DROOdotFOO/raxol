defmodule Raxol.Earn.Onchain.LogDecoderTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Onchain.LogDecoder

  test "event_topic is the full keccak of the canonical signature" do
    assert LogDecoder.event_topic("Transfer(address,address,uint256)") ==
             "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  end

  test "decode_uint256 reads a right-aligned 32-byte topic" do
    assert LogDecoder.decode_uint256("0x" <> String.duplicate("0", 62) <> "2a") == {:ok, 42}
  end

  test "decode_uint256 rejects a non-32-byte value" do
    assert {:error, {:bad_uint256, _}} = LogDecoder.decode_uint256("0x2a")
  end

  test "find_event matches topics[0] by signature or precomputed hash" do
    topic = LogDecoder.event_topic("JobCreated(uint256)")
    log = %{"topics" => [topic, "0x" <> String.duplicate("0", 62) <> "07"]}

    assert {:ok, ^log} = LogDecoder.find_event([log], "JobCreated(uint256)")
    assert {:ok, ^log} = LogDecoder.find_event([log], topic)
    assert :error = LogDecoder.find_event([log], "Nope(uint256)")
  end

  test "extract pulls the indexed uint256 jobId out of a JobCreated log" do
    topic = LogDecoder.event_topic("JobCreated(uint256)")
    log = %{"topics" => [topic, "0x" <> String.duplicate("0", 62) <> "63"]}

    assert {:ok, 99} = LogDecoder.extract([log], "JobCreated(uint256)", 1, :uint256)
  end

  test "extract errors when the event is absent" do
    assert {:error, {:event_not_found, _}} =
             LogDecoder.extract([], "JobCreated(uint256)", 1, :uint256)
  end
end
