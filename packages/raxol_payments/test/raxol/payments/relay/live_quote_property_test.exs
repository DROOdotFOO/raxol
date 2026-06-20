defmodule Raxol.Payments.Relay.LiveQuotePropertyTest do
  @moduledoc """
  Contract property against a real Relay endpoint: a `/relay/quote` must never
  return a 5xx for any EVM <-> Tron route and amount. Every response should be a
  quote, an unfillable result, or a classified 4xx. A 5xx means an unhandled
  raise in the quote handler.

  Quotes are read-only, so this is safe to fuzz. Run after a Riddler deploy to
  confirm the relay 500 stays closed.

  Tagged `:live_property`, excluded by default, compiled only when RELAY_LIVE_URL
  is set.

      RELAY_LIVE_URL=https://riddler.axol.io \\
      RELAY_LIVE_TOKEN="$(op read 'op://Employee/Riddler Tron Relay API Token/password')" \\
        mix test --include live_property test/raxol/payments/relay/live_quote_property_test.exs
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :live_property
  @moduletag timeout: 300_000

  @tron 728_126_428
  @evm_usdc %{
    1 => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    8453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    10 => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    42_161 => "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
    137 => "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
  }
  @usdt_tron "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @evm_addr "0x6Bd36310CeC97dCB2499faFE285B48a6f8D0Fd13"
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  if System.get_env("RELAY_LIVE_URL") do
    alias Raxol.Payments.Relay
    alias Raxol.Payments.Relay.Schemas.QuoteRequest

    @config %{
      base_url: System.fetch_env!("RELAY_LIVE_URL"),
      auth_token: System.get_env("RELAY_LIVE_TOKEN", "")
    }
    @evm_chain_ids Map.keys(@evm_usdc)

    property "quote never returns 5xx across EVM <-> Tron routes and amounts" do
      check all(
              evm <- member_of(@evm_chain_ids),
              direction <- member_of([:evm_to_tron, :tron_to_evm]),
              amount <- map(integer(100_000..200_000_000), &Integer.to_string/1),
              max_runs: 40
            ) do
        request = build_request(evm, direction, amount)
        label = "#{request.from_chain_id}->#{request.to_chain_id} amount=#{amount}"
        assert_no_5xx(Relay.get_quote(@config, request), label)
      end
    end

    defp build_request(evm, :evm_to_tron, amount) do
      %QuoteRequest{
        transfer_id: gen_id(),
        from_chain_id: evm,
        to_chain_id: @tron,
        from_token: @evm_usdc[evm],
        to_token: @usdt_tron,
        from_amount: amount,
        from_address: @evm_addr,
        to_address: @tron_addr
      }
    end

    defp build_request(evm, :tron_to_evm, amount) do
      %QuoteRequest{
        transfer_id: gen_id(),
        from_chain_id: @tron,
        to_chain_id: evm,
        from_token: @usdt_tron,
        to_token: @evm_usdc[evm],
        from_amount: amount,
        from_address: @tron_addr,
        to_address: @evm_addr
      }
    end

    defp gen_id, do: "prop_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    defp assert_no_5xx(result, label) do
      case result do
        {:ok, _quote} ->
          :ok

        {:error, {:http, status, body}} ->
          assert status < 500, "5xx on #{label}: HTTP #{status} #{inspect(body)}"

        {:error, _transport} ->
          :ok
      end
    end
  end
end
