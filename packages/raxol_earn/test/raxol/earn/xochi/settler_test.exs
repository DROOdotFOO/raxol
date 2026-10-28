Code.require_file(
  "../../../../../raxol_payments/test/support/xochi_intent_fixture.ex",
  __DIR__
)

defmodule Raxol.Earn.Xochi.SettlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Xochi.Settler
  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Xochi.ReadTokenStore

  @src_token "0x" <> String.duplicate("11", 20)
  @dst_token "0x" <> String.duplicate("22", 20)
  @base_url "https://xochi.test"

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

  defp principal(bundle \\ signed_intent()) do
    {:ok, request} = Raxol.Payments.Protocols.Xochi.prepare_signed_execute(bundle)
    Raxol.Payments.Xochi.SettlementState.fingerprint(request)
  end

  defp token_fetch(store, intent_id) do
    ReadTokenStore.fetch(
      store,
      @base_url,
      principal(),
      intent_id,
      System.system_time(:second)
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

    # xochi#563: the worker withholds a non-public intent's legs on status unless
    # the caller presents the read token execute returned. This sim does the
    # same: `exec_token` is what execute returns (nil = older worker / lost), and
    # the stealth status carries hashes only for the matching header.
    defp read_cap_sim(exec_token, test_pid, exec_status) do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      fn conn ->
        body =
          case conn.request_path do
            "/api/intent/execute" ->
              read_cap_execute(exec_token, exec_status, test_pid)

            "/api/intent/i1/status" ->
              read_cap_status(conn, issued, test_pid)
          end

        status = if conn.request_path == "/api/intent/execute", do: exec_status, else: 200
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
    end

    defp read_cap_execute(exec_token, exec_status, test_pid) do
      send(test_pid, :executed)

      %{"success" => exec_status == 200, "intent_id" => "i1", "status" => "executing"}
      |> Map.merge(if(exec_token, do: %{"read_token" => exec_token}, else: %{}))
      |> Map.merge(if(exec_status in 400..499, do: %{"error" => "request_rejected"}, else: %{}))
    end

    defp read_cap_status(conn, issued, test_pid) do
      presented = Plug.Conn.get_req_header(conn, "x-xochi-read-token")
      send(test_pid, {:presented, presented, conn.query_string})

      legs =
        if presented == [issued],
          do: %{
            "txHash" => "0x" <> String.duplicate("a", 64),
            "receivingTxHash" => "0x" <> String.duplicate("b", 64)
          },
          else: %{"settlement_confirmed" => true, "legs_withheld" => true}

      Map.merge(
        %{
          "intentId" => "i1",
          "status" => "completed",
          "terminal" => true,
          "settlementType" => "stealth"
        },
        legs
      )
    end

    defp read_cap_settler(exec_token, opts \\ []) do
      Settler.build(
        xochi_config: %{
          base_url: "https://xochi.test",
          auth_token: "stub",
          req_options: [
            plug: read_cap_sim(exec_token, self(), Keyword.get(opts, :exec_status, 200))
          ]
        },
        poll_timeout_ms: 5_000,
        poll_interval_ms: 10,
        checkpoint: Keyword.get(opts, :checkpoint)
      )
    end

    test "polls with the execute's read token, so a stealth settlement keeps its hashes" do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      assert {:ok, deliverable} = read_cap_settler(issued).(args())
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert deliverable.receiving_tx_hash == "0x" <> String.duplicate("b", 64)
      # Header only, never the URL; and never in the deliverable.
      assert_received {:presented, [^issued], ""}
      refute deliverable |> Map.values() |> Enum.member?(issued)
    end

    test "a withheld settlement hash is an explicit error, never a fabricated hash" do
      # Execute returned no token (older worker, or one lost), so the worker
      # withholds the stealth legs. The deliverable schema requires
      # settlement_tx_hash, so the settle fails with the intent id.
      assert {:error, {:settlement_tx_hash_unavailable, "i1"}} = read_cap_settler(nil).(args())
      assert_received {:presented, [], ""}
    end

    test "a 502 carrying the read token is polled with it, not failed (funds may have moved)" do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      assert {:ok, deliverable} = read_cap_settler(issued, exec_status: 502).(args())
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert_received {:presented, [^issued], ""}
    end

    test "a 502 without a token is polled anonymously because the outcome is unknown" do
      assert {:error, {:settlement_tx_hash_unavailable, "i1"}} =
               read_cap_settler(nil, exec_status: 502).(args())

      assert_received {:presented, [], ""}
    end

    defp ambiguous_sim(outcome, test_pid) do
      fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(test_pid, :executed)

            XochiIntentFixture.serve_ambiguous_execute(conn, outcome)

          "/api/intent/i1/status" ->
            Req.Test.json(conn, %{
              "intent_id" => "i1",
              "status" => "completed",
              "terminal" => true,
              "tx_hash" => "0x" <> String.duplicate("a", 64)
            })
        end
      end
    end

    test "ambiguous decode, reset, and 5xx outcomes poll instead of re-relaying" do
      for outcome <- [:timeout, :closed, :invalid_json, :invalid_body, :server_500] do
        store = Raxol.Payments.Checkpoint.ETS.new()

        settle =
          Settler.build(
            xochi_config: %{
              base_url: "https://xochi.test",
              auth_token: "stub",
              req_options: [plug: ambiguous_sim(outcome, self()), retry: false]
            },
            poll_timeout_ms: 5_000,
            poll_interval_ms: 10,
            checkpoint: store
          )

        assert {:ok, %{intent_id: "i1", status: "completed"}} = settle.(args())
        assert_received :executed
        refute_received :executed

        assert :error =
                 Raxol.Payments.Checkpoint.fetch(
                   store,
                   Raxol.Payments.Checkpoint.derive_key([
                     :xochi_settler,
                     @base_url,
                     "i1"
                   ])
                 )
      end
    end

    test "ambiguous dispatch followed by 404 past signed deadline releases state" do
      now = 1_900_000_000
      store = Raxol.Payments.Checkpoint.ETS.new()
      bundle = signed_intent(%{"deadline" => now - 1})
      test_pid = self()

      plug = fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(test_pid, :executed)
            Req.Test.transport_error(conn, :closed)

          "/api/intent/i1/status" ->
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not_found"})
        end
      end

      settle =
        Settler.build(
          xochi_config: %{base_url: @base_url, req_options: [plug: plug, retry: false]},
          checkpoint: store,
          clock: fn -> now end
        )

      assert {:error, {:never_dispatched, "i1"}} =
               settle.(args(%{signed_intent: bundle}))

      assert_received :executed

      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, @base_url, "i1"])
      assert :error = Raxol.Payments.Checkpoint.fetch(store, key)
      assert token_fetch(store, "i1") == nil
    end

    test "concurrent relay has one owner and the loser cannot delete its state" do
      parent = self()

      plug = fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(parent, {:execute_started, self()})

            receive do
              :release_execute ->
                Req.Test.json(conn, %{
                  "success" => true,
                  "intentId" => "i1",
                  "status" => "executing"
                })
            end

          "/api/intent/i1/status" ->
            Req.Test.json(conn, %{
              "intentId" => "i1",
              "status" => "completed",
              "terminal" => true,
              "txHash" => "0x" <> String.duplicate("a", 64)
            })
        end
      end

      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, @base_url, "i1"])

      settle =
        Settler.build(
          xochi_config: %{
            base_url: @base_url,
            auth_token: "stub",
            req_options: [plug: plug, retry: false]
          },
          checkpoint: store,
          poll_interval_ms: 0,
          clock: fn -> 1_900_000_000 end
        )

      winner = Task.async(fn -> settle.(args()) end)
      assert_receive {:execute_started, writer}

      assert {:error, {:intent_dispatch_in_progress, "i1"}} =
               Task.async(fn -> settle.(args()) end) |> Task.await()

      assert {:ok, %{status: :dispatching}} = Raxol.Payments.Checkpoint.fetch(store, key)
      refute_received {:execute_started, _other}

      send(writer, :release_execute)
      assert {:ok, %{settlement_tx_hash: "0x" <> _}} = Task.await(winner)
      assert :error = Raxol.Payments.Checkpoint.fetch(store, key)
    end

    test "a structurally valid clean execute rejection drops the checkpoint" do
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, @base_url, "i1"])

      assert {:error, {:http, 422, _}} =
               read_cap_settler(nil, exec_status: 422, checkpoint: store).(args())

      assert :error = Raxol.Payments.Checkpoint.fetch(store, key)
      assert token_fetch(store, "i1") == nil
    end

    defp claimed_sim(status, body, test_pid) do
      fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(test_pid, :executed)
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

          "/api/intent/victim1/status" ->
            send(test_pid, {:presented, Plug.Conn.get_req_header(conn, "x-xochi-read-token")})

            Req.Test.json(conn, %{
              "intent_id" => "victim1",
              "status" => "completed",
              "tx_hash" => "0x" <> String.duplicate("a", 64)
            })
        end
      end
    end

    test "refused forged bundle never polls the victim or sends its token" do
      victim_token = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      victim_principal = "wallet:victim"

      forged_bundle =
        signed_intent(%{
          "intent_id" => "victim1",
          "signature" => "0x" <> String.duplicate("00", 65)
        })

      forged_args = args(%{signed_intent: forged_bundle})

      refusals = [
        {409, %{"success" => false, "error" => "Intent already being executed"}},
        {400, %{"success" => false, "error" => "Cannot execute intent in completed status"}}
      ]

      for {status, body} <- refusals do
        store = Raxol.Payments.Checkpoint.ETS.new()

        ReadTokenStore.put(
          store,
          @base_url,
          victim_principal,
          "victim1",
          victim_token,
          1_900_000_000
        )

        settle =
          Settler.build(
            xochi_config: %{
              base_url: @base_url,
              auth_token: "stub",
              req_options: [plug: claimed_sim(status, body, self()), retry: false]
            },
            checkpoint: store,
            clock: fn -> 1_900_000_000 end
          )

        assert {:error, {:http, ^status, _}} = settle.(forged_args)
        assert_received :executed
        refute_received {:presented, _}

        assert ReadTokenStore.fetch(
                 store,
                 @base_url,
                 victim_principal,
                 "victim1",
                 1_900_000_000
               ) == victim_token
      end
    end

    test "an expired intent's refusal stays a clean rejection" do
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])
      body = %{"success" => false, "error" => "Cannot execute intent in expired status"}

      settle =
        Settler.build(
          xochi_config: %{
            base_url: @base_url,
            auth_token: "stub",
            req_options: [plug: claimed_sim(400, body, self()), retry: false]
          },
          checkpoint: store
        )

      assert {:error, {:http, 400, _}} = settle.(args())
      assert :error = Raxol.Payments.Checkpoint.fetch(store, key)
    end
  end
end
