defmodule Raxol.ACP.Relay.LiveRelayTest do
  @moduledoc """
  Full EVM -> Tron transfer through the Relay rail against a real Riddler
  endpoint, funded by the on-chain deposit broadcaster.

  `ExecuteRelayTransfer` quotes, authorizes the spend, and initiates execution;
  the `OnchainBroadcaster` broadcasts the ERC-20 deposit on the source chain;
  `PollRelayStatus` waits for `:completed`.

  Moves real funds: opt-in, excluded by default, compiled only when the required
  env is present.

      RELAY_LIVE_URL=https://riddler.axol.io \\
      RELAY_LIVE_TOKEN="$(op read 'op://Employee/Xochi staging RIDDLER_API_TOKEN/credential')" \\
      RELAY_LIVE_KEY=0x<funded source-chain private key> \\
      RELAY_LIVE_RPC=https://mainnet.base.org \\
        mix test --include live_relay test/raxol/acp/relay/live_relay_test.exs

  Defaults (Base USDC -> Tron USDT, 0.10 USDC) are overridable via
  RELAY_LIVE_FROM_CHAIN, RELAY_LIVE_FROM_TOKEN, RELAY_LIVE_TO_TOKEN,
  RELAY_LIVE_TO_ADDRESS, RELAY_LIVE_AMOUNT.
  """

  use ExUnit.Case, async: false

  @moduletag :live_relay
  @moduletag timeout: 300_000

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @usdt_tron "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  if System.get_env("RELAY_LIVE_URL") && System.get_env("RELAY_LIVE_KEY") &&
       System.get_env("RELAY_LIVE_RPC") do
    alias Raxol.ACP.ProviderAdapter.JSONRPC
    alias Raxol.ACP.Relay.OnchainBroadcaster

    alias Raxol.Payments.Actions.Payments.{
      ExecuteRelayTransfer,
      PollRelayStatus
    }

    alias Raxol.Payments.{Ledger, SpendingPolicy}

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "RELAY_LIVE_KEY"
    end

    setup do
      url = System.fetch_env!("RELAY_LIVE_URL")
      from_chain = env_int("RELAY_LIVE_FROM_CHAIN", 8453)

      provider =
        JSONRPC.new(
          chains: %{from_chain => System.fetch_env!("RELAY_LIVE_RPC")},
          private_key: decode_key(System.fetch_env!("RELAY_LIVE_KEY"))
        )

      OnchainBroadcaster.configure(provider)

      on_exit(fn ->
        Application.delete_env(:raxol_acp, :relay_broadcaster_provider)
      end)

      ledger = start_supervised!({Ledger, [name: nil]})
      host = url |> URI.parse() |> Map.get(:host)

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("5.00"),
        session_max: Decimal.new("20.00"),
        lifetime_max: Decimal.new("100.00"),
        session_window_ms: 3_600_000,
        approved_domains: [host]
      }

      context = %{
        wallet: LiveWallet,
        relay_config: %{
          base_url: url,
          auth_token: System.get_env("RELAY_LIVE_TOKEN", "")
        },
        broadcaster: OnchainBroadcaster,
        ledger: ledger,
        policy: policy,
        agent_id: :live_relay
      }

      {:ok, context: context, from_chain: from_chain}
    end

    test "agent completes an EVM->Tron transfer end-to-end", %{
      context: context,
      from_chain: from_chain
    } do
      params = %{
        amount: System.get_env("RELAY_LIVE_AMOUNT", "0.10"),
        from_chain_id: from_chain,
        to_chain_id: 728_126_428,
        from_token: System.get_env("RELAY_LIVE_FROM_TOKEN", @usdc_base),
        to_token: System.get_env("RELAY_LIVE_TO_TOKEN", @usdt_tron),
        to_address: System.get_env("RELAY_LIVE_TO_ADDRESS", @usdt_tron)
      }

      assert {:ok, transfer} = ExecuteRelayTransfer.call(params, context)
      assert transfer.funding == "broadcast"
      assert is_binary(transfer.deposit_tx_hash), "no deposit tx broadcast"

      assert {:ok, status} =
               PollRelayStatus.call(
                 %{transfer_id: transfer.transfer_id},
                 context
               )

      assert status.status == "completed",
             "live transfer #{transfer.transfer_id} ended in #{status.status}, expected completed"
    end

    test "a resumed run reuses the in-flight transfer without a second deposit", %{
      context: context,
      from_chain: from_chain
    } do
      # The crash-recovery path: a checkpoint store lets a re-run of the same
      # payment resume the dispatched transfer instead of minting a new id and
      # broadcasting a second deposit. One real deposit; the resume moves nothing.
      store = Raxol.Payments.Checkpoint.ETS.new()
      context = Map.merge(context, %{checkpoint: store, idempotency_key: "live-relay-resume"})

      params = %{
        amount: System.get_env("RELAY_LIVE_AMOUNT", "0.10"),
        from_chain_id: from_chain,
        to_chain_id: 728_126_428,
        from_token: System.get_env("RELAY_LIVE_FROM_TOKEN", @usdc_base),
        to_token: System.get_env("RELAY_LIVE_TO_TOKEN", @usdt_tron),
        to_address: System.get_env("RELAY_LIVE_TO_ADDRESS", @usdt_tron)
      }

      assert {:ok, transfer} = ExecuteRelayTransfer.call(params, context)
      assert transfer.funding == "broadcast"
      assert is_binary(transfer.deposit_tx_hash), "no deposit tx broadcast"
      charged = lifetime(context)

      # The agent "restarts" and runs the same payment; recovery resumes it.
      assert {:ok, resumed} = ExecuteRelayTransfer.call(params, context)

      assert resumed.transfer_id == transfer.transfer_id,
             "resume minted a new transfer #{resumed.transfer_id} instead of reusing #{transfer.transfer_id}"

      assert Decimal.equal?(lifetime(context), charged),
             "resume charged the ledger a second time"

      assert {:ok, status} =
               PollRelayStatus.call(%{transfer_id: transfer.transfer_id}, context)

      assert status.status == "completed",
             "live transfer #{transfer.transfer_id} ended in #{status.status}, expected completed"
    end

    defp lifetime(context) do
      Ledger.get_totals(context.ledger, context.agent_id, context.policy).lifetime
    end

    defp env_int(name, default) do
      case System.get_env(name) do
        nil -> default
        val -> String.to_integer(val)
      end
    end

    defp decode_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
    defp decode_key(hex), do: Base.decode16!(hex, case: :mixed)
  end
end
