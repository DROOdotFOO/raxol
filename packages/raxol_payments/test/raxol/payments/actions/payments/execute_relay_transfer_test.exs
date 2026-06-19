defmodule Raxol.Payments.Actions.Payments.ExecuteRelayTransferTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.{ExecuteRelayTransfer, PollRelayStatus}
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}

  @tron 728_126_428
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defmodule SpyWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_d, _t, _m), do: {:ok, <<7::size(520)>>}
    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  defp config do
    %{
      base_url: "https://relay.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp policy(overrides \\ %{}) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        lifetime_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["relay.test"]
      },
      overrides
    )
  end

  defp base_params(overrides) do
    Map.merge(
      %{
        amount: "0.50",
        from_chain_id: 8453,
        to_chain_id: @tron,
        from_token: @usdc_base,
        to_token: @usdt_trc20,
        to_address: @tron_addr,
        settlement: "public"
      },
      overrides
    )
  end

  defp stub_quote_and_execute do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/relay/quote" ->
          Req.Test.json(conn, %{
            "transfer_id" => "t_1",
            "quote_id" => "q_1",
            "can_fill" => true,
            "to_amount" => "499000",
            "deposit_address" => "0xdeposit"
          })

        "/relay/execute" ->
          Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
      end
    end)
  end

  defp ctx(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: SpyWallet,
        relay_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      },
      overrides
    )
  end

  describe "happy path" do
    test "quotes, gates, executes, returns the deposit address and status" do
      stub_quote_and_execute()

      assert {:ok, result} = ExecuteRelayTransfer.run(base_params(%{}), ctx())
      assert result.transfer_id == "t_1"
      assert result.deposit_address == "0xdeposit"
      assert result.status == "pending"
      assert result.to_amount == "499000"
      assert result.warnings == []
    end
  end

  describe "stealth downgrade on Tron" do
    test "downgrades a stealth request to public with a warning" do
      stub_quote_and_execute()

      assert {:ok, result} =
               ExecuteRelayTransfer.run(base_params(%{settlement: "stealth"}), ctx())

      assert [%{code: :stealth_unavailable_on_tron}] = result.warnings
      # The transfer still proceeded.
      assert result.status == "pending"
    end
  end

  describe "validation and routing" do
    test "rejects an EVM address on the Tron leg before any network call" do
      params = base_params(%{to_address: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{reason: :invalid_request}} =
               ExecuteRelayTransfer.run(params, ctx())
    end

    test "rejects a route with no Tron leg" do
      params =
        base_params(%{to_chain_id: 42_161, to_address: "0x" <> String.duplicate("ab", 20)})

      assert {:error, %Failure{reason: :route_unsupported}} =
               ExecuteRelayTransfer.run(params, ctx())
    end
  end

  describe "spend gate" do
    test "denies over per_request and does not execute" do
      stub_quote_and_execute()

      assert {:error, %Failure{reason: :over_budget}} =
               ExecuteRelayTransfer.run(
                 base_params(%{}),
                 ctx(%{policy: policy(%{per_request_max: Decimal.new("0.10")})})
               )
    end
  end

  describe "PollRelayStatus" do
    test "returns a completed transfer" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "transfer_id" => "t_1",
          "status" => "completed",
          "tx_hash" => "abc123"
        })
      end)

      assert {:ok, result} = PollRelayStatus.run(%{transfer_id: "t_1"}, %{relay_config: config()})
      assert result.status == "completed"
      assert result.terminal == true
      assert result.tx_hash == "abc123"
      assert result.settlement_speed == "within_budget"
    end

    test "surfaces a failed transfer as an error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "transfer_id" => "t_2",
          "status" => "failed",
          "error" => "bridge unavailable"
        })
      end)

      assert {:error, %Failure{}} =
               PollRelayStatus.run(%{transfer_id: "t_2"}, %{relay_config: config()})
    end
  end
end
