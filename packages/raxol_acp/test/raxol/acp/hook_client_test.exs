defmodule Raxol.ACP.HookClientTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.{ABI, HookClient, ProviderAdapter}
  alias Raxol.ACP.ProviderAdapter.Mock

  @core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @bytes32_a Base.decode16!(String.duplicate("a", 64), case: :mixed)
  @bytes32_hex "0x" <> String.duplicate("ab", 32)

  setup do
    {:ok, adapter: Mock.new(address: "0xfeed", supported_chain_ids: [8453])}
  end

  describe "set_budget/6" do
    test "encodes setBudget(jobId, amount, data) and submits via ProviderAdapter", %{adapter: a} do
      assert {:ok, tx} = HookClient.set_budget(a, 8453, @core, 42, 1_000_000)
      assert String.starts_with?(tx, "0x")

      assert [{8453, [call]}] = Mock.sent_calls(a)
      assert call.to == @core
      assert call.value == 0

      expected_selector = ABI.function_selector("setBudget(uint256,uint256,bytes)")
      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end

    test "passes the optional bytes data through verbatim", %{adapter: a} do
      data = <<0xCA, 0xFE, 0xBA, 0xBE>>
      assert {:ok, _} = HookClient.set_budget(a, 8453, @core, 1, 100, data)

      [{8453, [call]}] = Mock.sent_calls(a)
      # The dynamic `bytes` argument is at the end of the calldata; the last
      # 32 bytes carry the length, and the following bytes carry the data
      # (zero-padded to a 32-byte boundary).
      <<_::binary-size(4), _head::binary-size(96), 4::unsigned-big-256, payload::binary>> =
        call.data

      assert binary_part(payload, 0, 4) == data
    end
  end

  describe "fund/6" do
    test "encodes fund(jobId, amount, data)", %{adapter: a} do
      assert {:ok, _} = HookClient.fund(a, 8453, @core, 7, 500_000)

      [{8453, [call]}] = Mock.sent_calls(a)
      expected_selector = ABI.function_selector("fund(uint256,uint256,bytes)")
      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end
  end

  describe "submit/6" do
    test "accepts raw 32-byte deliverable hash", %{adapter: a} do
      assert {:ok, _} = HookClient.submit(a, 8453, @core, 9, @bytes32_a)

      [{8453, [call]}] = Mock.sent_calls(a)
      expected_selector = ABI.function_selector("submit(uint256,bytes32,bytes)")
      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end

    test "accepts 0x-prefixed hex deliverable hash", %{adapter: a} do
      assert {:ok, _} = HookClient.submit(a, 8453, @core, 9, @bytes32_hex)
    end

    test "rejects malformed bytes32", %{adapter: a} do
      assert_raise ArgumentError, ~r/bytes32/, fn ->
        HookClient.submit(a, 8453, @core, 9, "0xshort")
      end
    end
  end

  describe "complete/6 + reject/6" do
    test "complete uses complete(uint256,bytes32,bytes) selector", %{adapter: a} do
      assert {:ok, _} = HookClient.complete(a, 8453, @core, 1, @bytes32_a)

      [{8453, [call]}] = Mock.sent_calls(a)
      expected_selector = ABI.function_selector("complete(uint256,bytes32,bytes)")
      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end

    test "reject uses reject(uint256,bytes32,bytes) selector", %{adapter: a} do
      assert {:ok, _} = HookClient.reject(a, 8453, @core, 1, @bytes32_a)

      [{8453, [call]}] = Mock.sent_calls(a)
      expected_selector = ABI.function_selector("reject(uint256,bytes32,bytes)")
      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end
  end

  describe "create_job/4" do
    test "encodes the deployed createJob(address,address,uint256,string,address)", %{adapter: a} do
      params = %{
        provider: "0x" <> String.duplicate("ab", 20),
        evaluator: "0x" <> String.duplicate("cd", 20),
        expired_at: 1_900_000_000,
        hook_address: "0x0EaD25150985Bce0B4925c54E4ee1D856381A86B",
        description: "xochi transfer"
      }

      assert {:ok, _tx} = HookClient.create_job(a, 8453, @core, params)

      [{8453, [call]}] = Mock.sent_calls(a)
      assert call.to == @core

      # Must match the on-chain AgenticCommerceV3 selector 0x41528812, not the
      # old (address,bytes) shape which reverts on the real core.
      expected_selector =
        ABI.function_selector("createJob(address,address,uint256,string,address)")

      assert <<^expected_selector::binary-size(4), _rest::binary>> = call.data
    end
  end

  describe "error propagation" do
    defmodule FailingAdapter do
      @behaviour Raxol.ACP.ProviderAdapter
      def send_calls(_, _, _), do: {:error, :network_down}
      def sign_message(_, _, _), do: {:error, :nope}
      def sign_typed_data(_, _, _), do: {:error, :nope}
      def get_transaction_receipt(_, _, _), do: {:ok, nil}
      def read_contract(_, _, _), do: {:error, :nope}
      def get_logs(_, _, _), do: {:ok, []}
      def get_address(_), do: "0x0"
      def supported_chain_ids(_), do: []
    end

    test "propagates errors from the underlying adapter" do
      bad_adapter = %{adapter: FailingAdapter, config: %{}}

      assert {:error, :network_down} = HookClient.set_budget(bad_adapter, 8453, @core, 1, 100)
      assert {:error, :network_down} = HookClient.fund(bad_adapter, 8453, @core, 1, 100)
      assert {:error, :network_down} = HookClient.submit(bad_adapter, 8453, @core, 1, @bytes32_a)
    end
  end
end
