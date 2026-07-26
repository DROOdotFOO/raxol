defmodule Raxol.ACP.JobSession.ClientSigningBoundaryPropertyTest do
  @moduledoc """
  The buy-side signing boundary: a spend the gate rejects must NEVER produce an
  on-chain write. Across randomized amounts and policy caps, whenever `buy/1`
  returns `{:rejected, ...}` for a spend reason, the `ProviderAdapter` recorded
  zero calls -- no `createJob`, no signature. This is the buyer analogue of the
  payments `SpendGate` signing-boundary property.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.ACP.{AssetToken, JobSession}
  alias Raxol.ACP.JobSession.Client
  alias Raxol.ACP.ProviderAdapter.Mock, as: Adapter
  alias Raxol.ACP.JobIdResolver.Mock, as: Resolver
  alias Raxol.Payments.{Ledger, SpendingPolicy}

  @chain 84_532
  @core "0x" <> String.duplicate("ab", 20)
  @provider "0x" <> String.duplicate("cd", 20)
  @buyer "0x" <> String.duplicate("ef", 20)

  setup do
    unless Process.whereis(JobSession.Registry) do
      {:ok, _} = Registry.start_link(keys: :unique, name: JobSession.Registry)
    end

    unless Process.whereis(JobSession.Supervisor) do
      start_supervised!(JobSession.Supervisor)
    end

    :ok
  end

  property "a gate-rejected buy signs nothing on-chain" do
    check all(
            per_request <- StreamData.integer(1..50),
            amount_usdc <- StreamData.integer(1..100),
            max_runs: 60
          ) do
      {:ok, ledger} =
        Ledger.start_link(table_name: :"sbp_ledger_#{System.unique_integer([:positive])}")

      adapter = Adapter.new()
      resolver = Resolver.new()
      :ok = Resolver.put_default(resolver, System.unique_integer([:positive]))

      # Bind a separate copy for the Decimal caps so `per_request` stays a clean
      # integer for the `<=` comparison below (avoids a spurious struct-compare
      # type warning from the flow analysis).
      cap = Decimal.new(per_request)

      policy = %SpendingPolicy{
        per_request_max: cap,
        session_max: cap,
        lifetime_max: cap,
        currency: "USDC"
      }

      client =
        Client.new(
          adapter: adapter,
          resolver: resolver,
          chain_id: @chain,
          acp_core_address: @core,
          buyer: @buyer,
          provider: @provider,
          amount: AssetToken.usdc(amount_usdc, @chain),
          ledger: ledger,
          policy: policy,
          agent_id: :sbp_buyer,
          checkpoint: Raxol.Payments.Checkpoint.ETS.new(),
          nonce: System.unique_integer([:positive])
        )

      result = Client.buy(client)

      case result do
        {:rejected, {:spend_rejected, _}} ->
          # The invariant under test: rejection implies no signature/write.
          assert Adapter.sent_calls(adapter) == []

        {:ok, _client, _} ->
          # Accepted (amount within the cap): exactly one write (createJob).
          assert length(Adapter.sent_calls(adapter)) == 1
      end

      GenServer.stop(ledger)
    end
  end
end
