defmodule Raxol.Earn.Xochi.FeePathForkTest do
  @moduledoc """
  `:live_chain` fork trace of the storefront FEE PATH against the REAL deployed
  `AgenticCommerceV3` core on a Base fork. This is the on-chain half the
  in-memory `live_order_test.exs` cannot exercise: it proves that a PLAIN job
  (`hook = address(0)`) whose budget is the storefront fee pays raxol (the
  provider) `net = budget - platformFee - evaluatorFee = budget * 0.90` on
  completion, via the contract's real `PaymentReleased` event and real token
  transfers.

  Read from the verified source at `0x8e86FbEf4a4c927561cb6447cEd77ffFbf3B77BC`
  (`AgenticCommerceV3.sol`):

  - `whitelistedHooks[address(0)] = true` is set in `initialize`, so a plain job
    (`hook = 0`) passes `createJob`'s whitelist check -- no hook, no escrow
    routing, no `IACPHook` interface requirement.
  - Roles are enforced distinct: `client != provider`, `evaluator != provider`.
  - `setBudget` is PROVIDER-only; `fund` is CLIENT-only; `submit` is
    PROVIDER-only; `complete` is EVALUATOR-only (Submitted -> Completed).
  - On `complete`: `platformFee = budget*platformFeeBP/10000`,
    `evalFee = budget*evaluatorFeeBP/10000`, `net = budget - platformFee - evalFee`
    -> provider; emits `PaymentReleased(jobId, provider, net)`.

  Roles map to three anvil accounts: account 0 = client (buyer), account 1 =
  provider (raxol), account 2 = evaluator. Fees are READ from the fork's real
  storage (`platformFeeBP`/`evaluatorFeeBP`, both 500 on the live deployment ->
  a 10% take), so the assertion tracks the deployed config rather than a
  hardcoded split.

  USDC is dealt to the buyer by overwriting `balanceOf[buyer]` on the fork
  (Circle FiatToken balances at slot 9); the test asserts the write took before
  proceeding, so a wrong slot fails loudly instead of a confusing `fund` revert.

  Tagged `:live_chain`; needs foundry (anvil + cast). Excluded by default. Run:

      RAXOL_ACP_FORK_URL=https://mainnet.base.org \\
        MIX_ENV=test mix test --include live_chain \\
        test/raxol/acp/xochi/fee_path_fork_test.exs
  """
  use ExUnit.Case, async: false

  alias Raxol.Earn.HookClient
  alias Raxol.Earn.ProviderAdapter.JSONRPC
  alias Raxol.Earn.Test.AnvilHarness

  @moduletag :live_chain
  @moduletag timeout: 300_000

  @chain_id 8453
  @acp_core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  # Circle FiatToken stores the balances mapping at storage slot 9.
  @usdc_balance_slot 9
  @zero_hook "0x0000000000000000000000000000000000000000"
  # 0.005 USDC storefront fee.
  @fee 5_000

  setup_all do
    rpc = AnvilHarness.start!(port: 8613, chain_id: @chain_id)

    buyer = AnvilHarness.anvil_account(0)
    provider = AnvilHarness.anvil_account(1)
    evaluator = AnvilHarness.anvil_account(2)

    for %{address: a} <- [buyer, provider, evaluator] do
      AnvilHarness.anvil_set_balance(rpc, a, 10 * 10 ** 18)
    end

    %{
      rpc: rpc,
      buyer: buyer,
      provider: provider,
      evaluator: evaluator,
      adapters: %{
        buyer: adapter_for(rpc, buyer),
        provider: adapter_for(rpc, provider),
        evaluator: adapter_for(rpc, evaluator)
      }
    }
  end

  test "a plain-job storefront fee releases budget*0.90 to the provider", ctx do
    %{rpc: rpc, buyer: buyer, provider: provider, evaluator: evaluator, adapters: a} = ctx

    # Deal the buyer USDC and confirm the storage write landed (guards the slot).
    AnvilHarness.deal_erc20(rpc, @usdc, buyer.address, @fee, @usdc_balance_slot)
    assert AnvilHarness.erc20_balance(rpc, @usdc, buyer.address) == @fee

    # Provider and evaluator start with no USDC, so post-flow balances are the
    # exact amounts the contract paid them.
    assert AnvilHarness.erc20_balance(rpc, @usdc, provider.address) == 0
    assert AnvilHarness.erc20_balance(rpc, @usdc, evaluator.address) == 0

    # 1. createJob(provider, evaluator, expiry, "", hook=0) -- the BUYER (client).
    {:ok, create_tx} =
      HookClient.create_job(a.buyer, @chain_id, @acp_core, %{
        provider: provider.address,
        evaluator: evaluator.address,
        expired_at: now() + 3600,
        hook_address: @zero_hook,
        description: "xochi storefront fee"
      })

    AnvilHarness.assert_tx_success!(rpc, create_tx)

    # This is the only job creator on the fork, so the post-createJob counter is
    # our jobId (the contract does `++jobCounter`).
    job_id = AnvilHarness.read_uint(rpc, @acp_core, "jobCounter()(uint256)")

    # 2. setBudget(jobId, fee, "") -- the PROVIDER (raxol). budget = storefront fee.
    {:ok, budget_tx} = HookClient.set_budget(a.provider, @chain_id, @acp_core, job_id, @fee)
    AnvilHarness.assert_tx_success!(rpc, budget_tx)

    # 3. approve(core, fee) + fund(jobId, fee, "") -- the BUYER. A successful fund
    #    proves budget == fee (the contract reverts BudgetMismatch otherwise).
    approve_usdc(rpc, buyer, @acp_core, @fee)
    {:ok, fund_tx} = HookClient.fund(a.buyer, @chain_id, @acp_core, job_id, @fee)
    AnvilHarness.assert_tx_success!(rpc, fund_tx)

    # 4. submit(jobId, deliverable, "") -- the PROVIDER. With an evaluator set,
    #    this is Funded -> Submitted (no auto-complete).
    deliverable = "0x" <> String.duplicate("cd", 32)
    {:ok, submit_tx} = HookClient.submit(a.provider, @chain_id, @acp_core, job_id, deliverable)
    AnvilHarness.assert_tx_success!(rpc, submit_tx)

    # 5. complete(jobId, reason, "") -- the EVALUATOR. Distributes the escrow.
    reason = "0x" <> String.duplicate("11", 32)
    {:ok, complete_tx} = HookClient.complete(a.evaluator, @chain_id, @acp_core, job_id, reason)
    AnvilHarness.assert_tx_success!(rpc, complete_tx)

    # Net paid to the provider, computed from the fork's real fee config.
    platform_bp = AnvilHarness.read_uint(rpc, @acp_core, "platformFeeBP()(uint256)")
    eval_bp = AnvilHarness.read_uint(rpc, @acp_core, "evaluatorFeeBP()(uint256)")
    platform_fee = div(@fee * platform_bp, 10_000)
    eval_fee = div(@fee * eval_bp, 10_000)
    net = @fee - platform_fee - eval_fee

    # The deployed config is a 10% take, so the provider nets 90% of the budget.
    assert platform_bp == 500
    assert eval_bp == 500
    assert net == div(@fee * 90, 100)

    # The money moved exactly as the fee model claims: the provider (raxol) got
    # net, the evaluator got its fee, and the buyer's escrow is spent.
    assert AnvilHarness.erc20_balance(rpc, @usdc, provider.address) == net
    assert AnvilHarness.erc20_balance(rpc, @usdc, evaluator.address) == eval_fee
    assert AnvilHarness.erc20_balance(rpc, @usdc, buyer.address) == 0

    # And the completion receipt carries the real PaymentReleased event.
    assert receipt_has_event?(rpc, complete_tx, "PaymentReleased(uint256,address,uint256)"),
           "complete receipt did not emit PaymentReleased"
  end

  # -- Helpers --

  defp adapter_for(rpc, %{private_key: pk}) do
    JSONRPC.new(
      chains: %{@chain_id => rpc},
      private_key: pk,
      fee_overrides: %{
        @chain_id => %{
          max_priority_fee_per_gas: 1_000_000_000,
          max_fee_per_gas: 5_000_000_000
        }
      }
    )
  end

  defp approve_usdc(rpc, %{private_key: pk}, spender, amount) do
    {_out, 0} =
      AnvilHarness.cast([
        "send",
        @usdc,
        "approve(address,uint256)",
        spender,
        "#{amount}",
        "--private-key",
        "0x" <> Base.encode16(pk, case: :lower),
        "--rpc-url",
        rpc
      ])

    :ok
  end

  # topic0 of the event = keccak256 of its canonical signature; a completed job's
  # receipt must contain it.
  defp receipt_has_event?(rpc, tx_hash, signature) do
    topic0 = "0x" <> Base.encode16(ExKeccak.hash_256(signature), case: :lower)
    {receipt, 0} = AnvilHarness.cast(["receipt", tx_hash, "--rpc-url", rpc])
    String.contains?(String.downcase(receipt), String.downcase(topic0))
  end

  defp now, do: System.system_time(:second)
end
