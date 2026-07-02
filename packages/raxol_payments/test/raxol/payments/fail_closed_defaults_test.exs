defmodule Raxol.Payments.FailClosedDefaultsTest do
  @moduledoc """
  In a deployed release the spend gate and settlement path fail closed by
  default: a missing SpendingPolicy or a missing idempotency checkpoint stops
  the payment rather than defaulting to unlimited spend / double-settle risk.
  Development and tests stay permissive (the rest of the suite depends on that).
  """

  # async: false -- toggles the process-global production flag.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.Actions.SpendGate
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defmodule Wallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_d, _t, _m), do: {:ok, <<7::size(520)>>}
    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  setup do
    on_exit(fn -> Application.delete_env(:raxol_payments, :deployment) end)
    :ok
  end

  defp production, do: Application.put_env(:raxol_payments, :deployment, :production)
  defp development, do: Application.put_env(:raxol_payments, :deployment, :development)

  describe "require_policy default" do
    test "production fails closed when no SpendingPolicy is in context" do
      production()
      ctx = %{ledger: start_supervised!({Ledger, [name: nil]}), agent_id: "a1"}

      assert {:error, {:policy_required, :no_spending_policy}} =
               SpendGate.authorize(ctx, Decimal.new("0.50"), target: {:domain, "x.test"})
    end

    test "development treats a missing policy as an unrestricted no-op" do
      development()
      ctx = %{ledger: start_supervised!({Ledger, [name: nil]}), agent_id: "a1"}

      assert :ok =
               SpendGate.authorize(ctx, Decimal.new("0.50"), target: {:domain, "x.test"})
    end
  end

  describe "require_checkpoint default" do
    # No Req stub: the checkpoint guard must trip before any network or signature.
    test "production fails closed when no checkpoint store is in context" do
      production()

      assert {:error, %Failure{reason: :checkpoint_required, retryable?: false}} =
               ExecuteXochiIntent.run(xochi_params(), xochi_ctx())
    end

    test "development proceeds without a checkpoint (unchecked settlement)" do
      development()

      # Reaching the quote endpoint at all proves the checkpoint guard did not
      # trip. The stub declines to solve, so the run ends on a quote-level
      # failure, never :checkpoint_required.
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"canSolve" => false, "error" => "no route"})
      end)

      result = ExecuteXochiIntent.run(xochi_params(), xochi_ctx())
      assert {:error, %Failure{} = failure} = result
      refute failure.reason == :checkpoint_required
    end
  end

  defp xochi_ctx do
    %{
      wallet: Wallet,
      xochi_config: %{
        base_url: "https://xochi.test",
        auth_token: "token",
        req_options: [plug: {Req.Test, __MODULE__}]
      },
      ledger: start_supervised!({Ledger, [name: nil]}),
      policy: %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        lifetime_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["xochi.test"]
      },
      agent_id: "a1"
    }
  end

  defp xochi_params do
    %{
      amount: "0.50",
      from_chain_id: 8453,
      to_chain_id: 42_161,
      from_token: @usdc_base,
      to_token: @usdc_base,
      settlement: "stealth",
      recipient_meta_address: recipient_meta()
    }
  end

  defp recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end
end
