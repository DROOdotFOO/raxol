defmodule Raxol.ACP.Relay.LiveRelayTest do
  @moduledoc """
  Full EVM -> Tron transfer through the Relay rail against a real Riddler
  endpoint, funded by the on-chain deposit broadcaster.

  Each source token runs a read-only `/relay/quote` preflight (assert `can_fill`
  + a deposit address) before any broadcast, then `ExecuteRelayTransfer` quotes,
  authorizes the spend, and initiates execution; the `OnchainBroadcaster`
  broadcasts the ERC-20 deposit on the source chain; `PollRelayStatus` waits for
  `:completed`. Each settlement reports the deposit tx with an explorer link.

  Moves real funds: opt-in, excluded by default, compiled only when the required
  env is present.

      RELAY_LIVE_URL=https://riddler.axol.io \\
      RELAY_LIVE_TOKEN="$(op read 'op://Employee/Xochi staging RIDDLER_API_TOKEN/credential')" \\
      RELAY_LIVE_KEY=0x<funded source-chain private key> \\
      RELAY_LIVE_RPC=https://mainnet.base.org \\
        mix test --include live_relay test/raxol/acp/relay/live_relay_test.exs

  Multiple source tokens (each resolved per chain via `Raxol.Payments.Assets`)
  settle in one run via `RELAY_LIVE_TOKENS` (default `USDC`); the destination is
  always Tron. Defaults (Base -> Tron USDT, 0.10) are overridable via
  RELAY_LIVE_FROM_CHAIN, RELAY_LIVE_TOKENS, RELAY_LIVE_FROM_TOKEN (a raw origin
  address that overrides the token list), RELAY_LIVE_TO_TOKEN, RELAY_LIVE_TO_ADDRESS,
  RELAY_LIVE_AMOUNT.

  Or use the unified gate at the repo root: scripts/run_live_gates.sh --route relay
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

    alias Raxol.Payments.{Assets, Ledger, Relay, SpendingPolicy}
    alias Raxol.Payments.Relay.Schemas.QuoteRequest

    @tron 728_126_428

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

    test "agent completes an EVM->Tron transfer for each source token", %{
      context: context,
      from_chain: from_chain
    } do
      amount = System.get_env("RELAY_LIVE_AMOUNT", "0.10")
      to_address = System.get_env("RELAY_LIVE_TO_ADDRESS", @usdt_tron)
      cells = source_cells(from_chain)

      # Preflight every cell read-only first: a dead corridor aborts the run
      # before any deposit is broadcast.
      for {src_token, label} <- cells do
        assert {:ok, quote} = relay_quote(context, from_chain, src_token, amount, to_address)
        assert quote.can_fill, "#{label}: relay quote not fillable: #{inspect(quote)}"

        assert is_binary(quote.deposit_address),
               "#{label}: relay quote returned no deposit address"
      end

      for {src_token, label} <- cells do
        params = %{
          amount: amount,
          from_chain_id: from_chain,
          to_chain_id: @tron,
          from_token: src_token,
          to_token: System.get_env("RELAY_LIVE_TO_TOKEN", @usdt_tron),
          to_address: to_address
        }

        assert {:ok, transfer} = ExecuteRelayTransfer.call(params, context)
        assert transfer.funding == "broadcast"
        assert is_binary(transfer.deposit_tx_hash), "#{label}: no deposit tx broadcast"

        assert {:ok, status} =
                 PollRelayStatus.call(%{transfer_id: transfer.transfer_id}, context)

        assert status.status == "completed",
               "#{label}: transfer #{transfer.transfer_id} ended in #{status.status}, expected completed"

        report_relay(label, transfer, status, from_chain)
      end
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

    # A raw RELAY_LIVE_FROM_TOKEN overrides the token list with one custom cell;
    # otherwise resolve each RELAY_LIVE_TOKENS symbol to its origin address.
    defp source_cells(from_chain) do
      case System.get_env("RELAY_LIVE_FROM_TOKEN") do
        nil ->
          "RELAY_LIVE_TOKENS"
          |> System.get_env("USDC")
          |> parse_list()
          |> Enum.map(&resolve_src(from_chain, &1))

        addr ->
          [{addr, "#{from_chain}:custom->Tron"}]
      end
    end

    defp resolve_src(from_chain, token) do
      case Assets.address(from_chain, token) do
        {:ok, addr} -> {addr, "#{from_chain}:#{token}->Tron"}
        :error -> flunk("no #{token} address on chain #{from_chain}; set RELAY_LIVE_FROM_TOKEN")
      end
    end

    defp relay_quote(context, from_chain, src_token, amount, to_address) do
      decimals = Assets.decimals(from_chain, src_token)
      atomic = Integer.to_string(Assets.to_atomic(Decimal.new(amount), decimals))

      request = %QuoteRequest{
        transfer_id: "preflight_" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower),
        from_chain_id: from_chain,
        to_chain_id: @tron,
        from_token: src_token,
        to_token: System.get_env("RELAY_LIVE_TO_TOKEN", @usdt_tron),
        from_amount: atomic,
        from_address: LiveWallet.address(),
        to_address: to_address,
        slippage_bps: 50
      }

      Relay.get_quote(context.relay_config, request)
    end

    @explorers %{
      1 => "https://etherscan.io/tx/",
      10 => "https://optimistic.etherscan.io/tx/",
      137 => "https://polygonscan.com/tx/",
      8453 => "https://basescan.org/tx/",
      42_161 => "https://arbiscan.io/tx/"
    }

    defp report_relay(label, transfer, status, from_chain) do
      IO.puts(
        "[live_relay:#{label}] settled transfer=#{transfer.transfer_id} " <>
          "status=#{status.status} deposit=#{deposit_line(transfer.deposit_tx_hash, from_chain)}"
      )
    end

    defp deposit_line(nil, _chain), do: "(none)"
    defp deposit_line(hash, chain), do: Map.get(@explorers, chain, "") <> hash

    defp parse_list(spec), do: spec |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

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
