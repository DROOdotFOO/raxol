defmodule Raxol.Payments.Conformance.Permit2ConformanceTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Test.ConformanceFixture

  @moduletag :conformance

  setup_all do
    case ConformanceFixture.locate() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> {:skip, "conformance fixture not found"}
    end
  end

  defmodule StaticWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"
    @impl true
    def chain_id, do: 0
    @impl true
    def sign_message(_msg), do: {:ok, <<0::512>>}
    @impl true
    def sign_typed_data(_domain, _types, _message), do: {:ok, <<0::520>>}
    @impl true
    def sign_hash(_digest), do: {:ok, <<0::520>>}
  end

  describe "Permit2 EIP-712 conformance vs CLI" do
    for vec <- ConformanceFixture.by_protocol("permit2") do
      @vec vec

      test "digest + signed_object match CLI for #{vec["name"]}" do
        vec = @vec
        chain_id = vec["domain"]["chainId"] || vec["domain"]["chain_id"]
        quote_map = vec["quote"]

        assert {:ok, result} = Permit2.sign_quote(quote_map, chain_id, StaticWallet)

        assert result.digest == vec["expected_digest"],
               "digest mismatch for #{vec["name"]}: got #{result.digest}, expected #{vec["expected_digest"]}"

        assert result.signed_object == vec["expected_signed_object"],
               "signed_object mismatch for #{vec["name"]}: got #{result.signed_object}, expected #{vec["expected_signed_object"]}"
      end
    end
  end
end
