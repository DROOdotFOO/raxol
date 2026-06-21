defmodule Raxol.Payments.Xochi.LiveSmokeTest do
  @moduledoc """
  Fast, fund-free liveness checks against a real Xochi worker. Confirms the
  repointed `/api/intent/*` routes reach the worker and that the live auth modes
  behave, without moving funds (quote-only). Complements `LiveXochiTest`, which
  drives the full fund-moving lifecycle.

  Two auth modes work against prod today, and both are smoked here:

    * x402 Guest (live on prod) -- an anonymous quote is gated, returning the
      worker's "authenticate or pay" boundary (401 Member / 402 Guest x402
      invite). Needs only `XOCHI_LIVE_URL`: no token, no key, no funds.
    * Member (Bearer JWT) -- a $1 quote on a known-fillable corridor returns
      `can_solve: true` with signable snake_case fields. Needs `XOCHI_LIVE_TOKEN`.

  Mandate auth is not smoked: worker-side delegation verification is still on
  Xochi's roadmap (see XOCHI_HANDOVER.md / xochi/docs/planning/agent-auth.md).

  Tagged `:live_xochi` (excluded unless `XOCHI_LIVE_URL` is set, per
  test_helper.exs) and compiled only when `XOCHI_LIVE_URL` is present, so opting
  in without it yields no tests.

      # x402 Guest gate only (no secrets, no funds):
      XOCHI_LIVE_URL=https://api.xochi.fi \\
        mix test test/raxol/payments/xochi/live_smoke_test.exs

      # Add the Member quote round-trip:
      XOCHI_LIVE_URL=https://api.xochi.fi \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi worker token/credential')" \\
        mix test test/raxol/payments/xochi/live_smoke_test.exs

  The corridor defaults to a $1 Base -> Optimism USDC swap (the handover's first
  verified $1 fill). Override with `XOCHI_LIVE_SMOKE_{FROM_CHAIN,TO_CHAIN,
  FROM_TOKEN,TO_TOKEN,AMOUNT,WALLET}`.
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi
  @moduletag timeout: 60_000

  if System.get_env("XOCHI_LIVE_URL") do
    alias Raxol.Payments.Xochi.Client
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    # Base -> Optimism USDC, 1 USDC in atomic units (6 decimals). Verified to fill
    # at $1 on prod 2026-06-21 (XOCHI_HANDOVER.md). All values are overridable.
    @defaults %{
      from_chain: 8453,
      to_chain: 10,
      from_token: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      to_token: "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85",
      amount: "1000000",
      wallet: "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"
    }

    setup do
      {:ok, url: System.fetch_env!("XOCHI_LIVE_URL"), request: sample_request()}
    end

    test "the worker is reachable and gates an anonymous quote", %{url: url, request: request} do
      config = %{base_url: url, auth: :none}

      case Client.get_quote(config, request) do
        {:error, {:http, status, _body}} ->
          assert status in [401, 402],
                 "anonymous quote returned HTTP #{status}; expected an auth gate " <>
                   "(401 Member / 402 Guest x402 invite)"

        {:ok, quote} ->
          flunk(
            "anonymous quote was served without auth (can_solve=#{inspect(quote.can_solve)}); " <>
              "the worker's quote auth boundary may be open"
          )

        {:error, reason} ->
          flunk("could not reach the Xochi worker at #{url}: #{inspect(reason)}")
      end
    end

    if System.get_env("XOCHI_LIVE_TOKEN") do
      test "a Member quote fills the corridor with signable snake_case fields", %{
        url: url,
        request: request
      } do
        config = %{base_url: url, auth: {:member, System.fetch_env!("XOCHI_LIVE_TOKEN")}}

        assert {:ok, quote} = Client.get_quote(config, request)

        assert quote.can_solve == true,
               "Member quote could not solve corridor #{request.from_chain_id}->" <>
                 "#{request.to_chain_id} at #{request.from_amount}: #{inspect(quote.error)}"

        # snake_case round-trip: the worker emits snake_case + `eip712`, parsed
        # into these fields. All must be present for the agent to sign + execute.
        assert is_binary(quote.intent_id)
        assert is_binary(quote.quote_id)
        assert is_binary(quote.to_amount)
        refute is_nil(quote.eip712_data), "quote is missing eip712 typed data to sign"
      end
    end

    defp sample_request do
      %QuoteRequest{
        wallet: env("XOCHI_LIVE_SMOKE_WALLET", @defaults.wallet),
        from_chain_id: env_int("XOCHI_LIVE_SMOKE_FROM_CHAIN", @defaults.from_chain),
        to_chain_id: env_int("XOCHI_LIVE_SMOKE_TO_CHAIN", @defaults.to_chain),
        from_token: env("XOCHI_LIVE_SMOKE_FROM_TOKEN", @defaults.from_token),
        to_token: env("XOCHI_LIVE_SMOKE_TO_TOKEN", @defaults.to_token),
        from_amount: env("XOCHI_LIVE_SMOKE_AMOUNT", @defaults.amount),
        settlement_preference: "public"
      }
    end

    defp env(name, default), do: System.get_env(name) || default

    defp env_int(name, default) do
      case System.get_env(name) do
        nil -> default
        val -> String.to_integer(val)
      end
    end
  end
end
