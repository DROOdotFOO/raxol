defmodule Raxol.Payments.XochiCheckpointPropertyTest do
  @moduledoc """
  Property for the fail-closed idempotency gate on `ExecuteXochiIntent`.

  The invariant: when a deployment requires a durable checkpoint
  (`require_checkpoint: true`) and none is configured, NO payment -- whatever
  its settlement type, chain pair, token, or amount -- releases a wallet
  signature or reserves budget. The gate must be uniform across the whole
  payment space; a refactor that gates only some shapes (say, stealth but not
  public) would reopen the crash-retry double-settle window for the rest.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @usdc_arb "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"

  # A wallet that reports if it is ever asked to sign; the property asserts it
  # is not, so the fail-closed gate must trip before any signature.
  defmodule SpyWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_d, _t, _m), do: send(self(), :wallet_signed) && {:ok, <<7::520>>}
    def sign_message(_), do: {:ok, <<7::520>>}
    def sign_hash(_), do: {:ok, <<7::520>>}
  end

  defp recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  defp valid_params do
    gen all(
          cents <- integer(1..500),
          settlement <- member_of(["public", "stealth"]),
          to_chain <- member_of([8453, 42_161])
        ) do
      base = %{
        amount: Decimal.to_string(Decimal.div(Decimal.new(cents), 100)),
        from_chain_id: 8453,
        to_chain_id: to_chain,
        from_token: @usdc_base,
        to_token: if(to_chain == 8453, do: @usdc_base, else: @usdc_arb),
        settlement: settlement
      }

      if settlement == "stealth",
        do: Map.put(base, :recipient_meta_address, recipient_meta()),
        else: base
    end
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("100.00"),
      session_max: Decimal.new("100.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["xochi.test"]
    }
  end

  property "require_checkpoint with no store fails closed for every valid payment, never signing" do
    check all(params <- valid_params()) do
      ledger =
        start_supervised!(
          Supervisor.child_spec({Ledger, [name: nil]},
            id: {:l, System.unique_integer([:positive])}
          )
        )

      ctx = %{
        wallet: SpyWallet,
        xochi_config: %{base_url: "https://xochi.test", auth_token: "t"},
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        require_checkpoint: true
      }

      assert {:error, %Failure{reason: :checkpoint_required}} =
               ExecuteXochiIntent.run(params, ctx)

      # No signature released, no budget reserved -- uniformly, for any shape.
      refute_received :wallet_signed
      assert Ledger.get_history(ledger, "a1") == []
    end
  end
end
