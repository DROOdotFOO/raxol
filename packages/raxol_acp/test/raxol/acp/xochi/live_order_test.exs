defmodule Raxol.ACP.Xochi.LiveOrderTest do
  @moduledoc """
  Another agent orders the `xochi_cross_chain_transfer` ACP offering and the
  seller settles it for real through Xochi + the Riddler solver.

  This is the end-to-end proof that the settlement services are orderable through
  the ACP: a buyer creates a job, the seller's `Raxol.ACP.Xochi.TransferOffering`
  accepts it and, on delivery, runs the real `Raxol.ACP.Xochi.Settler` ->
  `Raxol.Payments.Protocols.Xochi.transfer/4`. The deliverable carries the intent
  id and the on-chain settlement tx hashes.

  The job orchestration uses the in-memory `ContractClient` (no live ACP escrow
  contracts); the SETTLEMENT is real and moves funds. The fuller on-chain escrow
  path (`ContractClient.Onchain` + `HookClient` + `SolverAgent`) is the existing
  `:live_chain` stack and is a separate gate.

  Auth is the Member service token (`XOCHI_ORDER_LIVE_TOKEN`): the seller is a
  Xochi Member, and the `Settler` uses one config for quote/execute/poll. (The
  mandate path is exercised by the raxol_payments Xochi gate.)

  USDC pulls via ERC-3009 and settles directly. USDT/WETH pull via Permit2 and
  need a standing on-chain allowance, which this gate broadcasts via
  `Raxol.ACP.Onchain.Permit2Approver` using a JSON-RPC provider built from the
  funded key and `XOCHI_ORDER_RPC_<chain>`. A USDT/WETH cell with no RPC for its
  origin chain is skipped (logged), not failed.

  Moves real funds. Tagged `:live_xochi_order` (settle) and
  `:live_xochi_order_preflight` (read-only); excluded by default and compiled
  only when the required env is present.

  Funds settle to the seller wallet on the destination chain (the current
  `Settler` delivers to the `QuoteRequest` wallet), so default the recipient to
  the funded key's own address.

      XOCHI_ORDER_LIVE_URL=https://api.xochi.fi \\
      XOCHI_ORDER_LIVE_TOKEN="$(op read 'op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential')" \\
      XOCHI_ORDER_LIVE_KEY=0x<funded seller key> \\
      XOCHI_ORDER_RPC_8453=https://mainnet.base.org \\
      XOCHI_ORDER_TOKENS=USDC,USDT,WETH \\
        mix test --only live_xochi_order test/raxol/acp/xochi/live_order_test.exs

  Or use the runner: examples/run_live_acp_order_gate.sh

  Overrides: XOCHI_ORDER_CORRIDORS ("from>to,from>to" or "mesh"),
  XOCHI_ORDER_TOKENS, XOCHI_ORDER_AMOUNT, XOCHI_ORDER_WETH_AMOUNT,
  XOCHI_ORDER_DESTINATION, XOCHI_ORDER_ALLOW_ETH_ORIGIN, XOCHI_ORDER_SOLVER,
  XOCHI_ORDER_SOLVER_PIN, XOCHI_ORDER_RPC_<chain>.
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi_order
  @moduletag timeout: 600_000

  if System.get_env("XOCHI_ORDER_LIVE_URL") && System.get_env("XOCHI_ORDER_LIVE_KEY") do
    alias Raxol.ACP.{ContractClient, Job}
    alias Raxol.ACP.ContractClient.InMemory
    alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
    alias Raxol.ACP.Onchain.Permit2Approver
    alias Raxol.ACP.ProviderAdapter.JSONRPC
    alias Raxol.ACP.Xochi.TransferOffering
    alias Raxol.Payments.Assets
    alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    # Riddler's universal solver (HD index-0); the pinned origin-pull recipient.
    @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"
    @evm_chains [1, 10, 137, 8453, 42_161]

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "XOCHI_ORDER_LIVE_KEY"
    end

    setup do
      pin_live_solver()

      url = System.fetch_env!("XOCHI_ORDER_LIVE_URL")
      token = System.get_env("XOCHI_ORDER_LIVE_TOKEN", "")
      wallet_address = LiveWallet.address()
      xochi_config = %{base_url: url, auth_token: token}

      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        wallet_address: wallet_address,
        xochi_config: xochi_config,
        xochi_wallet: LiveWallet,
        poll_timeout_ms: 180_000
      )

      ensure_registered()
      on_exit(fn -> Application.delete_env(:raxol_acp, :xochi_transfer_settler) end)

      cfg = %{
        xochi_config: xochi_config,
        wallet_address: wallet_address,
        destination: System.get_env("XOCHI_ORDER_DESTINATION", wallet_address),
        stable_amount: System.get_env("XOCHI_ORDER_AMOUNT", "1.10")
      }

      {:ok, cfg: cfg}
    end

    @tag :live_xochi_order_preflight
    test "the offering is discoverable and every cell quotes read-only", %{cfg: cfg} do
      assert {:ok, spec} = OfferingRegistry.lookup(TransferOffering.offering_name())
      assert spec.handler == TransferOffering

      cells = cells()
      IO.puts("[live_xochi_order:preflight] checking #{length(cells)} cells (NO funds move)")

      results =
        Enum.map(cells, fn {from, to, token} ->
          outcome = preflight_cell(cfg, from, to, token)
          report_preflight(from, to, token, outcome)
          {{from, to, token}, outcome}
        end)

      # A pin mismatch (wrong solver served) is a hard failure; a cell the solver
      # simply cannot fill yet is a soft note (the funded run skips it).
      failures = for {cell, {:error, reason}} <- results, do: {cell, reason}

      assert failures == [],
             "preflight failed for #{length(failures)} cell(s), no funds moved: #{inspect(failures)}"
    end

    @tag :live_xochi_order_settle
    test "a buyer orders the offering and the seller settles the fillable subset", %{cfg: cfg} do
      cells = cells()
      IO.puts("[live_xochi_order] ordering #{length(cells)} cells through the ACP (REAL funds)")

      for cell <- cells, do: run_cell(cfg, cell)
    end

    # -- Cell iteration --

    defp cells do
      corridors = parse_corridors(System.get_env("XOCHI_ORDER_CORRIDORS", "8453>42161"))
      tokens = parse_list(System.get_env("XOCHI_ORDER_TOKENS", "USDC,USDT,WETH"))
      for {from, to} <- corridors, token <- tokens, do: {from, to, token}
    end

    defp run_cell(cfg, {from, to, token}) do
      label = "#{from}->#{to}:#{token}"

      if from == 1 and System.get_env("XOCHI_ORDER_ALLOW_ETH_ORIGIN") != "true" do
        IO.puts(
          "[live_xochi_order] SKIP #{label}: Ethereum origin is quote-only " <>
            "(set XOCHI_ORDER_ALLOW_ETH_ORIGIN=true to settle from L1)"
        )
      else
        run_fillable_cell(cfg, from, to, token, label)
      end
    end

    # Only order a cell the solver can fill now, and (for USDT/WETH) only once the
    # Permit2 allowance is in place. A non-fillable cell or a missing RPC is a
    # logged skip, not a failure -- this is the fillable subset.
    defp run_fillable_cell(cfg, from, to, token, label) do
      with {:ok, _quote} <- preflight_quote(cfg, from, to, token),
           {:ok, _allowance} <- ensure_permit2(from, token, cfg.wallet_address) do
        order_cell(cfg, from, to, token, label)
      else
        {:error, reason} ->
          IO.puts("[live_xochi_order] SKIP #{label}: #{inspect(reason)}; no funds moved")
      end
    end

    # -- Order one cell through the ACP job lifecycle --

    defp order_cell(cfg, from, to, token, label) do
      requirement = requirement(cfg, from, to, token)

      {:ok, job_id} =
        ContractClient.create_job(cfg.wallet_address, cfg.wallet_address, future_ts())

      {:ok, _pid} =
        Job.Supervisor.start_job(
          job_id: job_id,
          handler: TransferOffering,
          request: requirement,
          buyer: cfg.wallet_address,
          seller: cfg.wallet_address
        )

      assert {:ok, :negotiation} = Job.Server.accept_request(job_id),
             "#{label}: seller rejected the request (job #{job_id})"

      assert {:ok, :transaction} = Job.Server.accept_payment(job_id, %{})

      started = System.monotonic_time(:millisecond)

      assert {:ok, :evaluation} = Job.Server.deliver(job_id),
             "#{label}: settlement did not deliver (job #{job_id}); the intent failed or expired"

      deliverable = deliverable_from_memos(job_id, label)

      assert is_binary(deliverable["intent_id"])
      assert deliverable["status"] in ["completed", "settled"]

      assert deliverable["src_tx_hash"] =~ ~r/^0x[0-9a-fA-F]{64}$/,
             "#{label}: deliverable missing a settlement tx hash: #{inspect(deliverable)}"

      report_settlement(label, to, deliverable, started)
    end

    defp requirement(cfg, from, to, token) do
      {:ok, src_token} = Assets.address(from, token)
      {:ok, dst_token} = Assets.address(to, token)

      %{
        "src_chain_id" => from,
        "dst_chain_id" => to,
        "src_token" => src_token,
        "dst_token" => dst_token,
        "amount_atomic" => amount_atomic(from, token, cfg.stable_amount),
        "destination" => cfg.destination,
        "slippage_bps" => 50,
        "settlement_preference" => "public"
      }
    end

    defp deliverable_from_memos(job_id, label) do
      case Enum.find(InMemory.list_memos(job_id), &(&1.next_phase == :evaluation)) do
        nil -> flunk("#{label}: no evaluation memo for job #{job_id}")
        memo -> Jason.decode!(memo.content)
      end
    end

    # -- Read-only quote (fillability + solver pin) --

    defp preflight_quote(cfg, from, to, token) do
      with {:ok, request} <- quote_request(cfg, from, to, token),
           {:ok, quote} <- XochiProtocol.get_quote(cfg.xochi_config, request),
           {:solve, true} <- {:solve, quote.can_solve},
           :ok <- XochiProtocol.validate_pull(quote, request, LiveWallet) do
        {:ok, quote}
      else
        {:solve, _} -> {:error, :cannot_solve}
        other -> other
      end
    end

    # For the preflight report, split "cannot solve yet" (soft) from a real
    # failure like a solver-pin mismatch (hard).
    defp preflight_cell(cfg, from, to, token) do
      case preflight_quote(cfg, from, to, token) do
        {:ok, quote} -> {:ok, %{method: quote.payment_method, to_amount: quote.to_amount}}
        {:error, :cannot_solve} -> {:soft, :cannot_solve}
        {:error, reason} -> {:error, reason}
      end
    end

    defp quote_request(cfg, from, to, token) do
      with {:ok, src_token} <- Assets.address(from, token),
           {:ok, dst_token} <- Assets.address(to, token) do
        {:ok,
         %QuoteRequest{
           wallet: cfg.wallet_address,
           from_chain_id: from,
           to_chain_id: to,
           from_token: src_token,
           to_token: dst_token,
           from_amount: amount_atomic(from, token, cfg.stable_amount),
           settlement_preference: "public",
           slippage_bps: 50
         }}
      else
        :error -> {:error, {:unknown_token, token}}
      end
    end

    # -- Permit2 allowance (USDT/WETH only) --

    defp ensure_permit2(from, token, owner) do
      if permit2_token?(token) do
        with {:ok, provider} <- provider_for(from),
             {:ok, src_token} <- Assets.address(from, token) do
          Permit2Approver.ensure_allowance(provider, from, src_token, owner)
        else
          :error -> {:error, {:unknown_token, token}}
          {:error, _} = err -> err
        end
      else
        {:ok, :not_needed}
      end
    end

    defp provider_for(chain) do
      case System.get_env("XOCHI_ORDER_RPC_#{chain}") do
        nil ->
          {:error, {:no_rpc_for_chain, chain, "set XOCHI_ORDER_RPC_#{chain}"}}

        url ->
          key = decode_key(System.fetch_env!("XOCHI_ORDER_LIVE_KEY"))
          {:ok, JSONRPC.new(chains: %{chain => url}, private_key: key)}
      end
    end

    # -- Solver pin (scoped to this module, restored on exit) --

    defp pin_live_solver do
      if System.get_env("XOCHI_ORDER_SOLVER_PIN", "true") != "false" do
        solver = System.get_env("XOCHI_ORDER_SOLVER", @canonical_solver)
        prior_allowlist = Application.get_env(:raxol_payments, :pull_solver_allowlist)
        prior_require = Application.get_env(:raxol_payments, :pull_require_solver_pin)

        Application.put_env(:raxol_payments, :pull_solver_allowlist, [solver])
        Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

        on_exit(fn ->
          restore_env(:pull_solver_allowlist, prior_allowlist)
          restore_env(:pull_require_solver_pin, prior_require)
        end)
      end
    end

    defp restore_env(key, nil), do: Application.delete_env(:raxol_payments, key)
    defp restore_env(key, value), do: Application.put_env(:raxol_payments, key, value)

    # -- Helpers --

    defp ensure_registered do
      case OfferingRegistry.lookup(TransferOffering.offering_name()) do
        {:ok, _spec} -> :ok
        :error -> TransferOffering.register()
      end
    end

    defp amount_atomic(from, token, stable_amount) do
      {:ok, src_token} = Assets.address(from, token)
      decimals = Assets.decimals(from, src_token)
      Integer.to_string(Assets.to_atomic(Decimal.new(amount_for(token, stable_amount)), decimals))
    end

    defp amount_for("WETH", _stable), do: System.get_env("XOCHI_ORDER_WETH_AMOUNT", "0.001")
    defp amount_for(_token, stable), do: stable

    defp permit2_token?(token), do: String.upcase(token) in ["USDT", "WETH"]

    defp parse_corridors(spec) when spec in ["mesh", "all"] do
      for from <- @evm_chains, to <- @evm_chains, from != to, do: {from, to}
    end

    defp parse_corridors(spec) do
      spec
      |> String.split(",", trim: true)
      |> Enum.map(fn pair ->
        [from, to] = String.split(pair, ">", parts: 2)
        {String.to_integer(String.trim(from)), String.to_integer(String.trim(to))}
      end)
    end

    defp parse_list(spec), do: spec |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    defp future_ts, do: System.system_time(:second) + 3600

    defp decode_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
    defp decode_key(hex), do: Base.decode16!(hex, case: :mixed)

    # -- Reporting --

    defp report_preflight(from, to, token, {:ok, info}) do
      IO.puts(
        "  PASS #{from}->#{to} #{token} via #{info.method || "?"} (to_amount #{info.to_amount})"
      )
    end

    defp report_preflight(from, to, token, {:soft, :cannot_solve}) do
      IO.puts(
        "  SKIP #{from}->#{to} #{token}: solver cannot fill this cell yet (no funds needed)"
      )
    end

    defp report_preflight(from, to, token, {:error, reason}) do
      IO.puts("  FAIL #{from}->#{to} #{token}: #{inspect(reason)}")
    end

    defp report_settlement(label, to_chain, deliverable, started_ms) do
      elapsed = System.monotonic_time(:millisecond) - started_ms

      IO.puts("""

      [live_xochi_order:#{label}] settled in #{elapsed}ms
        intent_id     #{deliverable["intent_id"]}
        status        #{deliverable["status"]}
        src tx        #{tx_line(deliverable["src_tx_hash"], to_chain)}
        dst tx        #{tx_line(deliverable["dst_tx_hash"], to_chain)}\
      """)
    end

    defp tx_line(nil, _chain_id), do: "(none reported)"

    defp tx_line(hash, chain_id) do
      case explorer_base(chain_id) do
        nil -> hash
        base -> base <> hash
      end
    end

    defp explorer_base(1), do: "https://etherscan.io/tx/"
    defp explorer_base(8453), do: "https://basescan.org/tx/"
    defp explorer_base(42_161), do: "https://arbiscan.io/tx/"
    defp explorer_base(10), do: "https://optimistic.etherscan.io/tx/"
    defp explorer_base(137), do: "https://polygonscan.com/tx/"
    defp explorer_base(_), do: nil
  end
end
