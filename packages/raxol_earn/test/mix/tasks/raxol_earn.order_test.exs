defmodule Mix.Tasks.RaxolEarn.OrderTest do
  # async: false -- Mix.shell/1 and the task's env reads are process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.RaxolEarn.Order
  alias Raxol.Earn.ProviderAdapter.Mock

  @spender "0xE9B020941015e428876f60C1979B3fc2A38a2f53"
  @allowance_sig "allowance(address,address)"

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  # 3.00 USDC on Base at the default 8 bps, so the take rate -- and with it the
  # default ceiling -- is 2400 base units.
  defp cfg do
    %{
      buyer: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      from: 8453,
      src_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      core: "0x238E541BfefD82238730D00a2208E5497F1832E0",
      amount: "3.00",
      principal_atomic: 3_000_000,
      fee_bps: 8
    }
  end

  # The real flag surface, so a ceiling raised on the command line is the ceiling
  # under test.
  defp gate(budget, argv), do: Order.enforce_budget!(cfg(), budget, Order.parse_argv(argv))

  # The universal Permit2 contract -- the ERC-20 spender an origin-pull approve
  # names. The permit's own spender is what the --solver pin bounds; the two are
  # different addresses and confusing them is the failure this pins against.
  @permit2 "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  defp permit(amount \\ 3_000_000),
    do: %{spender: @spender, chain_id: 8453, token: cfg().src_token, amount: amount}

  defp calls(pull), do: Order.funding_calls(cfg(), 73_295, 2_400, pull)

  defp selector(%{data: <<sel::binary-size(4), _rest::binary>>}),
    do: Base.encode16(sel, case: :lower)

  defp selector_of(signature),
    do: Base.encode16(binary_part(ExKeccak.hash_256(signature), 0, 4), case: :lower)

  defp approve_args(%{data: <<_sel::binary-size(4), spender::binary-size(32), amount::256>>}),
    do: {"0x" <> Base.encode16(binary_part(spender, 12, 20), case: :lower), amount}

  defp word(value), do: "0x" <> String.pad_leading(Integer.to_string(value, 16), 64, "0")

  # A cfg carrying a provider, for the reads the funding leg makes on its own.
  defp funding_cfg(adapter), do: Map.put(cfg(), :provider_adapter, adapter)

  defp with_allowance(value) do
    adapter = Mock.new()
    :ok = Mock.set_contract_read(adapter, cfg().src_token, @allowance_sig, word(value))
    funding_cfg(adapter)
  end

  # The gap between signing and funding is minutes of real time: createJob has to
  # mine, the chat room has to appear, and the provider has to write a budget. An
  # allowance covering the pull at signing can be spent down inside that window --
  # an earlier intent's own pull consumes it -- so a batch built from the signing
  # read would escrow the fee and leave THIS intent's pull short. Fee paid,
  # transfer impossible.
  describe "the allowance behind the funding batch" do
    test "is read at funding time, not carried over from signing" do
      # Signing saw a covering allowance; by now it is spent down to zero.
      assert {:short, %{amount: 3_000_000}} =
               Order.fund_time_allowance(with_allowance(0), {:permit2, permit()})
    end

    test "an allowance that still covers the pull adds nothing to the batch" do
      assert :standing =
               Order.fund_time_allowance(with_allowance(3_000_000), {:permit2, permit()})
    end

    test "a rail needing no allowance reads nothing and stays not_needed" do
      adapter = Mock.new()

      assert :not_needed = Order.fund_time_allowance(funding_cfg(adapter), :not_needed)
      assert Mock.sent_calls(adapter) == []
    end

    test "the fresh reading is what decides the batch, so a spent-down one restores the approve" do
      pull = Order.fund_time_allowance(with_allowance(0), {:permit2, permit()})

      assert [permit2_approve, _core_approve, _fund] = calls(pull)
      assert approve_args(permit2_approve) == {String.downcase(@permit2), 3_000_000}
    end

    # Funding without the approve is the outcome being avoided, so an unreadable
    # allowance must not be treated as one that covers the pull.
    test "a failed read at funding time aborts rather than funding short" do
      adapter = Mock.new()

      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn ->
          Order.fund_time_allowance(funding_cfg(adapter), {:permit2, permit()})
        end)

      assert message =~ "origin-pull allowance could not be settled"
      assert Mock.sent_calls(adapter) == []
    end
  end

  describe "--corridor validation" do
    test "an unsupported destination lists only the chains USDC actually exists on" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--corridor", "8453>4663", "--dry-run"]) end)

      assert message =~ "no USDC address for the destination chain 4663"

      # 4663 (Robinhood Chain) carries USDG and WETH but no USDC, so offering it as
      # an alternative sends the operator straight back into this same error.
      refute message =~ "Robinhood Chain"

      for chain <- ["1 (Ethereum)", "10 (Optimism)", "137 (Polygon)", "8453 (Base)"] do
        assert message =~ chain
      end
    end

    # This task runs the whole ACP lifecycle on the corridor's ORIGIN chain, and
    # the ACP core is deployed only on Base. The funding batch is what makes that
    # binding rather than incidental: it carries the origin-chain Permit2 approve
    # in the same send_calls as the Base ACP fund, and one batch is one chain.
    #
    # Unchecked it looked supported -- createJob went to the Base core address on
    # the origin chain, where nothing is deployed, while the budget poll read Base
    # and saw nothing. The 7702/SCA wallets sign for 8453 regardless, so nothing
    # downstream would have caught it either.
    test "a non-Base origin is refused, not half-executed" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--corridor", "42161>8453", "--dry-run"]) end)

      assert message =~ "--corridor origin 42161 is not the ACP core's chain (8453)"
      # The remedy names a corridor that actually works, keeping the destination.
      assert message =~ "--corridor 8453>42161"
    end

    # The origin check fires before the token lookup, so an origin that fails both
    # is reported on the ground that no token address could fix.
    test "an origin with no USDC is refused as an origin, not as a token gap" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--corridor", "4663>8453", "--dry-run"]) end)

      assert message =~ "is not the ACP core's chain"
      refute message =~ "no USDC address"
    end
  end

  describe "the --solver pin" do
    test "is a real switch, not one OptionParser silently drops" do
      # `strict:` routes an unregistered switch to `invalid` and parse_argv drops
      # it, so an unregistered --solver would leave the pin unset while the
      # operator watched themselves type it.
      assert Order.parse_argv(["--solver", @spender]) == [solver: @spender]
    end

    test "a malformed address is refused before the signer sidecar boots" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--solver", "0xnope", "--dry-run"]) end)

      assert message =~ "is not a 0x-hex 20-byte address"
      assert message =~ "pins the origin-pull spender"
    end

    test "ORDER_SOLVER is read when the flag is absent, and validated the same way" do
      put_solver_env("not-an-address")

      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--dry-run"]) end)

      assert message =~ "ORDER_SOLVER"
      assert message =~ "is not a 0x-hex 20-byte address"
    end

    test "an empty --solver falls back to ORDER_SOLVER instead of suppressing it" do
      # `--solver ""` is truthy in Elixir, so an empty flag used to win the `||`
      # and leave the run unpinned while ORDER_SOLVER sat there set.
      put_solver_env("not-an-address")

      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--solver", "  ", "--dry-run"]) end)

      # The env value is what got validated, so it is the value named back.
      assert message =~ ~s|"not-an-address"|
      assert message =~ "is not a 0x-hex 20-byte address"
    end
  end

  # The value is process-global, so a test that deletes it on the way out erases
  # whatever the operator (or an outer gate run) had set.
  defp put_solver_env(value) do
    prior = System.get_env("ORDER_SOLVER")
    System.put_env("ORDER_SOLVER", value)
    on_exit(fn -> restore_env("ORDER_SOLVER", prior) end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # The Virtuals paymaster refuses a STANDALONE approve to a token contract, so
  # the Permit2 approve cannot be its own UserOp on the sponsored path this task
  # defaults to. It rides in the approve+fund batch instead, which the paymaster
  # already accepts -- and which lands the allowance in the very transaction that
  # funds the job, so it exists at the first block the seller can observe
  # `funded` and settle (the settlement is when the solver pulls).
  describe "the funding batch" do
    test "a short allowance rides in the batch rather than a standalone approve" do
      assert [permit2_approve, core_approve, fund] = calls({:short, permit()})

      assert selector(permit2_approve) == selector_of("approve(address,uint256)")
      assert permit2_approve.to == cfg().src_token
      assert approve_args(permit2_approve) == {String.downcase(@permit2), 3_000_000}

      # The ACP-core call is what makes the paymaster accept the UserOp, so the
      # batch the approve rides in must still carry it.
      assert core_approve.to == cfg().src_token
      assert approve_args(core_approve) == {String.downcase(cfg().core), 2_400}
      assert fund.to == cfg().core
      assert selector(fund) == selector_of("fund(uint256,uint256,bytes)")
    end

    test "the batched approve grants the permit's bound, never a standing max" do
      assert [permit2_approve | _] = calls({:short, permit(1_500_000)})
      assert {_spender, 1_500_000} = approve_args(permit2_approve)
    end

    test "a standing allowance adds nothing, so the batch is escrow only" do
      for pull <- [:standing, :not_needed] do
        assert [core_approve, fund] = calls(pull)
        assert approve_args(core_approve) == {String.downcase(cfg().core), 2_400}
        assert fund.to == cfg().core
      end
    end

    test "the funding log line names the Permit2 approve when it rides along" do
      assert Order.funding_line(73_295, {:short, permit()}) =~ "approve(Permit2"
      assert Order.funding_line(73_295, {:short, permit()}) =~ "3000000"
      refute Order.funding_line(73_295, :standing) =~ "Permit2"
      refute Order.funding_line(73_295, :standing) =~ "sponsored"
    end
  end

  describe "the origin-pull disclosure" do
    test "a funded run says where the approve lands" do
      text = Enum.join(Order.origin_pull_lines({:short, permit()}, fund: true), "\n")

      assert text =~ "SHORT"
      assert text =~ "approve+fund"
      refute text =~ "CANNOT execute"
    end

    test "a run that signs but never funds says the pull it authorized cannot execute" do
      text = Enum.join(Order.origin_pull_lines({:short, permit()}, []), "\n")

      assert text =~ "does not --fund"
      assert text =~ "CANNOT execute"
      assert text =~ "--job-id"
    end

    test "a dry run says no approve is sent, without the unfunded warning" do
      text = Enum.join(Order.origin_pull_lines({:short, permit()}, dry_run: true), "\n")

      assert text =~ "--dry-run"
      refute text =~ "CANNOT execute"
    end

    test "a covered or non-Permit2 pull adds no warning at all" do
      for pull <- [:standing, :not_needed], opts <- [[], [fund: true]] do
        assert [_one_line] = Order.origin_pull_lines(pull, opts)
      end
    end
  end

  describe "the escrow ceiling gate" do
    test "a budget above the ceiling aborts a --fund run before anything is approved" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> gate(2_000_000_000, ["--fund"]) end)

      assert message =~ "above the 2400 ceiling"
      assert message =~ "refusing to fund"

      # Why the number matters: it is the provider's, and --fund pays it.
      assert message =~ "what --fund approves and escrows"
      assert message =~ "re-run with a matching --fee-bps"
      assert message =~ "not charging what it advertises"
      assert message =~ "--max-escrow"
    end

    test "a budget exactly at the take rate passes" do
      assert gate(2_400, ["--fund"]) == :ok
      assert_received {:mix_shell, :info, ["[order] OK: budget == 8 bps of the principal"]}
    end

    test "a budget under the take rate is accepted, with the shortfall disclosed" do
      # Charging less than advertised costs the buyer nothing, so it must not abort.
      assert gate(2_000, ["--fund"]) == :ok

      assert_received {:mix_shell, :info,
                       ["[order] budget 2000 != expected 2400 (8 bps), within the ceiling 2400"]}
    end

    test "a run without --fund discloses a mismatch instead of stranding the job" do
      # By this point createJob has landed and the requirement is sent. A run that
      # escrows nothing has nothing to refuse.
      assert gate(2_000_000_000, []) == :ok
      assert_received {:mix_shell, :info, ["[order] WARN: provider set budget 2000000000" <> _]}
    end

    test "--max-escrow raises the ceiling so a refused budget is accepted" do
      assert_raise(Mix.Error, fn -> gate(50_000, ["--fund"]) end)

      assert gate(50_000, ["--fund", "--max-escrow", "0.05"]) == :ok
      assert_received {:mix_shell, :info, ["[order] budget 50000 != expected 2400" <> _]}
    end

    test "--max-escrow that is not a USDC amount is refused" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> gate(2_400, ["--fund", "--max-escrow", "lots"]) end)

      assert message =~ "is not a USDC amount"
    end
  end

  # The preflight's own suite proves it classifies outcomes correctly. This
  # proves the run SPENDS on that classification -- a distinct claim, and the one
  # that was untested while a catch-all funded every outcome but one.
  describe "what a preflight outcome authorizes" do
    test "a funded run proceeds only on a pass" do
      assert Order.decide_preflight({:ok, %{}}, false) == :ok
    end

    test "a funded run stops on a rejection" do
      assert Order.decide_preflight({:rejected, %{reason: :no_verifying_contract}}, false) ==
               {:error, :pull_signature_rejected}
    end

    test "a funded run stops on an inconclusive check too" do
      # An unanswered question is not permission to escrow. The RPC that could
      # not answer it is the same one the createJob and fund writes go to.
      assert Order.decide_preflight({:inconclusive, {:chain_id_unavailable, :timeout}}, false) ==
               {:error, :pull_preflight_inconclusive}
    end

    # `scripts/run_live_gates.sh --dry-run` scores every cell on this task's exit
    # status, so a rejection that returned :ok here scored the rehearsal PASS on
    # the single defect the rehearsal exists to find.
    test "a dry run FAILS on a rejection, since the rehearsal is what CI scores" do
      assert Order.decide_preflight({:rejected, %{reason: :no_verifying_contract}}, true) ==
               {:error, :pull_signature_rejected}
    end

    # Not a verdict on the payload, and the usual cause is an origin-chain
    # endpoint the rehearsing machine was never given. Failing on it trains an
    # operator to ignore the exit code.
    test "a dry run carries on when the check could not run" do
      assert Order.decide_preflight({:inconclusive, :whatever}, true) == :ok
    end
  end

  # The gate can only check a signature it is handed. Reading a missing one as
  # "nothing to check" would switch the gate off for exactly the payload it was
  # built to gate, which is the fail-open shape PullPreflight refuses to offer
  # its callers one level down.
  describe "a bundle with no pull signature" do
    test "aborts rather than funding an unchecked pull" do
      quote_resp = %{pull_authorization: %{"domain" => %{}}}
      cfg = %{buyer: "0x0", rpc: "http://stub.invalid", src_token: "0x0"}

      assert {:error, {:pull_signature_missing, nil}} =
               Order.preflight_pull(cfg, quote_resp, %{signature: "0xabc"}, [])

      assert {:error, {:pull_signature_missing, nil}} =
               Order.preflight_pull(cfg, quote_resp, %{}, dry_run: true)
    end

    test "a quote that served no pull has nothing to check and is not blocked" do
      cfg = %{buyer: "0x0", rpc: "http://stub.invalid", src_token: "0x0"}

      assert :ok = Order.preflight_pull(cfg, %{pull_authorization: nil}, %{}, [])
    end
  end
end
