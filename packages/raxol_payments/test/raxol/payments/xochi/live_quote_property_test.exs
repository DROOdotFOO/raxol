defmodule Raxol.Payments.Xochi.LiveQuotePropertyTest do
  @moduledoc """
  Contract property against a real Xochi endpoint: a `/xochi/quote` must never
  return a 5xx for any supported route and amount. Every response should be a
  quote (200), `can_solve: false` (200), or a classified 4xx (e.g.
  `below_min_order_size`). A 5xx means an unhandled raise in the quote handler.

  Quotes are read-only and move no funds, so this is safe to fuzz against
  mainnet. Run it after a Riddler deploy to confirm the 500 class stays closed.

  Tagged `:live_property`, excluded by default, compiled only when XOCHI_LIVE_URL
  is set.

      XOCHI_LIVE_URL=https://riddler.axol.io \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi staging RIDDLER_API_TOKEN/credential')" \\
        mix test --include live_property test/raxol/payments/xochi/live_quote_property_test.exs
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  @moduletag :live_property
  @moduletag timeout: 300_000

  # chain id -> mainnet USDC contract
  @usdc %{
    1 => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    8453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    10 => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    42_161 => "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
    137 => "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359"
  }
  @wallet "0x6Bd36310CeC97dCB2499faFE285B48a6f8D0Fd13"

  if System.get_env("XOCHI_LIVE_URL") do
    alias Raxol.Payments.Protocols.Xochi
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    @config %{
      base_url: System.fetch_env!("XOCHI_LIVE_URL"),
      auth_token: System.get_env("XOCHI_LIVE_TOKEN", "")
    }
    @chain_ids Map.keys(@usdc)

    property "quote never returns 5xx across supported routes and amounts" do
      # Amounts span below-min (0.10), the 1 USDC floor, and larger.
      check all(
              from <- member_of(@chain_ids),
              to <- member_of(@chain_ids),
              from != to,
              amount <- map(integer(100_000..200_000_000), &Integer.to_string/1),
              max_runs: 40
            ) do
        request = %QuoteRequest{
          wallet: @wallet,
          from_chain_id: from,
          to_chain_id: to,
          from_token: @usdc[from],
          to_token: @usdc[to],
          from_amount: amount,
          settlement_preference: "public",
          slippage_bps: 50
        }

        assert_no_5xx(Xochi.get_quote(@config, request), "#{from}->#{to} amount=#{amount}")
      end
    end

    defp assert_no_5xx(result, label) do
      case result do
        {:ok, _quote} ->
          :ok

        {:error, {:http, status, body}} ->
          assert status < 500, "5xx on #{label}: HTTP #{status} #{inspect(body)}"

        {:error, _transport} ->
          # network/transport error is not a server 5xx
          :ok
      end
    end
  end
end
