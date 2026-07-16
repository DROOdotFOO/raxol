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

  defp request(preference \\ "public") do
    %QuoteRequest{
      wallet: AgentWallet.address(),
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc,
      to_token: @usdc,
      from_amount: "500000",
      settlement_preference: preference
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

    test "skips a topic_id that fails the Xochi format" do
      # too short (< 16 chars), and illegal characters, are both rejected.
      assert :skip ==
               SwapAnnouncer.config(context(%{agent_stream: stream_config(%{topic_id: "short"})}))

      assert :skip ==
               SwapAnnouncer.config(
                 context(%{agent_stream: stream_config(%{topic_id: "has spaces and bangs!!"})})
               )
    end

    test "skips an announce host that is neither the swap host nor allowlisted" do
      ctx =
        context(%{agent_stream: stream_config(%{xochi_api_url: "https://evil.example"})})

      assert :skip == SwapAnnouncer.config(ctx)
    end

    test "honors an announce host on the configured allowlist" do
      Application.put_env(:raxol_payments, :agent_stream_hosts, ["relay.xochi.example"])
      on_exit(fn -> Application.delete_env(:raxol_payments, :agent_stream_hosts) end)

      ctx =
        context(%{agent_stream: stream_config(%{xochi_api_url: "https://relay.xochi.example"})})

      assert {:ok, %{xochi_api_url: "https://relay.xochi.example"}} =
               SwapAnnouncer.config(ctx)
    end
  end

  describe "diagnostics: announce_skipped telemetry" do
    setup do
      ref = make_ref()
      test_pid = self()

      handler = fn _event, _measure, meta, _cfg ->
        send(test_pid, {:skipped, ref, meta.reason})
      end

      :telemetry.attach(
        "skip-#{inspect(ref)}",
        [:raxol, :payments, :xochi, :agent_stream, :announce_skipped],
        handler,
        nil
      )

      on_exit(fn -> :telemetry.detach("skip-#{inspect(ref)}") end)
      %{ref: ref}
    end

    test "emits :not_configured when no agent_stream is set", %{ref: ref} do
      SwapAnnouncer.config(%{wallet: AgentWallet})
      assert_receive {:skipped, ^ref, :not_configured}
    end

    test "emits :no_topic_id when the topic is blank", %{ref: ref} do
      SwapAnnouncer.config(context(%{agent_stream: stream_config(%{topic_id: ""})}))
      assert_receive {:skipped, ^ref, :no_topic_id}
    end

    test "emits :no_wallet when the wallet is absent", %{ref: ref} do
      SwapAnnouncer.config(%{agent_stream: stream_config()})
      assert_receive {:skipped, ^ref, :no_wallet}
    end

    test "emits :no_route when the terminal poll finds no stashed route", %{ref: ref} do
      status = %IntentStatus{intent_id: "never_stashed", status: :completed}
      assert :ok == SwapAnnouncer.announce_terminal(context(), "never_stashed", status)
      assert_receive {:skipped, ^ref, :no_route}
    end

    test "does not emit when config resolves cleanly", %{ref: ref} do
      assert {:ok, _} = SwapAnnouncer.config(context())
      refute_receive {:skipped, ^ref, _}, 100
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

  describe "privacy: only public settlements disclose the route" do
    defp expected_pseudo(intent_id) do
      :crypto.hash(:sha256, [@topic, "\n", intent_id])
      |> binary_part(0, 16)
      |> Base.encode16(case: :lower)
    end

    defp assert_redacted(body) do
      e = body["event"]
      assert e["fromChainId"] == 0
      assert e["toChainId"] == 0
      assert e["fromToken"] == "redacted"
      assert e["toToken"] == "redacted"
      assert e["fromAmount"] == "0"
      assert is_nil(e["toAmount"])
      # No real amounts/tokens/chains leaked, and the intent id is a pseudonym.
      refute e["intentId"] == "int_1"
      refute e["fromAmount"] == "500000"
    end

    test "a stealth execute announces a redacted row, not the route" do
      assert :ok ==
               SwapAnnouncer.announce_execute(
                 context(),
                 request("stealth"),
                 quote_resp(),
                 exec()
               )

      assert_receive {:announce, "/api/agent/announce", body}, 1000
      assert_redacted(body)
      assert body["event"]["status"] == "executing"
      assert body["event"]["intentId"] == expected_pseudo("int_1")

      # The redacted row is still a valid, verifiable signed announce.
      {:ok, recovered} =
        AgentStream.recover_signer(@topic, event_of(body), body["agentSig"])

      assert String.downcase(recovered) == String.downcase(@agent_address)
    end

    test "an unset settlement preference is treated as private (fail safe)" do
      assert :ok ==
               SwapAnnouncer.announce_execute(
                 context(),
                 request(nil),
                 quote_resp(),
                 exec()
               )

      assert_receive {:announce, _path, body}, 1000
      assert_redacted(body)
    end

    test "a shielded terminal row stays redacted and shares the execute pseudo id" do
      SwapAnnouncer.announce_execute(
        context(),
        request("shielded"),
        quote_resp(),
        exec()
      )

      assert_receive {:announce, _path, execute_body}, 1000
      pseudo = execute_body["event"]["intentId"]
      assert pseudo == expected_pseudo("int_1")

      status = %IntentStatus{intent_id: "int_1", status: :completed, tx_hash: "0xabc"}
      assert :ok == SwapAnnouncer.announce_terminal(context(), "int_1", status)

      assert_receive {:announce, _path, terminal_body}, 1000
      assert_redacted(terminal_body)
      assert terminal_body["event"]["status"] == "completed"
      # Same pseudo id so the browser merges the two rows, without exposing the
      # real intent id at any point.
      assert terminal_body["event"]["intentId"] == pseudo
    end

    test "a public execute still discloses the full route" do
      assert :ok ==
               SwapAnnouncer.announce_execute(
                 context(),
                 request("public"),
                 quote_resp(),
                 exec()
               )

      assert_receive {:announce, _path, body}, 1000
      assert body["event"]["intentId"] == "int_1"
      assert body["event"]["fromChainId"] == 8453
      assert body["event"]["fromAmount"] == "500000"
      assert body["event"]["toAmount"] == "499000"
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
