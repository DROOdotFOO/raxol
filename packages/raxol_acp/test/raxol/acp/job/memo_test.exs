defmodule Raxol.ACP.Job.MemoTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Job.Memo

  # Hardhat account #0 -- standard well-known test key.
  @test_env_var "RAXOL_ACP_MEMO_TEST_KEY"
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @verifying_contract "0x" <> String.duplicate("ab", 20)
  @payload_hash "0x" <> String.duplicate("cd", 32)
  @opts [chain_id: 8453, verifying_contract: @verifying_contract]

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_MEMO_TEST_KEY",
      chain_id: 8453
  end

  setup do
    System.put_env(@test_env_var, @test_privkey)
    on_exit(fn -> System.delete_env(@test_env_var) end)
    :ok
  end

  describe "typed_data/4" do
    test "produces a well-formed EIP-712 envelope" do
      {domain, types, message} = Memo.typed_data("1", :request, @payload_hash, @opts)

      assert domain.name == "Virtuals ACP"
      assert domain.version == "2"
      assert domain.chainId == 8453
      assert domain.verifyingContract == @verifying_contract

      assert Map.has_key?(types, "Memo")
      assert message.jobId == 1
      assert message.memoType == "request"
      assert message.payloadHash == @payload_hash
    end

    test "respects :name and :version overrides" do
      opts = Keyword.merge(@opts, name: "Custom", version: "9")
      {domain, _, _} = Memo.typed_data("1", :request, @payload_hash, opts)

      assert domain.name == "Custom"
      assert domain.version == "9"
    end

    test "passes integer job ids through unchanged" do
      {_, _, message} = Memo.typed_data(42, :request, @payload_hash, @opts)
      assert message.jobId == 42
    end

    test "parses numeric-string job ids" do
      {_, _, message} = Memo.typed_data("1234567890", :request, @payload_hash, @opts)
      assert message.jobId == 1_234_567_890
    end

    test "synthetic non-numeric job ids are deterministically hashed to uint256" do
      {_, _, m1} = Memo.typed_data("job-1", :request, @payload_hash, @opts)
      {_, _, m2} = Memo.typed_data("job-1", :request, @payload_hash, @opts)
      {_, _, m3} = Memo.typed_data("job-2", :request, @payload_hash, @opts)

      assert m1.jobId == m2.jobId
      assert m1.jobId != m3.jobId
      assert is_integer(m1.jobId) and m1.jobId >= 0
    end

    test "raises if :chain_id missing" do
      assert_raise KeyError, fn ->
        Memo.typed_data("1", :request, @payload_hash, verifying_contract: @verifying_contract)
      end
    end

    test "raises if :verifying_contract missing" do
      assert_raise KeyError, fn ->
        Memo.typed_data("1", :request, @payload_hash, chain_id: 8453)
      end
    end
  end

  describe "digest/1" do
    test "returns 32 bytes for a valid typed-data tuple" do
      td = Memo.typed_data("1", :request, @payload_hash, @opts)
      assert {:ok, hash} = Memo.digest(td)
      assert byte_size(hash) == 32
    end

    test "is deterministic" do
      td = Memo.typed_data("1", :request, @payload_hash, @opts)
      assert {:ok, h1} = Memo.digest(td)
      assert {:ok, h2} = Memo.digest(td)
      assert h1 == h2
    end

    test "differs for different memo types" do
      t1 = Memo.typed_data("1", :request, @payload_hash, @opts)
      t2 = Memo.typed_data("1", :negotiation, @payload_hash, @opts)
      assert {:ok, h1} = Memo.digest(t1)
      assert {:ok, h2} = Memo.digest(t2)
      assert h1 != h2
    end

    test "differs for different chain ids (replay protection)" do
      t1 = Memo.typed_data("1", :request, @payload_hash, @opts)
      t2 = Memo.typed_data("1", :request, @payload_hash, Keyword.put(@opts, :chain_id, 84_532))
      assert {:ok, h1} = Memo.digest(t1)
      assert {:ok, h2} = Memo.digest(t2)
      assert h1 != h2
    end

    test "differs for different verifying contracts" do
      other = "0x" <> String.duplicate("ef", 20)
      t1 = Memo.typed_data("1", :request, @payload_hash, @opts)

      t2 =
        Memo.typed_data(
          "1",
          :request,
          @payload_hash,
          Keyword.put(@opts, :verifying_contract, other)
        )

      assert {:ok, h1} = Memo.digest(t1)
      assert {:ok, h2} = Memo.digest(t2)
      assert h1 != h2
    end
  end

  describe "sign/2 with a real wallet" do
    test "produces a 65-byte signature (r ++ s ++ v)" do
      td = Memo.typed_data("1", :request, @payload_hash, @opts)
      assert {:ok, sig} = Memo.sign(td, Wallet)
      assert byte_size(sig) == 65
    end

    test "is deterministic for the same key + typed-data" do
      td = Memo.typed_data("1", :request, @payload_hash, @opts)
      assert {:ok, s1} = Memo.sign(td, Wallet)
      assert {:ok, s2} = Memo.sign(td, Wallet)
      assert s1 == s2
    end

    test "different memo types produce different signatures" do
      td1 = Memo.typed_data("1", :request, @payload_hash, @opts)
      td2 = Memo.typed_data("1", :negotiation, @payload_hash, @opts)
      assert {:ok, s1} = Memo.sign(td1, Wallet)
      assert {:ok, s2} = Memo.sign(td2, Wallet)
      assert s1 != s2
    end

    test "different job ids produce different signatures" do
      td1 = Memo.typed_data("1", :request, @payload_hash, @opts)
      td2 = Memo.typed_data("2", :request, @payload_hash, @opts)
      assert {:ok, s1} = Memo.sign(td1, Wallet)
      assert {:ok, s2} = Memo.sign(td2, Wallet)
      assert s1 != s2
    end
  end

  describe "build_and_sign/5 convenience" do
    test "returns both message and signature" do
      assert {:ok, %{message: message, signature: sig}} =
               Memo.build_and_sign("1", :evaluation, @payload_hash, Wallet, @opts)

      assert message.memoType == "evaluation"
      assert message.payloadHash == @payload_hash
      assert byte_size(sig) == 65
    end

    test "signature matches what sign/2 would produce on the same typed-data" do
      td = Memo.typed_data("1", :evaluation, @payload_hash, @opts)
      assert {:ok, expected_sig} = Memo.sign(td, Wallet)

      assert {:ok, %{signature: sig}} =
               Memo.build_and_sign("1", :evaluation, @payload_hash, Wallet, @opts)

      assert sig == expected_sig
    end
  end
end
