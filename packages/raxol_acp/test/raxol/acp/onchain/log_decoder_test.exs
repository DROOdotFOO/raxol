defmodule Raxol.ACP.Onchain.LogDecoderTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Onchain.LogDecoder

  # Canonical ERC-20 Transfer event hash, well-known on Etherscan etc.
  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  describe "event_topic/1" do
    test "matches the canonical Transfer event hash" do
      assert LogDecoder.event_topic("Transfer(address,address,uint256)") == @transfer_topic
    end

    test "is deterministic and case-sensitive" do
      a = LogDecoder.event_topic("JobCreated(uint256)")
      b = LogDecoder.event_topic("JobCreated(uint256)")
      c = LogDecoder.event_topic("jobcreated(uint256)")

      assert a == b
      refute a == c
    end

    test "starts with 0x and is exactly 66 chars (0x + 64 hex)" do
      hash = LogDecoder.event_topic("Foo()")
      assert byte_size(hash) == 66
      assert String.starts_with?(hash, "0x")
    end
  end

  describe "decode_uint256/1" do
    test "decodes a left-padded uint256 topic" do
      assert {:ok, 42} =
               LogDecoder.decode_uint256("0x" <> String.duplicate("0", 62) <> "2a")
    end

    test "decodes a max-ish uint" do
      hex = "0x" <> String.duplicate("ff", 32)
      {:ok, n} = LogDecoder.decode_uint256(hex)
      assert n == 2 ** 256 - 1
    end

    test "errors on the wrong length" do
      assert {:error, {:bad_uint256, _}} = LogDecoder.decode_uint256("0xff")
    end

    test "errors on missing 0x prefix" do
      assert {:error, {:bad_uint256, _}} = LogDecoder.decode_uint256(String.duplicate("0", 64))
    end
  end

  describe "decode_address/1" do
    test "extracts the 20-byte address from a left-padded topic" do
      addr = "ab" |> String.duplicate(20)
      topic = "0x" <> String.duplicate("0", 24) <> addr

      assert {:ok, "0x" <> ^addr} = LogDecoder.decode_address(topic)
    end

    test "errors when the leading 12 bytes are non-zero" do
      topic = "0x" <> "ff" <> String.duplicate("0", 22) <> String.duplicate("ab", 20)

      assert {:error, {:bad_address_padding, _}} = LogDecoder.decode_address(topic)
    end

    test "errors on bad hex" do
      assert {:error, {:bad_address_hex, _}} =
               LogDecoder.decode_address("0x" <> String.duplicate("z", 64))
    end
  end

  describe "decode_bytes32/1" do
    test "decodes to a raw 32-byte binary" do
      hex = "0x" <> String.duplicate("ab", 32)
      {:ok, bytes} = LogDecoder.decode_bytes32(hex)

      assert byte_size(bytes) == 32
      assert bytes == String.duplicate(<<0xAB>>, 32)
    end
  end

  describe "find_event/2" do
    setup do
      logs = [
        %{
          "address" => "0x" <> String.duplicate("aa", 20),
          "topics" => [
            "0xdeadbeef" <> String.duplicate("0", 56),
            "0x" <> String.duplicate("0", 64)
          ],
          "data" => "0x"
        },
        %{
          "address" => "0x" <> String.duplicate("bb", 20),
          "topics" => [
            @transfer_topic,
            "0x" <> String.duplicate("0", 24) <> String.duplicate("11", 20),
            "0x" <> String.duplicate("0", 24) <> String.duplicate("22", 20)
          ],
          "data" => "0x" <> String.duplicate("0", 62) <> "0a"
        }
      ]

      %{logs: logs}
    end

    test "finds a log by precomputed topic", %{logs: logs} do
      assert {:ok, %{"address" => "0x" <> _}} = LogDecoder.find_event(logs, @transfer_topic)
    end

    test "finds a log by canonical signature (auto-hashes)", %{logs: logs} do
      assert {:ok, _} = LogDecoder.find_event(logs, "Transfer(address,address,uint256)")
    end

    test ":error when no log matches", %{logs: logs} do
      assert :error = LogDecoder.find_event(logs, "Nope(uint256)")
    end

    test ":error on an empty log list" do
      assert :error = LogDecoder.find_event([], @transfer_topic)
    end

    test "topic match is case-insensitive on the hex chars" do
      logs = [%{"topics" => [String.upcase(@transfer_topic), "0x"]}]

      assert {:ok, _} = LogDecoder.find_event(logs, @transfer_topic)
    end
  end

  describe "extract/4" do
    test "pulls a uint256 from the right indexed slot" do
      log = %{
        "topics" => [
          LogDecoder.event_topic("JobCreated(uint256)"),
          "0x" <> String.duplicate("0", 62) <> "2a"
        ]
      }

      assert {:ok, 42} =
               LogDecoder.extract(
                 [log],
                 "JobCreated(uint256)",
                 1,
                 :uint256
               )
    end

    test "pulls an address from the second indexed slot" do
      addr = String.duplicate("ab", 20)

      log = %{
        "topics" => [
          LogDecoder.event_topic("JobOffered(uint256,address)"),
          "0x" <> String.duplicate("0", 62) <> "01",
          "0x" <> String.duplicate("0", 24) <> addr
        ]
      }

      assert {:ok, "0x" <> ^addr} =
               LogDecoder.extract(
                 [log],
                 "JobOffered(uint256,address)",
                 2,
                 :address
               )
    end

    test ":event_not_found error when nothing matches" do
      logs = [%{"topics" => ["0x" <> String.duplicate("0", 64)]}]

      assert {:error, {:event_not_found, _}} =
               LogDecoder.extract(logs, "Nope()", 1, :uint256)
    end

    test ":topic_out_of_range when the requested slot is missing" do
      log = %{"topics" => [LogDecoder.event_topic("Foo()")]}

      assert {:error, {:topic_out_of_range, 1}} =
               LogDecoder.extract([log], "Foo()", 1, :uint256)
    end
  end
end
