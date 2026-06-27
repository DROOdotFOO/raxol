defmodule Raxol.Payments.Conformance.Permit2ConformanceTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Test.ConformanceFixture
  alias Raxol.Payments.Test.ConformanceSigner

  @moduletag :conformance

  setup_all do
    case ConformanceFixture.locate() do
      {:ok, _path} -> :ok
      {:error, :not_found} -> {:skip, "conformance fixture not found"}
    end
  end

  # Signs with secp256k1 key 1 (the conformance fixture's key) through the same
  # primitives as Raxol.Payments.Wallets.Env, so Permit2.sign_quote/3 returns the
  # exact signature bytes ethers produced. address/0 is the derived signer.
  defmodule CanonicalWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet

    @key Base.decode16!("0000000000000000000000000000000000000000000000000000000000000001")

    @impl true
    def address, do: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf"

    @impl true
    def chain_id, do: 0

    @impl true
    def sign_message(_msg), do: {:ok, <<0::512>>}

    @impl true
    def sign_typed_data(domain, types, message) do
      with {:ok, digest} <- Raxol.Payments.EIP712.hash(domain, types, message),
           {:ok, signature} <- ExSecp256k1.sign(digest, @key) do
        {:ok, Raxol.Payments.EIP712.pack_signature(signature)}
      end
    end

    @impl true
    def sign_hash(<<digest::binary-size(32)>>) do
      {:ok, signature} = ExSecp256k1.sign(digest, @key)
      {:ok, Raxol.Payments.EIP712.pack_signature(signature)}
    end
  end

  describe "Permit2 EIP-712 conformance vs CLI" do
    for vec <- ConformanceFixture.by_protocol("permit2") do
      @vec vec

      test "digest + signed_object + signature match CLI for #{vec["name"]}" do
        vec = @vec
        chain_id = vec["domain"]["chainId"] || vec["domain"]["chain_id"]
        quote_map = vec["quote"]

        assert {:ok, result} = Permit2.sign_quote(quote_map, chain_id, CanonicalWallet)

        assert result.digest == vec["expected_digest"],
               "digest mismatch for #{vec["name"]}: got #{result.digest}, expected #{vec["expected_digest"]}"

        assert result.signed_object == vec["expected_signed_object"],
               "signed_object mismatch for #{vec["name"]}: got #{result.signed_object}, expected #{vec["expected_signed_object"]}"

        # The CLI signs the PermitWitnessTransferFrom digest with ethers; the full
        # sign_quote path must land on the same bytes and recover to the signer.
        assert result.signature == vec["expected_signature"],
               "signature mismatch for #{vec["name"]}: got #{result.signature}, expected #{vec["expected_signature"]}"

        digest = ConformanceSigner.decode_hex!(result.digest)

        assert ConformanceSigner.recover_address(digest, result.signature) ==
                 String.downcase(vec["expected_signer"]),
               "recovered signer mismatch for #{vec["name"]}"
      end
    end
  end
end
