defmodule Raxol.Payments.Xochi.SwapAnnouncerTest do
  # async: false -- SwapRouteStore is a named singleton shared across tests.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Xochi.{AgentStream, SwapAnnouncer, SwapRouteStore}
  alias Raxol.Payments.Xochi.Schemas.{IntentStatus, QuoteRequest, QuoteResponse}

  # Anvil/foundry default account #1 -- a well-known key, not a secret.
  @agent_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @agent_address "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"
  @topic "verifytopicabcdef1234"
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defmodule AgentWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_SWAP_ANNOUNCER_TEST_KEY"
  end

  setup do
    System.put_env("RAXOL_SWAP_ANNOUNCER_TEST_KEY", @agent_key)
    :ok
  end

  # A Req plug that captures the announce body to the test process and 202s, like
  # the live Xochi worker.
  defp capture_plug(test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:announce, conn.request_path, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{success: true})
    end
  end

  defp stream_config(overrides \\ %{}) do
    Map.merge(
      %{
        topic_id: @topic,
        xochi_api_url: "https://xochi.test",
        jitter_ms: 0,
        req_options: [plug: capture_plug(self())]
      },
      overrides
    )
  end

  defp context(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: AgentWallet,
        xochi_config: %{base_url: "https://xochi.test"},
        agent_stream: stream_config()
      },
      overrides
    )
  end

  defp request do
    %QuoteRequest{
      wallet: AgentWallet.address(),
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc,
      to_token: @usdc,
      from_amount: "500000",
      settlement_preference: "public"
    }
  end

  defp quote_resp do
    %QuoteResponse{
      intent_id: "int_1",
      quote_id: "q_1",
      can_solve: true,
      to_amount: "499000"
    }
  end

  defp exec(overrides \\ %{}) do
    Map.merge(
      %{intent_id: "int_1", status: :executing, reconciling: false},
      overrides
    )
  end

  describe "config/1" do
    test "resolves url, topic, and wallet from context" do
      assert {:ok, cfg} = SwapAnnouncer.config(context())
      assert cfg.topic_id == @topic
      assert cfg.xochi_api_url == "https://xochi.test"
      assert cfg.wallet == AgentWallet
    end

    test "defaults the announce url to the swap's xochi_config base_url" do
      ctx = context(%{agent_stream: stream_config(%{xochi_api_url: nil})})
      assert {:ok, cfg} = SwapAnnouncer.config(ctx)
      assert cfg.xochi_api_url == "https://xochi.test"
    end

    test "carries mandate_hash when present, omits it otherwise" do
      with_hash =
        context(%{agent_stream: stream_config(%{mandate_hash: "0xdead"})})

      assert {:ok, %{mandate_hash: "0xdead"}} = SwapAnnouncer.config(with_hash)

      refute Map.has_key?(
               elem(SwapAnnouncer.config(context()), 1),
               :mandate_hash
             )
    end

    test "skips when no agent_stream configured" do
      assert :skip == SwapAnnouncer.config(%{wallet: AgentWallet})
    end

    test "skips when topic_id is missing or blank" do
      assert :skip ==
               SwapAnnouncer.config(context(%{agent_stream: %{xochi_api_url: "https://x"}}))

      assert :skip ==
               SwapAnnouncer.config(context(%{agent_stream: stream_config(%{topic_id: ""})}))
    end
  end

  describe "announce_execute/4" do
    test "posts a signed, verifiable execute event and stashes the route" do
      assert :ok ==
               SwapAnnouncer.announce_execute(
                 context(),
                 request(),
                 quote_resp(),
                 exec()
               )

      assert_receive {:announce, "/api/agent/announce", body}, 1000
      assert body["topicId"] == @topic

      assert String.downcase(body["agentWallet"]) ==
               String.downcase(@agent_address)

      assert body["event"]["intentId"] == "int_1"
      assert body["event"]["fromChainId"] == 8453
      assert body["event"]["toChainId"] == 42_161
      assert body["event"]["fromAmount"] == "500000"
      assert body["event"]["toAmount"] == "499000"
      assert body["event"]["status"] == "executing"

      # The signature verifies against the agent wallet -- exactly the client's
      # viem verifyMessage check.
      {:ok, recovered} =
        AgentStream.recover_signer(@topic, event_of(body), body["agentSig"])

      assert String.downcase(recovered) == String.downcase(@agent_address)

      # Route stashed for the terminal announce.
      assert {:ok, stashed} = SwapRouteStore.take("int_1")
      assert stashed.from_chain_id == 8453
    end

    test "marks an in-doubt (reconciling) execute as non-terminal" do
      assert :ok ==
               SwapAnnouncer.announce_execute(
                 context(),
                 request(),
                 quote_resp(),
                 exec(%{reconciling: true})
               )

      assert_receive {:announce, _path, body}, 1000
      assert body["event"]["status"] == "executing"
    end

    test "is a silent no-op when no topic_id is configured" do
      ctx = %{
        wallet: AgentWallet,
        xochi_config: %{base_url: "https://xochi.test"}
      }

      assert :ok ==
               SwapAnnouncer.announce_execute(
                 ctx,
                 request(),
                 quote_resp(),
                 exec()
               )

      refute_receive {:announce, _, _}, 200
    end
  end

  describe "announce_terminal/3" do
    test "rebuilds the full event from the stashed route with the terminal status" do
      # Execute first so the route is stashed.
      SwapAnnouncer.announce_execute(context(), request(), quote_resp(), exec())
      assert_receive {:announce, _path, _execute_body}, 1000

      status = %IntentStatus{
        intent_id: "int_1",
        status: :completed,
        tx_hash: "0xabc"
      }

      assert :ok == SwapAnnouncer.announce_terminal(context(), "int_1", status)

      assert_receive {:announce, "/api/agent/announce", body}, 1000
      assert body["event"]["intentId"] == "int_1"
      assert body["event"]["fromChainId"] == 8453
      assert body["event"]["toToken"] == @usdc
      assert body["event"]["toAmount"] == "499000"
      assert body["event"]["status"] == "completed"

      {:ok, recovered} =
        AgentStream.recover_signer(@topic, event_of(body), body["agentSig"])

      assert String.downcase(recovered) == String.downcase(@agent_address)
    end

    test "skips when no route was stashed for the intent" do
      status = %IntentStatus{intent_id: "never_executed", status: :failed}

      assert :ok ==
               SwapAnnouncer.announce_terminal(
                 context(),
                 "never_executed",
                 status
               )

      refute_receive {:announce, _, _}, 200
    end

    test "take/1 consumes the route so it is not re-emitted" do
      SwapAnnouncer.announce_execute(context(), request(), quote_resp(), exec())
      assert {:ok, _} = SwapRouteStore.take("int_1")
      assert :error == SwapRouteStore.take("int_1")
    end
  end

  # Rebuild the snake_case event AgentStream signs from the camelCase wire body,
  # so the test can recover the signer the same way the client does.
  defp event_of(%{"event" => e}) do
    %{
      intent_id: e["intentId"],
      from_chain_id: e["fromChainId"],
      to_chain_id: e["toChainId"],
      from_token: e["fromToken"],
      to_token: e["toToken"],
      from_amount: e["fromAmount"],
      to_amount: e["toAmount"],
      status: e["status"],
      ts: e["ts"]
    }
  end
end
