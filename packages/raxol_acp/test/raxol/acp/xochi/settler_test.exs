defmodule Raxol.ACP.Xochi.SettlerTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Xochi.Settler

  @wallet "0xfeedfacefeedfacefeedfacefeedfacefeedface"
  @src_token "0x" <> String.duplicate("11", 20)
  @dst_token "0x" <> String.duplicate("22", 20)
  @destination "0x" <> String.duplicate("33", 20)

  defp valid_requirement do
    %{
      "src_chain_id" => 8453,
      "dst_chain_id" => 10,
      "src_token" => @src_token,
      "dst_token" => @dst_token,
      "amount_atomic" => "1000000",
      "destination" => @destination,
      "slippage_bps" => 50,
      "settlement_preference" => "public"
    }
  end

  defp settle_args(req) do
    %{
      requirement: req,
      transfer_amount_atomic: 1_000_000,
      destination: @destination,
      xochi_config: %{base_url: "http://stub", auth_token: "stub"},
      xochi_wallet: nil
    }
  end

  describe "build/1" do
    test "raises when required option missing" do
      assert_raise KeyError, fn -> Settler.build(xochi_config: %{}, xochi_wallet: nil) end
    end

    test "returns a function arity-1" do
      f =
        Settler.build(
          wallet_address: @wallet,
          xochi_config: %{base_url: "http://stub"},
          xochi_wallet: nil
        )

      assert is_function(f, 1)
    end
  end

  describe "settle_fn invocation (validation only)" do
    # The settler's first job is to build a valid QuoteRequest from the
    # settle args. If the requirement is malformed, we expect an early
    # error before ever talking to Xochi. The "real" Xochi.transfer call
    # is exercised by the SolverAgent live test path; here we verify the
    # validation layer.

    test "rejects an invalid src_token in the requirement" do
      settler =
        Settler.build(
          wallet_address: @wallet,
          xochi_config: %{base_url: "http://stub"},
          xochi_wallet: nil
        )

      bad_req = %{valid_requirement() | "src_token" => "not-an-address"}

      assert {:error, {:invalid_from_token, _}} = settler.(settle_args(bad_req))
    end

    test "rejects a non-positive chain id" do
      settler =
        Settler.build(
          wallet_address: @wallet,
          xochi_config: %{base_url: "http://stub"},
          xochi_wallet: nil
        )

      bad_req = %{valid_requirement() | "src_chain_id" => 0}

      assert {:error, {:invalid_chain_id, _}} = settler.(settle_args(bad_req))
    end

    test "rejects a malformed destination" do
      settler =
        Settler.build(
          wallet_address: @wallet,
          xochi_config: %{base_url: "http://stub"},
          xochi_wallet: nil
        )

      bad_req = %{valid_requirement() | "dst_token" => "bad"}

      assert {:error, {:invalid_to_token, _}} = settler.(settle_args(bad_req))
    end
  end
end
