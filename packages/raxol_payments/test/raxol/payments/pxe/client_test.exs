defmodule Raxol.Payments.Pxe.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Pxe.Client
  alias Raxol.Payments.Pxe.Schemas.CreateNoteParams

  @config %{url: "http://127.0.0.1:19999", api_key: "test-key", retry: false}

  @valid_params %CreateNoteParams{
    recipient: "0x" <> String.duplicate("ab", 32),
    token: "0x" <> String.duplicate("cd", 32),
    amount: "1000000",
    chain_id: 1
  }

  # Everything below the seam used to be untested: with no way to inject a
  # transport, the suite could only prove the client fails against a dead port.
  # The decode path, the RPC error path and the auth header had never run.
  describe "against a bridge" do
    test "create_note decodes the result into a struct" do
      config = sim(ok(note_result()))

      assert {:ok, result} = Client.create_note(config, @valid_params)
      assert result.note_commitment == "0x" <> String.duplicate("7c", 32)
      assert result.nullifier_hash == "0x" <> String.duplicate("3e", 32)
      assert result.l2_tx_hash == "0x" <> String.duplicate("9a", 32)
    end

    test "get_version returns the version string" do
      assert {:ok, "0.87.4"} = Client.get_version(sim(ok("0.87.4")))
    end

    test "health decodes the status endpoint" do
      config = sim(fn conn -> Req.Test.json(conn, %{"status" => "ok", "version" => "0.1.0"}) end)

      assert {:ok, health} = Client.health(config)
      assert health.status == :ok
    end

    # A JSON-RPC error arrives with HTTP 200, so this is only distinguishable
    # from success by the body -- the case a dead port can never reach.
    test "an RPC error is an error, not a decoded result" do
      config =
        sim(fn conn ->
          Req.Test.json(conn, %{
            "jsonrpc" => "2.0",
            "id" => 1,
            "error" => %{"code" => -32_000, "message" => "pxe not synced"}
          })
        end)

      assert {:error, {:rpc, -32_000, "pxe not synced"}} =
               Client.create_note(config, @valid_params)
    end

    test "the api key is sent as a bearer token" do
      parent = self()

      config =
        sim(fn conn ->
          send(parent, {:auth, Plug.Conn.get_req_header(conn, "authorization")})
          ok("0.87.4").(conn)
        end)

      assert {:ok, _} = Client.get_version(config)
      assert_receive {:auth, ["Bearer test-key"]}
    end
  end

  defp sim(fun) do
    %{url: "https://pxe.sim", api_key: "test-key", retry: false, req_options: [plug: fun]}
  end

  defp ok(result) do
    fn conn -> Req.Test.json(conn, %{"jsonrpc" => "2.0", "id" => 1, "result" => result}) end
  end

  defp note_result do
    %{
      "noteCommitment" => "0x" <> String.duplicate("7c", 32),
      "nullifierHash" => "0x" <> String.duplicate("3e", 32),
      "l2TxHash" => "0x" <> String.duplicate("9a", 32)
    }
  end

  describe "create_note/2" do
    test "validates params before making RPC call" do
      bad_params = %{@valid_params | recipient: "0xshort"}
      assert {:error, {:invalid_recipient, _}} = Client.create_note(@config, bad_params)
    end

    test "returns connection error for unreachable host" do
      assert {:error, _reason} = Client.create_note(@config, @valid_params)
    end
  end

  describe "get_version/1" do
    test "returns connection error for unreachable host" do
      assert {:error, _reason} = Client.get_version(@config)
    end
  end

  describe "health/1" do
    test "returns connection error for unreachable host" do
      assert {:error, _reason} = Client.health(@config)
    end
  end

  describe "auth headers" do
    test "config without api_key still works" do
      config = %{url: "http://127.0.0.1:19999", retry: false}
      assert {:error, _reason} = Client.health(config)
    end

    test "config with nil api_key still works" do
      config = %{url: "http://127.0.0.1:19999", api_key: nil, retry: false}
      assert {:error, _reason} = Client.health(config)
    end
  end
end
