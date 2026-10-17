defmodule Raxol.Payments.Pxe.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Pxe.Client
  alias Raxol.Payments.Pxe.Schemas.CreateNoteParams

  @params %CreateNoteParams{
    recipient: "0x" <> String.duplicate("ab", 32),
    token: "0x" <> String.duplicate("cd", 32),
    amount: "1000000",
    chain_id: 1
  }

  @key "settlement-42"

  describe "create_note/3" do
    test "sends one positional params object with the idempotency key and bearer token" do
      parent = self()

      config =
        sim(fn conn ->
          send(parent, {:request, conn.req_headers, conn.body_params})
          rpc_ok(conn, note_result())
        end)

      assert {:ok, result} = Client.create_note(config, @params, @key)

      assert result.note_hashes == [
               "0x" <> String.duplicate("7c", 32),
               "0x" <> String.duplicate("7d", 32)
             ]

      assert result.nullifiers == ["0x" <> String.duplicate("3e", 32)]
      assert result.l2_tx_hash == "0x" <> String.duplicate("9a", 32)

      assert_received {:request, headers, body}
      assert {"idempotency-key", @key} in headers
      assert {"authorization", "Bearer test-key"} in headers
      assert body["method"] == "aztec_createNote"

      assert body["params"] == [
               %{
                 "recipient" => @params.recipient,
                 "token" => @params.token,
                 "amount" => "1000000",
                 "chainId" => 1
               }
             ]
    end

    test "-32002 is submitted-unknown carrying the bridge's tx hash" do
      tx = "0x" <> String.duplicate("9a", 32)
      config = sim(rpc_error(-32_002, "Transaction submitted, result unknown", %{"txHash" => tx}))

      assert {:error, {:submitted_unknown, ^tx}} = Client.create_note(config, @params, @key)
    end

    test "-32002 without data is submitted-unknown with no tx hash" do
      config = sim(rpc_error(-32_002, "Transaction submitted, result unknown"))

      assert {:error, {:submitted_unknown, nil}} = Client.create_note(config, @params, @key)
    end

    test "-32001 is request-in-flight" do
      config = sim(rpc_error(-32_001, "Request already in flight"))

      assert {:error, :request_in_flight} = Client.create_note(config, @params, @key)
    end

    test "any other RPC error keeps its code and message" do
      config = sim(rpc_error(-32_602, "Amount 1000000 exceeds per-transaction maximum 10"))

      assert {:error, {:rpc, -32_602, "Amount 1000000 exceeds per-transaction maximum 10"}} =
               Client.create_note(config, @params, @key)
    end

    test "a result with only the deprecated scalar fields is refused, not half-decoded" do
      config =
        sim(fn conn ->
          rpc_ok(conn, %{
            "noteCommitment" => "0x" <> String.duplicate("7c", 32),
            "nullifierHash" => "0x" <> String.duplicate("3e", 32),
            "l2TxHash" => "0x" <> String.duplicate("9a", 32)
          })
        end)

      assert {:error, {:unexpected_result, _}} = Client.create_note(config, @params, @key)
    end

    test "an invalid idempotency key is refused before any request" do
      parent = self()
      config = sim(fn conn -> send(parent, :requested) && rpc_ok(conn, note_result()) end)

      for key <- ["", "   ", String.duplicate("k", 129), "caf\u00e9", "line\nbreak", nil] do
        assert {:error, {:invalid_idempotency_key, _}} = Client.create_note(config, @params, key)
      end

      refute_received :requested
    end

    test "a refused connection is retried once with the same key" do
      parent = self()
      calls = :counters.new(1, [])

      config =
        sim(fn conn ->
          :counters.add(calls, 1, 1)
          send(parent, {:key, Plug.Conn.get_req_header(conn, "idempotency-key")})

          if :counters.get(calls, 1) == 1,
            do: Req.Test.transport_error(conn, :econnrefused),
            else: rpc_ok(conn, note_result())
        end)

      assert {:ok, _} = Client.create_note(config, @params, @key)
      assert :counters.get(calls, 1) == 2
      assert_received {:key, [@key]}
      assert_received {:key, [@key]}
    end

    # A timed-out create may still be proving on the bridge: resending is the
    # caller's call (with the same key), never this client's.
    test "a timeout is not retried" do
      calls = :counters.new(1, [])

      config =
        sim(fn conn ->
          :counters.add(calls, 1, 1)
          Req.Test.transport_error(conn, :timeout)
        end)

      assert {:error, %Req.TransportError{reason: :timeout}} =
               Client.create_note(config, @params, @key)

      assert :counters.get(calls, 1) == 1
    end

    test "a 504 from the bridge's response deadline is returned, not retried" do
      calls = :counters.new(1, [])

      config =
        sim(fn conn ->
          :counters.add(calls, 1, 1)

          conn
          |> Plug.Conn.put_status(504)
          |> Req.Test.json(%{
            "jsonrpc" => "2.0",
            "id" => nil,
            "error" => %{"code" => -32_603, "message" => "Gateway timeout"}
          })
        end)

      assert {:error, {:http, 504, _}} = Client.create_note(config, @params, @key)
      assert :counters.get(calls, 1) == 1
    end

    test "invalid params are refused before any request" do
      parent = self()
      config = sim(fn conn -> send(parent, :requested) && rpc_ok(conn, note_result()) end)

      assert {:error, {:invalid_amount, _}} =
               Client.create_note(config, %{@params | amount: "0"}, @key)

      refute_received :requested
    end
  end

  describe "get_version/1" do
    test "returns the version string" do
      assert {:ok, "0.87.4"} = Client.get_version(sim(&rpc_ok(&1, "0.87.4")))
    end

    test "retries a transient gateway status" do
      calls = :counters.new(1, [])

      config =
        sim(fn conn ->
          :counters.add(calls, 1, 1)

          if :counters.get(calls, 1) == 1,
            do: Plug.Conn.send_resp(conn, 502, "bad gateway"),
            else: rpc_ok(conn, "0.87.4")
        end)

      assert {:ok, "0.87.4"} = Client.get_version(config)
      assert :counters.get(calls, 1) == 2
    end

    test "a non-string result is refused" do
      assert {:error, {:unexpected_result, 42}} = Client.get_version(sim(&rpc_ok(&1, 42)))
    end

    test "no bearer header without an api key" do
      parent = self()

      config =
        %{
          sim(fn conn ->
            send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
            rpc_ok(conn, "0.87.4")
          end)
          | api_key: nil
        }

      assert {:ok, _} = Client.get_version(config)
      assert_received {:auth, []}
    end
  end

  describe "health/1" do
    test "decodes a ready bridge" do
      config = sim(&Req.Test.json(&1, %{"status" => "ok", "version" => "0.1.0"}))

      assert {:ok, %{status: :ok, version: "0.1.0"}} = Client.health(config)
    end

    test "a 503 starting body is a health report, returned without retrying" do
      calls = :counters.new(1, [])

      config =
        sim(fn conn ->
          :counters.add(calls, 1, 1)
          conn |> Plug.Conn.put_status(503) |> Req.Test.json(%{"status" => "starting"})
        end)

      assert {:ok, %{status: :starting}} = Client.health(config)
      assert :counters.get(calls, 1) == 1
    end
  end

  defp sim(plug) do
    %{
      url: "https://pxe.sim",
      api_key: "test-key",
      req_options: [plug: plug, retry_delay: fn _ -> 0 end, retry_log_level: false]
    }
  end

  defp rpc_ok(conn, result) do
    Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => result})
  end

  defp rpc_error(code, message, data \\ nil) do
    error = %{"code" => code, "message" => message}
    error = if data, do: Map.put(error, "data", data), else: error

    fn conn -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "error" => error}) end
  end

  defp note_result do
    %{
      "noteHashes" => ["0x" <> String.duplicate("7c", 32), "0x" <> String.duplicate("7d", 32)],
      "nullifiers" => ["0x" <> String.duplicate("3e", 32)],
      "l2TxHash" => "0x" <> String.duplicate("9a", 32),
      "noteCommitment" => "0x" <> String.duplicate("7c", 32),
      "nullifierHash" => "0x" <> String.duplicate("3e", 32)
    }
  end
end
