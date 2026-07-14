defmodule Raxol.ACP.Xochi.FixtureParityTest do
  @moduledoc """
  Keeps `FakeXochi` honest against the real Xochi worker.

  The fixtures under `test/fixtures/xochi/` are real `POST /api/intent/quote`
  responses captured from production `api.xochi.fi` (read-only, no funds). These
  tests assert that (1) the real responses still parse into the shape the client
  signs and settles, and (2) `FakeXochi` serves the same shape on the fields the
  code actually reads -- so a drift on either side fails a CI test instead of only
  surfacing live.

  ## Refreshing the fixtures

  Re-capture with a Member token (read-only; the wallet is a public dummy, so no
  funds and no key are involved):

      TOKEN="$(op read 'op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential')"
      W=0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045
      curl -sS -X POST https://api.xochi.fi/api/intent/quote \\
        -H "authorization: Bearer $TOKEN" -H 'content-type: application/json' \\
        -d '{"wallet":"'$W'","from_chain_id":8453,"to_chain_id":42161,
             "from_token":"0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
             "to_token":"0xaf88d065e77c8cc2239327c5edb3a432268e5831",
             "from_amount":"1100000","settlement_preference":"public",
             "slippage_bps":50,"deadline":9999999999,"gasless":false}'

  The `:live_parity` shadow test below re-checks the live shape against the fixture
  when `XOCHI_PARITY_TOKEN` is set (compile-gated, excluded from CI).
  """

  use ExUnit.Case, async: true

  alias Raxol.ACP.TestSupport.FakeXochi
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  @wallet "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"

  # The fields the sign/settle flow reads from a fillable quote. FakeXochi must
  # populate every one the real worker does.
  @core_fillable [
    :intent_id,
    :quote_id,
    :can_solve,
    :payment_method,
    :to_amount,
    :xochi_fee,
    :eip712_data,
    :pull_authorization,
    :settlement_options
  ]

  describe "real fixtures parse into the shape the client uses" do
    test "a fillable quote carries a signable intent + an ERC-3009 origin pull" do
      real = real_quote("quote_fillable.json")

      assert real.can_solve == true
      assert real.payment_method == "erc3009"
      assert is_binary(real.to_amount)
      assert is_map(real.eip712_data)
      assert real.eip712_data["primaryType"] == "XochiIntent"
      assert Map.has_key?(real.eip712_data["domain"], "salt")

      assert is_map(real.pull_authorization)
      assert real.pull_authorization["primaryType"] == "ReceiveWithAuthorization"

      assert erc3009_message_fields(real.pull_authorization) ==
               MapSet.new(~w(from to value validAfter validBefore nonce))
    end

    test "a below-minimum / unavailable quote reports can_solve:false with an error" do
      for fixture <- ["quote_below_min.json", "quote_unavailable.json"] do
        real = real_quote(fixture)
        assert real.can_solve == false, "#{fixture} should not be solvable"
        assert is_binary(real.error), "#{fixture} should carry an error string"
      end
    end
  end

  describe "the fake serves the same shape as the real worker" do
    test "a fillable fake quote populates the same core fields, with matching structure" do
      real = real_quote("quote_fillable.json")
      fake = fake_quote(start_fake(), request(8453, 42_161, "USDC", "USDC", "1100000"))

      for field <- @core_fillable do
        refute is_nil(Map.get(real, field)), "real fillable quote missing #{field}"

        refute is_nil(Map.get(fake, field)),
               "fake omits #{field} that the real worker returns: #{inspect(real)}"
      end

      assert fake.can_solve == real.can_solve
      assert fake.payment_method == real.payment_method

      # EIP-712 intent: same primaryType and a salt-bearing domain (no verifyingContract).
      assert fake.eip712_data["primaryType"] == real.eip712_data["primaryType"]
      assert Map.has_key?(fake.eip712_data["domain"], "salt")
      refute Map.has_key?(fake.eip712_data["domain"], "verifyingContract")

      # Origin pull: same envelope type and the identical set of signed message fields.
      assert fake.pull_authorization["primaryType"] == real.pull_authorization["primaryType"]

      assert erc3009_message_fields(fake.pull_authorization) ==
               erc3009_message_fields(real.pull_authorization)
    end

    test "a below-floor fake quote reports can_solve:false with an error, like the real worker" do
      real = real_quote("quote_below_min.json")
      fake = fake_quote(start_fake(), request(8453, 42_161, "USDC", "USDC", "500000"))

      assert fake.can_solve == real.can_solve
      assert fake.can_solve == false
      assert is_binary(fake.error)
    end

    test "an unavailable origin surfaces as a 503, matching the real worker's shape" do
      real_body = load("quote_unavailable.json")
      assert real_body["can_solve"] == false
      assert is_binary(real_body["error"])

      {:ok, fake} = FakeXochi.start_link(unavailable_origins: [4663])

      assert {:error, {:http, 503, body}} =
               Xochi.get_quote(
                 FakeXochi.config(fake),
                 request(4663, 8453, "USDG", "USDC", "1100000")
               )

      assert body["can_solve"] == false
      assert body["error"] =~ "unavailable"
    end
  end

  # A shadow contract test: re-check the LIVE worker against the committed fixture,
  # so prod drift (a new/removed core field) is caught. Compile-gated on
  # XOCHI_PARITY_TOKEN, read-only, no funds; excluded from CI.
  if System.get_env("XOCHI_PARITY_TOKEN") do
    @tag :live_parity
    test "LIVE: the real endpoint still populates the fixture's core fields" do
      config = %{
        base_url: System.get_env("XOCHI_PARITY_URL", "https://api.xochi.fi"),
        auth_token: System.fetch_env!("XOCHI_PARITY_TOKEN")
      }

      fixture = real_quote("quote_fillable.json")

      assert {:ok, live} =
               Xochi.get_quote(config, request(8453, 42_161, "USDC", "USDC", "1100000"))

      for field <- @core_fillable do
        assert is_nil(Map.get(live, field)) == is_nil(Map.get(fixture, field)),
               "live drifted from the fixture on #{field}; re-capture the fixtures"
      end
    end
  end

  # -- Helpers --

  defp start_fake do
    {:ok, server} = FakeXochi.start_link()
    server
  end

  defp fake_quote(server, request) do
    {:ok, quote} = Xochi.get_quote(FakeXochi.config(server), request)
    quote
  end

  defp real_quote(fixture), do: fixture |> load() |> QuoteResponse.from_json()

  defp load(fixture) do
    [__DIR__, "..", "..", "..", "fixtures", "xochi", fixture]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  defp request(from, to, from_symbol, to_symbol, amount) do
    {:ok, from_token} = Assets.address(from, from_symbol)
    {:ok, to_token} = Assets.address(to, to_symbol)

    %QuoteRequest{
      wallet: @wallet,
      from_chain_id: from,
      to_chain_id: to,
      from_token: from_token,
      to_token: to_token,
      from_amount: amount,
      settlement_preference: "public"
    }
  end

  defp erc3009_message_fields(pull) do
    pull["message"] |> Map.keys() |> MapSet.new()
  end
end
