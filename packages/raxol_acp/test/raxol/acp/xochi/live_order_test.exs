defmodule Raxol.ACP.Xochi.LiveOrderTest do
  @moduledoc """
  Live gate: a buyer orders the `xochi_stable_public` ACP offering and the seller
  settles it for real through Xochi + the Riddler solver. Moves real funds.

  The buyer quotes and signs a Xochi intent itself
  (`Raxol.Payments.Protocols.Xochi.quote_and_sign/3`), embeds the signed bundle in
  the job requirement's `signed_intent`, and the seller's `StablePublicOffering`
  relays it via `Raxol.ACP.Xochi.Settler` -> `execute_signed/2` (no re-signing) and
  polls.
  Job orchestration is in-process (`ProviderAdapter.Mock` stands in for the on-chain
  hook writes); only the settlement moves funds. The funded `LiveWallet` plays every
  role -- buyer, provider, and recipient (the Xochi `QuoteRequest` has no separate
  recipient, so funds return to the funded key on the destination chain).

  Tagged `:live_xochi_order` (settle) and `:live_xochi_order_preflight`
  (read-only); excluded by default, compiled only when the env is present.

      XOCHI_ORDER_LIVE_URL=https://api.xochi.fi \\
      XOCHI_ORDER_LIVE_TOKEN=<Xochi Member token> XOCHI_ORDER_LIVE_KEY=0x<funded key> \\
      XOCHI_ORDER_RPC_8453=https://mainnet.base.org \\
        mix test --only live_xochi_order test/raxol/acp/xochi/live_order_test.exs

  Runner + full env/corridor reference (USDC/ERC-3009 vs USDT/WETH/USDG Permit2,
  Robinhood cross-asset corridors, mesh, and all `XOCHI_ORDER_*` overrides): the
  unified gate at the repo root, `scripts/run_live_gates.sh --route acp`.
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi_order
  @moduletag timeout: 600_000

  if System.get_env("XOCHI_ORDER_LIVE_URL") && System.get_env("XOCHI_ORDER_LIVE_KEY") do
    alias Raxol.ACP.{AssetToken, Chain, JobSession}
    alias Raxol.ACP.Offering.Registry, as: OfferingRegistry
    alias Raxol.ACP.Onchain.Permit2Approver
    alias Raxol.ACP.ProviderAdapter
    alias Raxol.ACP.ProviderAdapter.JSONRPC
    alias Raxol.ACP.Xochi.StablePublicOffering
    alias Raxol.Payments.Assets
    alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    # Riddler's universal solver (HD index-0); the pinned origin-pull recipient.
    @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"
    # The six settleable EVM chains. Robinhood Chain (4663) has no USDC, only
    # USDG, so a stablecoin corridor touching it is cross-asset (USDG on the
    # Robinhood leg); see leg_symbol/2. USDG pulls via Permit2, never ERC-3009.
    @evm_chains [1, 10, 137, 8453, 42_161, 4663]

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "XOCHI_ORDER_LIVE_KEY"
    end

    setup do
      pin_live_solver()
      maybe_enable_corridor_allowlist()

      url = System.fetch_env!("XOCHI_ORDER_LIVE_URL")
      token = System.get_env("XOCHI_ORDER_LIVE_TOKEN", "")
      wallet_address = LiveWallet.address()
      xochi_config = %{base_url: url, auth_token: token}

      # The relay Settler needs only :xochi_config (it never signs).
      Application.put_env(:raxol_acp, :xochi_transfer_settler,
        xochi_config: xochi_config,
        poll_timeout_ms: 180_000
      )

      ensure_registered()
      on_exit(fn -> Application.delete_env(:raxol_acp, :xochi_transfer_settler) end)

      cfg = %{
        xochi_config: xochi_config,
        wallet_address: wallet_address,
        stable_amount: System.get_env("XOCHI_ORDER_AMOUNT", "1.10")
      }

      {:ok, cfg: cfg}
    end

    @tag :live_xochi_order_preflight
    test "the offering is discoverable and every cell quotes read-only", %{cfg: cfg} do
      assert {:ok, spec} = OfferingRegistry.lookup(StablePublicOffering.offering_name())
      assert spec.handler == StablePublicOffering

      cells = cells()
      log("preflight: checking #{length(cells)} cells (NO funds move)")

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
      log("ordering #{length(cells)} cells through the ACP (REAL funds)")

      for cell <- cells, do: run_cell(cfg, cell)
    end

    # -- Cell iteration --

    defp cells do
      corridors = parse_corridors(System.get_env("XOCHI_ORDER_CORRIDORS", "8453>42161"))
      tokens = parse_list(System.get_env("XOCHI_ORDER_TOKENS", "USDC,USDT,USDG"))
      for {from, to} <- corridors, token <- tokens, do: {from, to, token}
    end

    defp run_cell(cfg, {from, to, token}) do
      label = "#{from}->#{to}:#{token}"

      if from == 1 and System.get_env("XOCHI_ORDER_ALLOW_ETH_ORIGIN") != "true" do
        log(
          "SKIP #{label}: Ethereum origin is quote-only (set XOCHI_ORDER_ALLOW_ETH_ORIGIN=true)"
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
        {:error, reason} -> log("SKIP #{label}: #{inspect(reason)}; no funds moved")
      end
    end

    # -- Order one cell through the ACP job lifecycle --

    defp order_cell(cfg, from, to, token, label) do
      # The BUYER quotes + signs the Xochi intent itself; the signed bundle rides
      # in the requirement. raxol (the offering) relays it -- it never re-signs.
      {:ok, request} = quote_request(cfg, from, to, token)

      {:ok, bundle} = XochiProtocol.quote_and_sign(cfg.xochi_config, request, LiveWallet)

      requirement = requirement(cfg, from, to, token, bundle)

      # Drive the v2 provider directly. The job orchestration is local (a
      # ProviderAdapter.Mock stands in for the on-chain hook writes); only the
      # SETTLEMENT inside handle_deliver is real and moves funds.
      chain_id = 8453
      job_id = "live-order-#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        JobSession.Supervisor.start_session(chain_id: chain_id, job_id: job_id, role: :provider)

      provider =
        JobSession.Provider.new(
          session: {chain_id, job_id},
          handler: StablePublicOffering,
          adapter: ProviderAdapter.Mock.new(),
          chain_id: chain_id,
          acp_core_address: Chain.mainnet().acp_core_address,
          job_id: :erlang.phash2(job_id),
          buyer: cfg.wallet_address,
          seller: cfg.wallet_address
        )

      budget = AssetToken.usdc(Decimal.new("0.25"), chain_id)

      assert {:ok, %{status: :budget_set}} =
               JobSession.Provider.accept_request(provider, requirement, budget),
             "#{label}: seller rejected the request (job #{job_id})"

      # The client funds the escrow; mirror it before delivery.
      {:ok, :funded} = JobSession.apply_event({chain_id, job_id}, :funded, %{})

      started = System.monotonic_time(:millisecond)

      assert {:ok, %{status: :submitted, deliverable: deliverable}} =
               JobSession.Provider.deliver(provider, requirement),
             "#{label}: settlement did not deliver (job #{job_id}); the intent failed or expired"

      assert is_binary(deliverable["intent_id"])
      assert deliverable["status"] in ["completed", "settled"]

      assert deliverable["settlement_tx_hash"] =~ ~r/^0x[0-9a-fA-F]{64}$/,
             "#{label}: deliverable missing a settlement tx hash: #{inspect(deliverable)}"

      report_settlement(label, to, deliverable, started)
    end

    defp requirement(cfg, from, to, token, bundle) do
      {:ok, src_token} = Assets.address(from, leg_symbol(from, token))
      {:ok, dst_token} = Assets.address(to, leg_symbol(to, token))

      %{
        "src_chain_id" => from,
        "dst_chain_id" => to,
        "src_token" => src_token,
        "dst_token" => dst_token,
        "amount_atomic" => amount_atomic(from, token, cfg.stable_amount),
        "settlement_preference" => "public",
        "signed_intent" => bundle_to_json(bundle)
      }
    end

    # The bundle from quote_and_sign/3 is atom-keyed; the ACP requirement is JSON
    # (string keys). Stringify so valid_requirement?/execute_signed read it.
    defp bundle_to_json(bundle) do
      Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
    end

    # -- Read-only quote (fillability + solver pin) --

    defp preflight_quote(cfg, from, to, token) do
      with {:ok, request} <- quote_request(cfg, from, to, token),
           {:ok, quote} <- solver_quote(cfg, request),
           :ok <- XochiProtocol.validate_pull(quote, request, LiveWallet) do
        {:ok, quote}
      end
    end

    # A fillable quote, or a soft `:cannot_solve` when the solver reports it
    # cannot fill this cell right now -- whether it answers 200 with
    # can_solve:false OR a transient error whose body still says can_solve:false
    # (e.g. 503 "Solver temporarily unavailable"). Only a fillable quote proceeds
    # to the pull check (the hard, anti-drain solver-pin assertion). A genuine
    # error (auth, connection, an unexpected shape) stays hard, so a real
    # misconfiguration is not masked as a per-cell skip.
    defp solver_quote(cfg, request) do
      case XochiProtocol.get_quote(cfg.xochi_config, request) do
        {:ok, %{can_solve: true} = quote} -> {:ok, quote}
        {:ok, %{can_solve: false}} -> {:error, :cannot_solve}
        {:error, {:http, _status, %{"can_solve" => false}}} -> {:error, :cannot_solve}
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
      with {:ok, src_token} <- Assets.address(from, leg_symbol(from, token)),
           {:ok, dst_token} <- Assets.address(to, leg_symbol(to, token)) do
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
      if permit2_origin?(from, token) do
        with {:ok, provider} <- provider_for(from),
             {:ok, src_token} <- Assets.address(from, leg_symbol(from, token)) do
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

        # With XochiPull enabled the origin pull routes to the verified per-chain
        # pull contracts, not the bare solver EOA -- trust those alongside the
        # pinned solver (Riddler #591; Raxol.Payments.Xochi.PullContracts).
        allowlist = Enum.uniq([solver | Raxol.Payments.Xochi.PullContracts.pull_recipients()])
        Application.put_env(:raxol_payments, :pull_solver_allowlist, allowlist)
        Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

        on_exit(fn ->
          restore_env(:pull_solver_allowlist, prior_allowlist)
          restore_env(:pull_require_solver_pin, prior_require)
        end)
      end
    end

    defp restore_env(key, nil), do: Application.delete_env(:raxol_payments, key)
    defp restore_env(key, value), do: Application.put_env(:raxol_payments, key, value)

    # Enable the launch corridor scope (USDC mesh, USDT arb/poly, USDG 4663 drain)
    # so this gate exercises the same allowlist production runs under. Opt-in via
    # XOCHI_ORDER_STABLECOIN_ALLOWLIST=true (the run_live_gates.sh acp route sets
    # it, driving one allowlist-valid corridor per asset); off by default so a raw
    # `mix test` with mixed default corridors is not gated.
    defp maybe_enable_corridor_allowlist do
      if System.get_env("XOCHI_ORDER_STABLECOIN_ALLOWLIST") == "true" do
        prior = Application.get_env(:raxol_acp, :stablecoin_corridors_only)
        Application.put_env(:raxol_acp, :stablecoin_corridors_only, true)
        on_exit(fn -> restore_acp_env(:stablecoin_corridors_only, prior) end)
      end
    end

    defp restore_acp_env(key, nil), do: Application.delete_env(:raxol_acp, key)
    defp restore_acp_env(key, value), do: Application.put_env(:raxol_acp, key, value)

    # -- Helpers --

    defp ensure_registered do
      case OfferingRegistry.lookup(StablePublicOffering.offering_name()) do
        {:ok, _spec} -> :ok
        :error -> StablePublicOffering.register()
      end
    end

    defp amount_atomic(from, token, stable_amount) do
      {:ok, src_token} = Assets.address(from, leg_symbol(from, token))
      decimals = Assets.decimals(from, src_token)
      Integer.to_string(Assets.to_atomic(Decimal.new(amount_for(token, stable_amount)), decimals))
    end

    defp amount_for("WETH", _stable), do: System.get_env("XOCHI_ORDER_WETH_AMOUNT", "0.001")
    defp amount_for(_token, stable), do: stable

    # The origin pull rail: USDC pulls via ERC-3009, everything else (USDT, WETH,
    # and Robinhood's USDG) via Permit2. Keyed on the ORIGIN leg's resolved token,
    # so a Robinhood-origin corridor (USDG) needs a Permit2 allowance even when the
    # logical corridor token is USDC.
    defp permit2_origin?(from, token), do: String.upcase(leg_symbol(from, token)) != "USDC"

    # Robinhood Chain (4663) carries no USDC/USDT: its only stablecoin is USDG. A
    # stablecoin corridor touching 4663 is therefore cross-asset (USDG on the
    # Robinhood leg, the requested stablecoin on the other) -- the fungible
    # stablecoin group the solver fills. Every non-Robinhood leg, and WETH
    # (canonical on 4663 too), passes through unchanged.
    defp leg_symbol(4663, token) do
      if stablecoin_symbol?(token), do: "USDG", else: token
    end

    defp leg_symbol(_chain, token), do: token

    defp stablecoin_symbol?(token), do: String.upcase(token) in ["USDC", "USDT", "DAI", "USDG"]

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

    defp decode_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
    defp decode_key(hex), do: Base.decode16!(hex, case: :mixed)

    # -- Reporting (one terse line per cell) --

    @explorers %{
      1 => "https://etherscan.io/tx/",
      10 => "https://optimistic.etherscan.io/tx/",
      137 => "https://polygonscan.com/tx/",
      8453 => "https://basescan.org/tx/",
      42_161 => "https://arbiscan.io/tx/"
    }

    defp log(msg), do: IO.puts("[live_xochi_order] " <> msg)

    defp report_preflight(from, to, token, outcome) do
      cell = "#{from}->#{to} #{asset_pair(from, to, token)}"

      log(
        case outcome do
          {:ok, %{method: m, to_amount: a}} -> "PASS #{cell} via #{m || "?"} (#{a})"
          {:soft, :cannot_solve} -> "SKIP #{cell}: solver cannot fill yet"
          {:error, reason} -> "FAIL #{cell}: #{inspect(reason)}"
        end
      )
    end

    # Render the corridor's asset pairing: "USDC" same-asset, "USDC->USDG" when a
    # Robinhood leg swaps a stablecoin for USDG, so the log shows the cross-asset fill.
    defp asset_pair(from, to, token) do
      f = leg_symbol(from, token)
      t = leg_symbol(to, token)
      if f == t, do: f, else: "#{f}->#{t}"
    end

    defp report_settlement(label, to_chain, deliverable, started_ms) do
      elapsed = System.monotonic_time(:millisecond) - started_ms
      settle = tx_line(deliverable["settlement_tx_hash"], to_chain)

      recv =
        case deliverable["receiving_tx_hash"] do
          nil -> ""
          hash -> " recv=" <> tx_line(hash, to_chain)
        end

      log(
        "#{label} settled #{elapsed}ms " <>
          "intent=#{deliverable["intent_id"]} status=#{deliverable["status"]} settle=#{settle}" <>
          recv
      )
    end

    defp tx_line(nil, _chain), do: "(none)"
    defp tx_line(hash, chain), do: Map.get(@explorers, chain, "") <> hash
  end
end
