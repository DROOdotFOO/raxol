defmodule Raxol.ACP.Wallet.Sma7702Test do
  use ExUnit.Case, async: true

  alias Raxol.Payments.EIP712

  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"
  @chain 8453
  # A fixed raw 65-byte secp256k1 signature (v = 0x1b) the mock authority returns.
  @raw_sig <<0xAB>> <> :binary.copy(<<0x11>>, 31) <> :binary.copy(<<0x22>>, 32) <> <<0x1B>>

  # Mock managed-authority provider: an ACP.ProviderAdapter shape that records the
  # typed data it is asked to sign and returns @raw_sig. `ProviderAdapter.sign_typed_data/3`
  # dispatches through the `:adapter` module, so only that callback is needed.
  defmodule MockProvider do
    def new(test_pid), do: %{adapter: __MODULE__, config: %{test_pid: test_pid}}

    def sign_typed_data(%{config: %{test_pid: pid}}, chain_id, typed_data) do
      send(pid, {:signed, chain_id, typed_data})
      {:ok, Raxol.ACP.Wallet.Sma7702Test.raw_sig()}
    end
  end

  def raw_sig, do: @raw_sig

  def stash_provider(pid),
    do: :persistent_term.put({__MODULE__, :provider}, MockProvider.new(pid))

  def provider, do: :persistent_term.get({__MODULE__, :provider})

  defmodule Wallet do
    use Raxol.ACP.Wallet.Sma7702,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      provider: {Raxol.ACP.Wallet.Sma7702Test, :provider}
  end

  setup do
    stash_provider(self())
    :ok
  end

  test "address/0 and chain_id/0 come from config" do
    assert Wallet.address() == @account
    assert Wallet.chain_id() == @chain
  end

  test "sign_hash/1 refuses -- a 7702 account only validates its managed authority" do
    assert Wallet.sign_hash(:binary.copy(<<0>>, 32)) ==
             {:error, :sma7702_requires_managed_signer}
  end

  test "sign_typed_data wraps the app digest in the account ReplaySafeHash and packs the envelope" do
    domain = %{name: "T", version: "1", chainId: @chain, verifyingContract: @account}
    types = %{"Msg" => [{"n", "uint256"}]}
    message = %{"n" => 7}

    {:ok, wrapped} = Wallet.sign_typed_data(domain, types, message)

    # Envelope: 0x00 || uint32(0) || 0xFF || 0x00 || <normalized 65-byte sig>.
    assert <<0x00, 0::unsigned-big-32, 0xFF, 0x00, sig::binary>> = wrapped
    assert byte_size(sig) == 65
    # v already 0x1b (>= 27), so the sig is passed through unchanged.
    assert sig == @raw_sig

    # The provider was handed the ReplaySafeHash wrapper over the ACCOUNT domain
    # (chainId + verifyingContract only), with hash = the app digest D.
    {:ok, d} = EIP712.hash(domain, types, message)
    expected_hash = "0x" <> Base.encode16(d, case: :lower)

    assert_received {:signed, @chain, wrapper}
    assert wrapper.domain == %{chainId: @chain, verifyingContract: @account}
    assert wrapper.types == %{"ReplaySafeHash" => [%{name: "hash", type: "bytes32"}]}
    assert wrapper.message == %{"hash" => expected_hash}
  end

  test "a recovery-id v (< 27) is normalized to 27/28 before packing" do
    # Swap the mock to return v = 0 (raw recovery id); the pack must lift it to 27.
    defmodule LowVProvider do
      def new(pid), do: %{adapter: __MODULE__, config: %{pid: pid}}
      def sign_typed_data(_a, _c, _td), do: {:ok, :binary.copy(<<0x33>>, 64) <> <<0x00>>}
    end

    :persistent_term.put({__MODULE__, :provider}, LowVProvider.new(self()))

    {:ok, wrapped} =
      Wallet.sign_typed_data(%{chainId: @chain}, %{"M" => [{"n", "uint256"}]}, %{"n" => 1})

    <<_env::binary-size(7), _r::binary-size(32), _s::binary-size(32), v::8>> = wrapped
    assert v == 27
  end
end
