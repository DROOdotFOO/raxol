# Preflight: Pay-Stack Launch Verification
#
# Single-request walkthrough of the full payment stack: wallet ->
# SpendingPolicy -> Ledger -> AutoPay -> :on_confirm -> Req. Run this
# against the local echo server before pointing the same wiring at any
# real mainnet endpoint -- if it doesn't fly here, it won't fly there.
#
# Defaults target Raxol.Payments.EchoServer so you can rehearse end-to-end
# without spending real money. Swap the URL and the wallet backend for
# the actual launch.
#
# Usage (from packages/raxol_payments/):
#
#   # Terminal A: start the echo server
#   mix raxol_payments.echo --port 4002
#
#   # Terminal B: run this script against it
#   mix run examples/preflight.exs
#
# Environment:
#
#   PREFLIGHT_TARGET_URL   default http://localhost:4002/anything
#   PREFLIGHT_WALLET_KEY   private key (0x-prefixed hex). Required.
#                          For a real launch, switch to Raxol.Payments.Wallets.Op
#                          and remove this env var entirely.
#   PREFLIGHT_AUTO_APPROVE if "true", skip the terminal prompt and approve
#                          any over-threshold payment. Use only during rehearsal.
#
# Units:
#   Amounts in this policy are in human-decimal USDC ($1.00 = Decimal.new("1.00")).
#   `Raxol.Payments.Protocols.X402.amount/1` normalizes the atomic-unit
#   `maxAmountRequired` from the challenge against the asset's decimals
#   (via `Raxol.Payments.Assets`) before the gate sees it, so the policy
#   reads like dollars and not like raw token units.

Logger.configure(level: :warning)

defmodule Preflight do
  alias Raxol.Payments.{Confirm, Ledger, Req.AutoPay, SpendingPolicy}

  def run do
    url =
      System.get_env("PREFLIGHT_TARGET_URL", "http://localhost:4002/anything")

    wallet = wallet_module()
    policy = production_policy()
    confirm = confirm_callback()

    {:ok, ledger} = Ledger.start_link(table_name: :preflight_ledger)
    _watcher = Ledger.tail(ledger, agent_id: :preflight)

    IO.puts("\n== preflight ==")
    IO.puts("target:   #{url}")
    IO.puts("wallet:   #{wallet}  (address: #{wallet.address()})")

    IO.puts(
      "policy:   per_request=#{policy.per_request_max}  " <>
        "session=#{policy.session_max}  lifetime=#{policy.lifetime_max}"
    )

    IO.puts("approved: #{inspect(policy.approved_domains)}")
    IO.puts("confirm@: #{policy.require_confirmation_above}")
    IO.puts("")

    req =
      Req.new(url: url, retry: false)
      |> AutoPay.attach(
        wallet: wallet,
        ledger: ledger,
        policy: policy,
        agent_id: :preflight,
        on_confirm: confirm
      )

    case Req.get(req) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        IO.puts("\n[ok] payment accepted")
        IO.inspect(body, label: "response")

      {:ok, %Req.Response{status: status, body: body}} ->
        IO.puts("\n[denied] status=#{status}")
        IO.inspect(body, label: "response")

      {:error, reason} ->
        IO.puts("\n[error] #{inspect(reason)}")
    end

    # Give the ledger tail a moment to flush before we exit.
    Process.sleep(50)
    :ok
  end

  # ---- policy ----

  defp production_policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("10.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      currency: "USDC",
      # For a real launch, lock this down to the exact target host(s).
      approved_domains: ["localhost", "example.com"],
      require_confirmation_above: Decimal.new("5.00")
    }
  end

  # ---- wallet ----

  # For mainnet, replace this entire function with:
  #
  #     defp wallet_module, do: Raxol.Payments.Wallets.Op
  #
  # and make sure the 1Password item exists. Never check keys into env vars
  # or scripts.
  defp wallet_module do
    case System.get_env("PREFLIGHT_WALLET_KEY") do
      nil ->
        IO.puts(
          :stderr,
          "[warn] PREFLIGHT_WALLET_KEY not set; generating ephemeral dev key"
        )

        key = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
        System.put_env("PREFLIGHT_WALLET_KEY", key)
        build_env_wallet()

      _set ->
        build_env_wallet()
    end
  end

  defp build_env_wallet do
    defmodule EphemeralWallet do
      use Raxol.Payments.Wallets.Env, env_var: "PREFLIGHT_WALLET_KEY"
    end

    EphemeralWallet
  end

  # ---- confirm ----

  defp confirm_callback do
    case System.get_env("PREFLIGHT_AUTO_APPROVE") do
      "true" -> Confirm.always(:approve)
      _ -> Confirm.terminal()
    end
  end
end

Preflight.run()
