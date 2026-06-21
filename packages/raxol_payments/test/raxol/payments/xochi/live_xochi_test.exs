defmodule Raxol.Payments.Xochi.LiveXochiTest do
  @moduledoc """
  The full agent crosschain payment lifecycle against a real Xochi endpoint:
  `ExecuteXochiIntent` quotes, authorizes the spend, signs, and submits the
  intent; `PollXochiStatus` waits for `:completed`.

  Moves real funds. The endpoint is the Xochi worker (`api.xochi.fi`, or
  `api-stg.xochi.fi` for staging), which serves the `/api/intent/*` routes this
  client calls, applies trust-tier fees, and calls the Riddler solver internally.
  The token is the Xochi worker bearer token.

  Defaults are mainnet Base -> Arbitrum USDC at 10 USDC. Settlement defaults to
  `public`; set `XOCHI_LIVE_SETTLEMENT=stealth` with `XOCHI_LIVE_RECIPIENT_META`
  to exercise the private path. The worker returns `can_solve: false` for an
  amount the solver cannot price, so the test asserts on `can_solve`.

  Tagged `:live_xochi` and excluded by default. Compiled only when the required
  env is present, so opting in without it yields no tests.

      XOCHI_LIVE_URL=https://api.xochi.fi \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi worker token/credential')" \\
      XOCHI_LIVE_KEY=0x<funded Base mainnet private key> \\
        mix test --include live_xochi test/raxol/payments/xochi/live_xochi_test.exs

  Or use the runner: examples/run_live_xochi_gate.sh

  Overrides: XOCHI_LIVE_FROM_CHAIN, XOCHI_LIVE_TO_CHAIN, XOCHI_LIVE_FROM_TOKEN,
  XOCHI_LIVE_TO_TOKEN, XOCHI_LIVE_AMOUNT, XOCHI_LIVE_SETTLEMENT,
  XOCHI_LIVE_RECIPIENT_META.
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
        per_request_max: Decimal.new("50.00"),
        session_max: Decimal.new("100.00"),
        lifetime_max: Decimal.new("500.00"),
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

    test "agent completes a crosschain payment end-to-end", %{context: context} do
      params =
        %{
          amount: System.get_env("XOCHI_LIVE_AMOUNT", "10.00"),
          from_chain_id: env_int("XOCHI_LIVE_FROM_CHAIN", 8453),
          to_chain_id: env_int("XOCHI_LIVE_TO_CHAIN", 42_161),
          from_token:
            System.get_env("XOCHI_LIVE_FROM_TOKEN", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
          to_token:
            System.get_env("XOCHI_LIVE_TO_TOKEN", "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
          settlement: System.get_env("XOCHI_LIVE_SETTLEMENT", "public")
        }
        |> maybe_put_recipient()

      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      assert is_binary(intent.intent_id)

      assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, context)
      assert status.terminal == true

      assert status.status == "completed",
             "live intent #{intent.intent_id} ended in #{status.status}, expected completed"
    end

    test "a resumed run reuses the in-flight intent without a second signature", %{
      context: context
    } do
      # The crash-recovery path: an idempotency checkpoint lets a re-run of the
      # same payment resume the dispatched intent instead of quoting and signing
      # again. One real settlement; the second call must not move funds.
      store = Raxol.Payments.Checkpoint.ETS.new()
      context = Map.merge(context, %{checkpoint: store, idempotency_key: "live-resume"})

      params =
        %{
          amount: System.get_env("XOCHI_LIVE_AMOUNT", "10.00"),
          from_chain_id: env_int("XOCHI_LIVE_FROM_CHAIN", 8453),
          to_chain_id: env_int("XOCHI_LIVE_TO_CHAIN", 42_161),
          from_token:
            System.get_env("XOCHI_LIVE_FROM_TOKEN", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
          to_token:
            System.get_env("XOCHI_LIVE_TO_TOKEN", "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
          settlement: System.get_env("XOCHI_LIVE_SETTLEMENT", "public")
        }
        |> maybe_put_recipient()

      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      assert is_binary(intent.intent_id)
      charged = lifetime(context)

      # The agent "restarts" and runs the same payment; recovery resumes it.
      assert {:ok, resumed} = ExecuteXochiIntent.call(params, context)

      assert resumed.intent_id == intent.intent_id,
             "resume signed a new intent #{resumed.intent_id} instead of reusing #{intent.intent_id}"

      assert Decimal.equal?(lifetime(context), charged),
             "resume charged the ledger a second time"

      assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, context)
      assert status.terminal == true

      assert status.status == "completed",
             "live intent #{intent.intent_id} ended in #{status.status}, expected completed"
    end

    defp lifetime(context) do
      Ledger.get_totals(context.ledger, context.agent_id, context.policy).lifetime
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
