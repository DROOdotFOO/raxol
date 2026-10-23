defmodule Raxol.Earn.Xochi.SettlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.Xochi.Settler
  alias Raxol.Payments.Xochi.ReadTokenStore

  @src_token "0x" <> String.duplicate("11", 20)
  @dst_token "0x" <> String.duplicate("22", 20)
  @base_url "https://xochi.test"

  # A checkpoint store that dies while committing a terminal record, modelling
  # a crash between the terminal poll and the commit.
  defmodule CrashOnTerminal do
    @behaviour Raxol.Payments.Checkpoint
    alias Raxol.Payments.Checkpoint.ETS

    @impl true
    def fetch(table, key), do: ETS.fetch(table, key)

    @impl true
    def put(_table, _key, %{status: :terminal}), do: raise("crash before terminal commit")
    def put(table, key, record), do: ETS.put(table, key, record)

    @impl true
    def delete(table, key), do: ETS.delete(table, key)
  end

  # A checkpoint store that dies on delete, modelling a crash between the
  # terminal commit and the token cleanup.
  defmodule CrashOnDelete do
    @behaviour Raxol.Payments.Checkpoint
    alias Raxol.Payments.Checkpoint.ETS

    @impl true
    def fetch(table, key), do: ETS.fetch(table, key)

    @impl true
    def put(table, key, record), do: ETS.put(table, key, record)

    @impl true
    def delete(_table, _key), do: raise("crash before token cleanup")
  end

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
              send(test_pid, :executed)

              base =
                %{"success" => exec_status == 200, "intent_id" => "i1", "status" => "executing"}

              base
              |> Map.merge(if(exec_token, do: %{"read_token" => exec_token}, else: %{}))
              |> Map.merge(
                if(exec_status in 400..499, do: %{"error" => "request_rejected"}, else: %{})
              )

            "/api/intent/i1/status" ->
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

        status = if conn.request_path == "/api/intent/execute", do: exec_status, else: 200
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      end
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

    test "the replay checkpoint excludes the token and a re-run returns the committed result" do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

      assert {:ok, first} = read_cap_settler(issued, checkpoint: store).(args())
      assert_received :executed
      assert_received {:presented, [^issued], ""}

      assert {:ok, record} = Raxol.Payments.Checkpoint.fetch(store, key)
      assert record.status == :terminal
      refute Map.has_key?(record, :read_token)
      refute inspect(record) =~ issued

      # The token is dropped only once the terminal result is committed.
      assert ReadTokenStore.fetch(store, @base_url, "i1") == nil

      # An at-least-once re-run (or a crash after the commit) returns the stored
      # deliverable: no relay, no anonymous poll, no hash-unavailable failure.
      assert {:ok, ^first} = read_cap_settler(nil, checkpoint: store).(args())
      refute_received :executed
      refute_received {:presented, _, _}
      assert first.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
    end

    test "a crash before the terminal commit leaves the token for the re-run" do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      table = :ets.new(:settler_crash, [:set, :public])
      crashing = {CrashOnTerminal, table}
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

      assert_raise RuntimeError, fn -> read_cap_settler(issued, checkpoint: crashing).(args()) end
      assert_received :executed
      assert_received {:presented, [^issued], ""}

      store = {Raxol.Payments.Checkpoint.ETS, table}
      assert {:ok, %{status: :in_flight}} = Raxol.Payments.Checkpoint.fetch(store, key)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == issued

      assert {:ok, deliverable} = read_cap_settler(nil, checkpoint: store).(args())
      refute_received :executed
      assert_received {:presented, [^issued], ""}
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == nil
    end

    test "a crash after the terminal commit leaves no token behind on the re-run" do
      issued = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
      table = :ets.new(:settler_crash_delete, [:set, :public])
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

      assert_raise RuntimeError, fn ->
        read_cap_settler(issued, checkpoint: {CrashOnDelete, table}).(args())
      end

      store = {Raxol.Payments.Checkpoint.ETS, table}
      assert {:ok, %{status: :terminal}} = Raxol.Payments.Checkpoint.fetch(store, key)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == issued
      assert_received :executed
      assert_received {:presented, [^issued], ""}

      assert {:ok, deliverable} = read_cap_settler(nil, checkpoint: store).(args())
      refute_received :executed
      refute_received {:presented, _, _}
      assert deliverable.settlement_tx_hash == "0x" <> String.duplicate("a", 64)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == nil
    end

    test "a writer whose execute returns after another committed terminal drops its token" do
      token_b = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])
      committed = {:ok, %{intent_id: "i1", status: "completed"}}
      test_pid = self()

      # Writer A commits its terminal record (and crashes before deleting its
      # token) while B's execute is in flight; B then gets its own token back.
      plug = fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            Raxol.Payments.Checkpoint.put(store, key, %{
              intent_id: "i1",
              status: :terminal,
              result: committed
            })

            Req.Test.json(conn, %{
              "success" => true,
              "intent_id" => "i1",
              "status" => "executing",
              "read_token" => token_b
            })

          "/api/intent/i1/status" ->
            send(test_pid, :polled)
            Req.Test.json(conn, %{"intent_id" => "i1", "status" => "executing"})
        end
      end

      settle =
        Settler.build(
          xochi_config: %{base_url: @base_url, auth_token: "stub", req_options: [plug: plug]},
          poll_timeout_ms: 30,
          poll_interval_ms: 10,
          checkpoint: store
        )

      assert ^committed = settle.(args())
      refute_received :polled
      assert ReadTokenStore.fetch(store, @base_url, "i1") == nil
    end

    test "an anonymous terminal answer commits nothing and keeps the token" do
      foreign = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF"
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

      assert {:error, {:settlement_tx_hash_unavailable, "i1"}} =
               read_cap_settler(foreign, checkpoint: store).(args())

      assert {:ok, %{status: :in_flight}} = Raxol.Payments.Checkpoint.fetch(store, key)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == foreign
    end

    defp ambiguous_sim(outcome, test_pid) do
      fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(test_pid, :executed)

            case outcome do
              :timeout ->
                Req.Test.transport_error(conn, :timeout)

              :closed ->
                Req.Test.transport_error(conn, :closed)

              :invalid_json ->
                conn
                |> Plug.Conn.put_resp_content_type("application/json")
                |> Plug.Conn.send_resp(200, "{not-json")

              :invalid_body ->
                Req.Test.json(conn, ["not", "an", "execute", "response"])

              :server_500 ->
                conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "upstream"})
            end

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

    test "transport, decode, and 5xx execute outcomes poll instead of re-relaying" do
      for outcome <- [:timeout, :closed, :invalid_json, :invalid_body, :server_500] do
        store = Raxol.Payments.Checkpoint.ETS.new()
        key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

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

        assert {:ok, %{intent_id: "i1", status: :terminal, result: {:ok, %{status: "completed"}}}} =
                 Raxol.Payments.Checkpoint.fetch(store, key)
      end
    end

    test "a structurally valid clean execute rejection drops the checkpoint" do
      store = Raxol.Payments.Checkpoint.ETS.new()
      key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])

      assert {:error, {:http, 422, _}} =
               read_cap_settler(nil, exec_status: 422, checkpoint: store).(args())

      assert :error = Raxol.Payments.Checkpoint.fetch(store, key)
      assert ReadTokenStore.fetch(store, @base_url, "i1") == nil
    end

    # Another writer already claimed the intent: the worker answers 409 (claim
    # held) or 400 naming its status. This writer's outcome is unknown, so it
    # must keep the shared checkpoint and the winner's token, and poll.
    defp claimed_sim(status, body, test_pid) do
      fn conn ->
        case conn.request_path do
          "/api/intent/execute" ->
            send(test_pid, :executed)
            conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)

          "/api/intent/i1/status" ->
            send(test_pid, {:presented, Plug.Conn.get_req_header(conn, "x-xochi-read-token")})
            Req.Test.json(conn, %{"intent_id" => "i1", "status" => "executing"})
        end
      end
    end

    test "a writer that lost the execute race keeps the winner's checkpoint and token" do
      winner = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

      refusals = [
        {409, %{"success" => false, "error" => "Intent already being executed"}},
        {400, %{"success" => false, "error" => "Cannot execute intent in executing status"}}
      ]

      for {status, body} <- refusals do
        store = Raxol.Payments.Checkpoint.ETS.new()
        key = Raxol.Payments.Checkpoint.derive_key([:xochi_settler, "i1"])
        ReadTokenStore.put(store, @base_url, "i1", winner)

        settle =
          Settler.build(
            xochi_config: %{
              base_url: @base_url,
              auth_token: "stub",
              req_options: [plug: claimed_sim(status, body, self()), retry: false]
            },
            poll_timeout_ms: 30,
            poll_interval_ms: 10,
            checkpoint: store
          )

        assert {:error, :timeout} = settle.(args())
        assert_received :executed
        # It polls the claimed intent with the winner's token rather than failing.
        assert_received {:presented, [^winner]}
        assert {:ok, %{status: :in_flight}} = Raxol.Payments.Checkpoint.fetch(store, key)
        assert ReadTokenStore.fetch(store, @base_url, "i1") == winner

        # A re-run resumes the same intent; it never relays again.
        assert {:error, :timeout} = settle.(args())
        refute_received :executed
        assert_received {:presented, [^winner]}
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
