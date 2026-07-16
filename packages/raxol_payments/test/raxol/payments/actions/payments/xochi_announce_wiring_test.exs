defmodule Raxol.Payments.Actions.Payments.XochiAnnounceWiringTest do
  # async: false -- drives the named SwapRouteStore singleton and a real wallet.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
  alias Raxol.Payments.{Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.AgentStream

  # Anvil/foundry default account #1 -- a well-known key, not a secret. A real
  # signing wallet (not a stub) so the announce signature actually verifies.
  @agent_key "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
  @agent_address "0x70997970c51812dc3a010c7d01b50e0d17dc79c8"
  @topic "verifytopicabcdef1234"
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defmodule AgentWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ANNOUNCE_WIRING_KEY"
  end

  setup do
    System.put_env("RAXOL_ANNOUNCE_WIRING_KEY", @agent_key)
    :ok
  end

  # Xochi worker sim: quote -> execute -> completed status. The announce POST is
  # captured on a separate plug so the swap and the announce stay decoupled.
  @completed_status %{
    "intentId" => "int_1",
    "status" => "completed",
    "txHash" => "0xabc",
    "terminal" => true
  }

  # A status that never reaches terminal, so the poll times out (stranded).
  @nonterminal_status %{"intentId" => "int_1", "status" => "executing", "terminal" => false}

  defp xochi_plug(status_body \\ @completed_status) do
    fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            "toAmount" => "499000",
            "xochiFee" => "1000",
            "eip712Data" => %{
              "domain" => %{
                "name" => "Xochi",
                "version" => "1",
                "chainId" => 8453
              },
              "types" => %{
                "Intent" => [%{"name" => "amount", "type" => "uint256"}]
              },
              "message" => %{"amount" => 500_000}
            }
          })

        "/api/intent/execute" ->
          Req.Test.json(conn, %{
            "success" => true,
            "intentId" => "int_1",
            "status" => "executing"
          })

        "/api/intent/int_1/status" ->
          Req.Test.json(conn, status_body)
      end
    end
  end

  defp announce_plug(test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:announce, Jason.decode!(raw)})
      conn |> Plug.Conn.put_status(202) |> Req.Test.json(%{success: true})
    end
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("10.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["xochi.test"]
    }
  end

  defp context(overrides) do
    Map.merge(
      %{
        wallet: AgentWallet,
        xochi_config: %{
          base_url: "https://xochi.test",
          req_options: [plug: xochi_plug()]
        },
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      },
      overrides
    )
  end

  defp with_stream(context) do
    Map.put(context, :agent_stream, %{
      topic_id: @topic,
      xochi_api_url: "https://xochi.test",
      jitter_ms: 0,
      req_options: [plug: announce_plug(self())]
    })
  end

  defp params do
    %{
      amount: "0.50",
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc,
      to_token: @usdc,
      settlement: "public",
      recipient_address: "0x" <> String.duplicate("cc", 20)
    }
  end

  defp assert_announce_verifies(status) do
    assert_receive {:announce, body}, 1000
    assert body["topicId"] == @topic
    assert String.downcase(body["agentWallet"]) == @agent_address
    assert body["event"]["status"] == status
    assert body["event"]["fromChainId"] == 8453
    assert body["event"]["toChainId"] == 42_161
    assert body["event"]["fromAmount"] == "500000"

    {:ok, recovered} =
      AgentStream.recover_signer(@topic, event_of(body), body["agentSig"])

    assert String.downcase(recovered) == @agent_address
    body
  end

  describe "with a configured topic_id" do
    test "ExecuteXochiIntent fires a verifiable execute announce" do
      ctx = with_stream(context(%{}))

      assert {:ok, %{intent_id: "int_1"}} =
               ExecuteXochiIntent.run(params(), ctx)

      assert_announce_verifies("executing")
    end

    test "PollXochiStatus fires a verifiable terminal announce after execute" do
      ctx = with_stream(context(%{}))

      assert {:ok, _} = ExecuteXochiIntent.run(params(), ctx)
      assert_announce_verifies("executing")

      assert {:ok, %{status: "completed"}} =
               PollXochiStatus.run(%{intent_id: "int_1", timeout_ms: 2000}, ctx)

      body = assert_announce_verifies("completed")
      assert body["event"]["intentId"] == "int_1"
    end

    test "PollXochiStatus fires a stranded announce when the poll times out" do
      ctx =
        with_stream(
          context(%{
            xochi_config: %{
              base_url: "https://xochi.test",
              req_options: [plug: xochi_plug(@nonterminal_status)]
            }
          })
        )

      assert {:ok, _} = ExecuteXochiIntent.run(params(), ctx)
      assert_announce_verifies("executing")

      assert {:error, %{reason: :stranded}} =
               PollXochiStatus.run(%{intent_id: "int_1", timeout_ms: 40, interval_ms: 10}, ctx)

      body = assert_announce_verifies("stranded")
      assert body["event"]["intentId"] == "int_1"
    end
  end

  describe "without a configured topic_id" do
    test "the swap runs and emits nothing" do
      ctx = context(%{})

      assert {:ok, %{intent_id: "int_1"}} =
               ExecuteXochiIntent.run(params(), ctx)

      assert {:ok, %{status: "completed"}} =
               PollXochiStatus.run(%{intent_id: "int_1", timeout_ms: 2000}, ctx)

      refute_receive {:announce, _}, 200
    end
  end

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
