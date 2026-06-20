defmodule Raxol.Payments.Xochi.LiveXochiTest do
  @moduledoc """
  Launch gate: the full agent crosschain stealth payment lifecycle against a
  real (testnet) Xochi endpoint.

  This is the live-validated evidence that the agent path works end to end:
  `ExecuteXochiIntent` quotes, authorizes the spend, signs, and submits a real
  intent; `PollXochiStatus` waits for it to reach `:completed`.

  Tagged `:live_xochi` and excluded by default. The test is only compiled when
  the required env is present, so opting in without it yields no tests rather
  than a spurious failure.

  The endpoint is the Riddler solver, which serves the `/xochi/*` routes this
  client calls (the Xochi worker at api*.xochi.fi serves `/api/intent/*` and is
  not the right target). The token is the staging-scoped Riddler bearer token.

      XOCHI_LIVE_URL=https://riddler.axol.io \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi staging RIDDLER_API_TOKEN/credential')" \\
      XOCHI_LIVE_KEY=0x<funded Base-Sepolia private key> \\
        mix test --include live_xochi test/raxol/payments/xochi/live_xochi_test.exs

  Or use the runner: examples/run_live_xochi_gate.sh

  Optional overrides (Base Sepolia -> Arbitrum Sepolia USDC defaults otherwise):
  XOCHI_LIVE_FROM_CHAIN, XOCHI_LIVE_TO_CHAIN, XOCHI_LIVE_FROM_TOKEN,
  XOCHI_LIVE_TO_TOKEN, XOCHI_LIVE_AMOUNT, XOCHI_LIVE_RECIPIENT_META.
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi
  # Live settlement can take longer than the ExUnit default.
  @moduletag timeout: 300_000

  if System.get_env("XOCHI_LIVE_URL") && System.get_env("XOCHI_LIVE_KEY") do
    alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
    alias Raxol.Payments.{Ledger, SpendingPolicy}

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "XOCHI_LIVE_KEY"
    end

    setup do
      url = System.fetch_env!("XOCHI_LIVE_URL")
      host = url |> URI.parse() |> Map.get(:host)
      ledger = start_supervised!({Ledger, [name: nil]})

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("5.00"),
        session_max: Decimal.new("20.00"),
        lifetime_max: Decimal.new("100.00"),
        session_window_ms: 3_600_000,
        approved_domains: [host]
      }

      context = %{
        wallet: LiveWallet,
        xochi_config: %{base_url: url, auth_token: System.get_env("XOCHI_LIVE_TOKEN", "")},
        ledger: ledger,
        policy: policy,
        agent_id: :live_gate
      }

      {:ok, context: context}
    end

    test "agent completes a crosschain stealth payment end-to-end", %{context: context} do
      params =
        %{
          amount: System.get_env("XOCHI_LIVE_AMOUNT", "0.10"),
          from_chain_id: env_int("XOCHI_LIVE_FROM_CHAIN", 84_532),
          to_chain_id: env_int("XOCHI_LIVE_TO_CHAIN", 421_614),
          from_token:
            System.get_env("XOCHI_LIVE_FROM_TOKEN", "0x036CbD53842c5426634e7929541eC2318f3dCF7e"),
          to_token:
            System.get_env("XOCHI_LIVE_TO_TOKEN", "0x036CbD53842c5426634e7929541eC2318f3dCF7e"),
          settlement: "stealth"
        }
        |> maybe_put_recipient()

      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      assert is_binary(intent.intent_id)

      assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, context)
      assert status.terminal == true

      assert status.status == "completed",
             "live intent #{intent.intent_id} ended in #{status.status}, expected completed"
    end

    defp maybe_put_recipient(params) do
      case System.get_env("XOCHI_LIVE_RECIPIENT_META") do
        nil -> params
        meta -> Map.put(params, :recipient_meta_address, meta)
      end
    end

    defp env_int(name, default) do
      case System.get_env(name) do
        nil -> default
        val -> String.to_integer(val)
      end
    end
  end
end
