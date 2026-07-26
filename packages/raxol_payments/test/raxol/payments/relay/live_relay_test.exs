defmodule Raxol.Payments.Relay.LiveRelayTest do
  @moduledoc """
  Read-only live check of the Tron Relay client against a real Riddler endpoint.

  Requests a `/relay/quote` and asserts the route returns a fillable quote with a
  deposit address. A quote moves no funds, so it is safe against mainnet. The
  full EVM->Tron settlement, which broadcasts an on-chain deposit, is a raxol_acp
  `:live_relay` test (broadcasting needs the EVM transaction stack in that
  package).

  Tagged `:live_relay`, excluded by default, and compiled only when the endpoint
  env is present. The endpoint is the Riddler solver serving the `/relay/*`
  routes (the Xochi worker at api*.xochi.fi serves `/api/intent/*`).

      RELAY_LIVE_URL=https://riddler.axol.io \\
      RELAY_LIVE_TOKEN="$(op read 'op://Employee/Xochi staging RIDDLER_API_TOKEN/credential')" \\
      RELAY_LIVE_FROM_ADDRESS=0x<your Base address> \\
        mix test --include live_relay test/raxol/payments/relay/live_relay_test.exs

  Or use the unified gate at the repo root: scripts/run_live_gates.sh --route relay

  Defaults (Base USDC -> Tron USDT) are overridable via RELAY_LIVE_FROM_CHAIN,
  RELAY_LIVE_TO_CHAIN, RELAY_LIVE_FROM_TOKEN, RELAY_LIVE_TO_TOKEN,
  RELAY_LIVE_AMOUNT, RELAY_LIVE_TO_ADDRESS.
  """

  use ExUnit.Case, async: false

  @moduletag :live_relay
  @moduletag timeout: 120_000

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @usdt_tron "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_recipient "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  if System.get_env("RELAY_LIVE_URL") do
    alias Raxol.Payments.Relay
    alias Raxol.Payments.Relay.Schemas.QuoteRequest

    test "relay quote endpoint is reachable and returns a fillable quote" do
      config = %{
        base_url: System.fetch_env!("RELAY_LIVE_URL"),
        auth_token: System.get_env("RELAY_LIVE_TOKEN", "")
      }

      request = %QuoteRequest{
        transfer_id:
          "live_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower),
        from_chain_id: env_int("RELAY_LIVE_FROM_CHAIN", 8453),
        to_chain_id: env_int("RELAY_LIVE_TO_CHAIN", 728_126_428),
        from_token: System.get_env("RELAY_LIVE_FROM_TOKEN", @usdc_base),
        to_token: System.get_env("RELAY_LIVE_TO_TOKEN", @usdt_tron),
        from_amount: System.get_env("RELAY_LIVE_AMOUNT", "100000"),
        from_address: System.fetch_env!("RELAY_LIVE_FROM_ADDRESS"),
        to_address: System.get_env("RELAY_LIVE_TO_ADDRESS", @tron_recipient)
      }

      assert {:ok, quote} = Relay.get_quote(config, request),
             "relay quote request failed against #{config.base_url}"

      assert quote.can_fill,
             "relay quote not fillable: #{inspect(Map.take(quote, [:can_fill, :metadata]))}"

      assert is_binary(quote.deposit_address),
             "relay quote returned no deposit address: #{inspect(quote)}"
    end

    defp env_int(name, default) do
      case System.get_env(name) do
        nil -> default
        val -> String.to_integer(val)
      end
    end
  end
end
