defmodule Raxol.Earn.ProviderAdapter.PrivyTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.ProviderAdapter.Privy

  @addr "0x" <> String.duplicate("ab", 20)

  # An in-process signing sidecar: a Req plug that echoes each request to the test
  # and returns a canned {status, body} per path. No Node process, no network.
  defp sidecar(test_pid, responses) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sidecar, conn.request_path, Jason.decode!(body)})
      {status, resp} = Map.get(responses, conn.request_path, {200, %{}})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(resp))
    end

    Privy.new(
      sidecar_url: "http://127.0.0.1:4048/",
      address: @addr,
      chains: %{8453 => "https://mainnet.base.org"},
      req_options: [plug: plug, retry: false]
    )
  end

  describe "new/1" do
    test "trims a trailing slash from the sidecar url and defaults the timeout" do
      adapter =
        Privy.new(sidecar_url: "http://127.0.0.1:4048/", address: @addr, chains: %{8453 => "u"})

      assert adapter.config.sidecar_url == "http://127.0.0.1:4048"
      assert adapter.config.req_options[:receive_timeout] == 60_000
    end

    test "exposes the managed wallet address and the sorted supported chains" do
      adapter =
        Privy.new(sidecar_url: "http://x", address: @addr, chains: %{42_161 => "a", 8453 => "b"})

      assert Privy.get_address(adapter) == @addr
      assert Privy.supported_chain_ids(adapter) == [8453, 42_161]
    end
  end

  describe "sign_message/3" do
    test "posts to /sign-message and decodes the hex signature to raw bytes" do
      sig_hex = String.duplicate("ab", 65)
      adapter = sidecar(self(), %{"/sign-message" => {200, %{"signature" => "0x" <> sig_hex}}})

      assert {:ok, raw} = Privy.sign_message(adapter, 8453, "hello")
      assert raw == Base.decode16!(sig_hex, case: :mixed)
      assert_receive {:sidecar, "/sign-message", %{"chainId" => 8453, "message" => "hello"}}
    end
  end

  describe "sign_typed_data/3" do
    test "normalizes tuple type-fields to objects and decodes the signature" do
      typed = %{
        domain: %{"name" => "Xochi"},
        types: %{"XochiIntent" => [{"intentId", "string"}, {"amount", "uint256"}]},
        message: %{"intentId" => "xi_1"}
      }

      sig_hex = String.duplicate("cd", 65)
      adapter = sidecar(self(), %{"/sign-typed-data" => {200, %{"signature" => "0x" <> sig_hex}}})

      assert {:ok, raw} = Privy.sign_typed_data(adapter, 8453, typed)
      assert raw == Base.decode16!(sig_hex, case: :mixed)

      assert_receive {:sidecar, "/sign-typed-data", body}

      assert body["typedData"]["types"]["XochiIntent"] == [
               %{"name" => "intentId", "type" => "string"},
               %{"name" => "amount", "type" => "uint256"}
             ]
    end
  end

  describe "send_calls/3" do
    test "hex-encodes data, stringifies value, and returns the tx hashes" do
      adapter = sidecar(self(), %{"/send-calls" => {200, %{"txHashes" => ["0xabc"]}}})
      calls = [%{to: "0xdead", data: <<1, 2, 3>>, value: 1000}]

      assert {:ok, ["0xabc"]} = Privy.send_calls(adapter, 8453, calls)
      assert_receive {:sidecar, "/send-calls", %{"calls" => [call]}}
      assert call["to"] == "0xdead"
      assert call["data"] == "0x010203"
      assert call["value"] == "1000"
    end

    test "defaults empty data and zero value" do
      adapter = sidecar(self(), %{"/send-calls" => {200, %{"txHashes" => []}}})
      assert {:ok, []} = Privy.send_calls(adapter, 8453, [%{to: "0xfeed"}])

      assert_receive {:sidecar, "/send-calls", %{"calls" => [call]}}
      assert call["data"] == "0x"
      assert call["value"] == "0"
    end
  end

  describe "sidecar error mapping" do
    test "a 409 approval_required surfaces the approval id + url" do
      adapter =
        sidecar(self(), %{
          "/sign-message" =>
            {409,
             %{
               "error" => "approval_required",
               "approvalId" => "ap_1",
               "approvalUrl" => "https://approve.example/ap_1"
             }}
        })

      assert {:error, {:approval_required, "ap_1", "https://approve.example/ap_1"}} =
               Privy.sign_message(adapter, 8453, "x")
    end

    test "a non-200 surfaces {:signer, status, detail}" do
      adapter = sidecar(self(), %{"/sign-message" => {500, %{"detail" => "boom"}}})
      assert {:error, {:signer, 500, "boom"}} = Privy.sign_message(adapter, 8453, "x")
    end
  end

  describe "read callbacks" do
    test "reject an unsupported chain before any network call" do
      adapter = Privy.new(sidecar_url: "http://x", address: @addr, chains: %{8453 => "u"})

      assert {:error, {:unsupported_chain, 10}} =
               Privy.get_transaction_receipt(adapter, 10, "0xh")
    end
  end
end
