defmodule Raxol.Earn.Xochi.SettlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Xochi.Settler

  @src_token "0x" <> String.duplicate("11", 20)
  @dst_token "0x" <> String.duplicate("22", 20)

  # A buyer-signed Xochi intent bundle, as it arrives in the requirement JSON
  # (string keys). Signature values are opaque -- raxol relays them; Riddler
  # verifies against its persisted quote.
  defp signed_intent(overrides \\ %{}) do
    Map.merge(
      %{
        "intent_id" => "i1",
        "quote_id" => "q1",
        "signature" => "0x" <> String.duplicate("11", 65),
        "nonce" => 7,
        "pull_signature" => "0x" <> String.duplicate("22", 65)
      },
      overrides
    )
  end

  defp requirement(overrides \\ %{}) do
    Map.merge(
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => @src_token,
        "dst_token" => @dst_token,
        "amount_atomic" => "1000000",
        "signed_intent" => signed_intent()
      },
      overrides
    )
  end

  # The SolverAgent threads the bundle both ways: `:signed_intent` directly and
  # inside `:requirement`. Default args carry both.
  defp args(overrides \\ %{}) do
    req = requirement()

    Map.merge(
      %{
        requirement: req,
        signed_intent: req["signed_intent"],
        transfer_amount_atomic: 1_000_000
      },
      overrides
    )
  end

  describe "build/1" do
    test "raises when :xochi_config is missing" do
      assert_raise KeyError, fn -> Settler.build([]) end
    end

    test "returns a function of arity 1" do
      f = Settler.build(xochi_config: %{base_url: "https://xochi.test"})
      assert is_function(f, 1)
    end
  end

  describe "relay (pure storefront: no wallet, no re-signing)" do
    # A worker sim over the real client paths (`/api/intent/*`). No quote call --
    # the buyer already quoted; the settler only executes (relays) and polls.
    # camelCase bodies: ExecuteResponse/IntentStatus read camelCase.
    defp sim(status, test_pid) do
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        if conn.request_path == "/api/intent/execute" do
          send(test_pid, {:relayed, Jason.decode!(raw)})
        end

        body =
          case conn.request_path do
            "/api/intent/execute" ->
              %{"success" => true, "intentId" => "i1", "status" => "executing"}

            "/api/intent/i1/status" ->
              %{
                "intentId" => "i1",
                "status" => status,
                "terminal" => true,
                "txHash" => "0x" <> String.duplicate("a", 64),
                "receivingTxHash" => "0x" <> String.duplicate("b", 64)
              }
          end

        Req.Test.json(conn, body)
      end
    end

    defp settler_for(status) do
      Settler.build(
        xochi_config: %{
          base_url: "https://xochi.test",
          auth_token: "stub",
          req_options: [plug: sim(status, self())]
        },
        poll_timeout_ms: 5_000,
        poll_interval_ms: 10
      )
    end

    test "relays the buyer's signed bundle verbatim, without re-signing" do
      assert {:ok, _deliverable} = settler_for("completed").(args())

      # The execute POST carries the BUYER's signature, pull_signature, and
      # nonce unchanged -- raxol signs nothing.
      assert_receive {:relayed, relayed}
      assert relayed["signature"] == "0x" <> String.duplicate("11", 65)
      assert relayed["pull_signature"] == "0x" <> String.duplicate("22", 65)
      assert relayed["nonce"] == 7
      assert relayed["intent_id"] == "i1"
      assert relayed["quote_id"] == "q1"
    end

    test "a completed intent yields a deliverable with the settlement tx hashes" do
      assert {:ok, deliverable} = settler_for("completed").(args())
      assert deliverable.intent_id == "i1"
      assert deliverable.status == "completed"
      # IntentStatus tx_hash / receiving_tx_hash surface under matching names.
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert deliverable.receiving_tx_hash == "0x" <> String.duplicate("b", 64)
      # The deliverable commits the declared transfer amount.
      assert deliverable.amount_atomic == "1000000"
    end

    test "extracts the signed intent from the requirement when not threaded directly" do
      only_requirement = %{requirement: requirement(), transfer_amount_atomic: 1_000_000}
      assert {:ok, deliverable} = settler_for("completed").(only_requirement)
      assert deliverable.intent_id == "i1"
    end

    test "a failed intent is an error, not a deliverable" do
      assert {:error, {:settlement_failed, :failed, "i1", _}} = settler_for("failed").(args())
    end

    test "an expired intent is an error, not a deliverable" do
      assert {:error, {:settlement_failed, :expired, "i1", _}} = settler_for("expired").(args())
    end

    test "errors before any relay when the requirement carries no signed_intent" do
      no_bundle = %{requirement: Map.delete(requirement(), "signed_intent")}
      assert {:error, :missing_signed_intent} = settler_for("completed").(no_bundle)
      refute_received {:relayed, _}
    end

    test "errors before any relay when the signed intent has no intent_id" do
      bundle = Map.delete(signed_intent(), "intent_id")

      assert {:error, {:invalid_signed_intent, :intent_id}} =
               settler_for("completed").(args(%{signed_intent: bundle}))

      refute_received {:relayed, _}
    end

    # A stealth settlement: the worker returns the ERC-5564 announcement
    # (stealth_address / ephemeral_pub_key / view_tag) on execute and marks the
    # settled intent settlement_type "stealth" on poll. The recipient and privacy
    # tier live inside the buyer's opaque signature; the settler only relays.
    defp stealth_sim(test_pid) do
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        if conn.request_path == "/api/intent/execute" do
          send(test_pid, {:relayed, Jason.decode!(raw)})
        end

        body =
          case conn.request_path do
            "/api/intent/execute" ->
              %{
                "success" => true,
                "intentId" => "i1",
                "status" => "executing",
                "stealth_address" => "0x" <> String.duplicate("5c", 20),
                "ephemeral_pub_key" => "0x02" <> String.duplicate("ab", 32),
                "view_tag" => 42
              }

            "/api/intent/i1/status" ->
              %{
                "intentId" => "i1",
                "status" => "completed",
                "terminal" => true,
                "settlement_type" => "stealth",
                "txHash" => "0x" <> String.duplicate("a", 64),
                "receivingTxHash" => "0x" <> String.duplicate("b", 64)
              }
          end

        Req.Test.json(conn, body)
      end
    end

    defp stealth_settler_for(test_pid) do
      Settler.build(
        xochi_config: %{
          base_url: "https://xochi.test",
          auth_token: "stub",
          req_options: [plug: stealth_sim(test_pid)]
        },
        poll_timeout_ms: 5_000,
        poll_interval_ms: 10
      )
    end

    test "a stealth settlement surfaces the ERC-5564 announcement fields (#368)" do
      # The buyer signed a stealth intent (keys + ephemeral recipient inside the
      # signature) and its bundle carries a shielded-claim aztec_proof. The
      # settler relays the opaque bundle verbatim, and the deliverable surfaces
      # the public ERC-5564 announcement the evaluator verifies on-chain.
      bundle = signed_intent(%{"aztec_proof" => "0x" <> String.duplicate("de", 40)})

      stealth_args =
        args(%{
          requirement:
            requirement(%{
              "settlement_preference" => "stealth",
              "destination" => "0x" <> String.duplicate("5c", 20),
              "signed_intent" => bundle
            }),
          signed_intent: bundle
        })

      assert {:ok, deliverable} = stealth_settler_for(self()).(stealth_args)

      assert deliverable.settlement_type == "stealth"
      assert deliverable.stealth_address == "0x" <> String.duplicate("5c", 20)
      assert deliverable.ephemeral_pub_key == "0x02" <> String.duplicate("ab", 32)
      assert deliverable.view_tag == 42
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert deliverable.receiving_tx_hash == "0x" <> String.duplicate("b", 64)

      # The buyer's opaque bundle -- signature and shielded-claim proof -- is
      # relayed unchanged; raxol signs nothing and strips nothing.
      assert_receive {:relayed, relayed}
      assert relayed["signature"] == "0x" <> String.duplicate("11", 65)
      assert relayed["aztec_proof"] == "0x" <> String.duplicate("de", 40)
    end

    test "a different-recipient intent is relayed and settled, not gated (#368)" do
      # The recipient the buyer signed lives inside the opaque bundle; the
      # requirement's `destination` is only an audit hint. The settle path must
      # relay and settle it unchanged -- there is no same-owner or public-only
      # gate on raxol's side.
      diff_recipient_args =
        args(%{
          requirement:
            requirement(%{
              "settlement_preference" => "stealth",
              "destination" => "0x" <> String.duplicate("fe", 20)
            })
        })

      assert {:ok, deliverable} = settler_for("completed").(diff_recipient_args)
      assert deliverable.intent_id == "i1"
      assert deliverable.status == "completed"

      # The buyer's bundle relays verbatim; the audit-hint destination never
      # touches the relay POST.
      assert_receive {:relayed, relayed}
      assert relayed["signature"] == "0x" <> String.duplicate("11", 65)
      refute Map.has_key?(relayed, "destination")
    end
  end
end
