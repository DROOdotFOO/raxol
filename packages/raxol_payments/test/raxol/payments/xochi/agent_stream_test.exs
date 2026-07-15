defmodule Raxol.Payments.Xochi.AgentStreamTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.AgentStream

  # Anvil/foundry default account #1 -- a well-known key, not a secret, safe to
  # hard-code. Its address is the parity target the Xochi client verifies against.
  @agent_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @agent_address "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"

  @topic_id "verifytopicabcdef1234"

  defmodule AgentWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_AGENT_STREAM_TEST_KEY"
  end

  setup do
    System.put_env("RAXOL_AGENT_STREAM_TEST_KEY", @agent_key)
    :ok
  end

  defp event(overrides \\ %{}) do
    %{
      intent_id: "intent-abc",
      from_chain_id: 8453,
      to_chain_id: 42161,
      from_token: "0xUSDC",
      to_token: "0xUSDC",
      from_amount: "100000000",
      to_amount: "99780000",
      status: "completed",
      ts: 1_700_000_000_000
    }
    |> Map.merge(overrides)
  end

  describe "digest_message/2 (parity with agentActivityDigest)" do
    test "byte-matches the Xochi shared contract fixture" do
      expected =
        "verifytopicabcdef1234\n" <>
          ~s(["intent-abc",8453,42161,"0xUSDC","0xUSDC","100000000","99780000","completed",1700000000000])

      assert AgentStream.digest_message(@topic_id, event()) == expected
    end

    test "binds the event to its topic" do
      a = AgentStream.digest_message("topicA0000000000000", event())
      b = AgentStream.digest_message("topicB0000000000000", event())
      refute a == b
      assert String.starts_with?(a, "topicA0000000000000\n")
    end
  end

  describe "canonical_event/1 (parity with canonicalizeEvent)" do
    test "renders a fixed-order array with no whitespace" do
      assert AgentStream.canonical_event(event()) ==
               ~s(["intent-abc",8453,42161,"0xUSDC","0xUSDC","100000000","99780000","completed",1700000000000])
    end

    test "renders a nil to_amount as null" do
      assert AgentStream.canonical_event(event(%{to_amount: nil})) ==
               ~s(["intent-abc",8453,42161,"0xUSDC","0xUSDC","100000000",null,"completed",1700000000000])
    end

    test "changes when any field changes" do
      refute AgentStream.canonical_event(event()) ==
               AgentStream.canonical_event(event(%{from_amount: "200000000"}))
    end
  end

  describe "sign_event/3 + recover_signer/3 (parity with viem verifyMessage)" do
    test "signature recovers to the agent's address" do
      {:ok, sig} = AgentStream.sign_event(AgentWallet, @topic_id, event())

      assert "0x" <> hex = sig
      # 65-byte signature -> 130 hex chars.
      assert byte_size(hex) == 130

      {:ok, recovered} = AgentStream.recover_signer(@topic_id, event(), sig)
      assert String.downcase(recovered) == String.downcase(@agent_address)
    end

    test "verify/4 accepts a signature from the expected wallet" do
      {:ok, sig} = AgentStream.sign_event(AgentWallet, @topic_id, event())
      assert :ok == AgentStream.verify(@topic_id, event(), sig, @agent_address)
    end

    test "verify/4 rejects a signature bound to a different topic" do
      {:ok, sig} = AgentStream.sign_event(AgentWallet, "othertopicabcdef1234", event())

      assert {:error, :signer_mismatch} ==
               AgentStream.verify(@topic_id, event(), sig, @agent_address)
    end

    test "the test wallet derives the expected agent address" do
      assert String.downcase(AgentWallet.address()) == String.downcase(@agent_address)
    end
  end

  describe "build_body/2" do
    test "emits camelCase, the agent wallet, and the signature -- no human wallet or topic in the event" do
      config = %{topic_id: @topic_id, wallet: AgentWallet}
      {:ok, body} = AgentStream.build_body(config, event())

      assert body["topicId"] == @topic_id
      assert String.downcase(body["agentWallet"]) == String.downcase(@agent_address)
      assert "0x" <> _ = body["agentSig"]

      assert body["event"] == %{
               "intentId" => "intent-abc",
               "fromChainId" => 8453,
               "toChainId" => 42161,
               "fromToken" => "0xUSDC",
               "toToken" => "0xUSDC",
               "fromAmount" => "100000000",
               "toAmount" => "99780000",
               "status" => "completed",
               "ts" => 1_700_000_000_000
             }

      # The event object must never carry the topic (the worker must not learn it).
      refute Map.has_key?(body["event"], "topicId")
    end

    test "honors an explicit agent_wallet override" do
      override = "0x1111111111111111111111111111111111111111"
      config = %{topic_id: @topic_id, wallet: AgentWallet, agent_wallet: override}
      {:ok, body} = AgentStream.build_body(config, event())
      assert body["agentWallet"] == override
    end

    test "the body round-trips through JSON compactly" do
      config = %{topic_id: @topic_id, wallet: AgentWallet}
      {:ok, body} = AgentStream.build_body(config, event())
      assert {:ok, ^body} = Jason.decode(Jason.encode!(body))
    end
  end

  describe "announce_sync/2 base_url guard" do
    test "refuses a plaintext non-local http base_url" do
      config = %{
        xochi_api_url: "http://evil.example",
        topic_id: @topic_id,
        wallet: AgentWallet
      }

      assert_raise ArgumentError, fn -> AgentStream.announce_sync(config, event()) end
    end
  end
end
