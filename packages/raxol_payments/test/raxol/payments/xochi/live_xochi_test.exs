defmodule Raxol.Payments.Xochi.LiveXochiTest do
  @moduledoc """
  The full agent crosschain payment lifecycle against a real Xochi endpoint:
  `ExecuteXochiIntent` quotes, authorizes the spend, signs, and submits the
  intent; `PollXochiStatus` waits for `:completed`.

  Moves real funds. The endpoint is the Xochi worker (`api.xochi.fi`, or
  `api-stg.xochi.fi` for staging), which serves the `/api/intent/*` routes this
  client calls, applies trust-tier fees, and calls the Riddler solver internally.

  ## Auth (`XOCHI_LIVE_AUTH`)

  Defaults to `mandate`, the agent-native path: the funded gate key signs an
  EIP-712 delegation envelope and self-delegates (it is both the Member whose
  Trust Tier the worker applies and the agent that presents the envelope), which
  `Raxol.Payments.Req.Mandate` attaches as `X-Xochi-Delegation` on quote and
  execute. The worker scopes mandates to quote/execute/stealth_claim only, so
  status polling falls back to the Member service token (`XOCHI_LIVE_TOKEN`) --
  a mandate run therefore needs both the funded key and the service token. Set
  `XOCHI_LIVE_AUTH=member` to drive the whole lifecycle off the Member service
  token instead (the legacy path; the only option where x402 is disabled and no
  mandate is provisioned).

  Defaults are mainnet Base -> Arbitrum USDC at 10 USDC. Settlement defaults to
  `public`; set `XOCHI_LIVE_SETTLEMENT=stealth` with `XOCHI_LIVE_RECIPIENT_META`
  to exercise the private path. The worker returns `can_solve: false` for an
  amount the solver cannot price, so the test asserts on `can_solve`.

  Tagged `:live_xochi` and excluded by default. Compiled only when the required
  env is present, so opting in without it yields no tests.

      XOCHI_LIVE_URL=https://api.xochi.fi \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential')" \\
      XOCHI_LIVE_KEY=0x<funded Base mainnet private key> \\
        mix test --include live_xochi test/raxol/payments/xochi/live_xochi_test.exs

  Or use the runner: examples/run_live_xochi_gate.sh

  Overrides: XOCHI_LIVE_AUTH, XOCHI_LIVE_AGENT_WALLET, XOCHI_LIVE_FROM_CHAIN,
  XOCHI_LIVE_TO_CHAIN, XOCHI_LIVE_FROM_TOKEN, XOCHI_LIVE_TO_TOKEN,
  XOCHI_LIVE_AMOUNT, XOCHI_LIVE_SETTLEMENT, XOCHI_LIVE_RECIPIENT_META,
  XOCHI_LIVE_SOLVER, XOCHI_LIVE_SOLVER_PIN.

  ## Solver pin

  The gate enforces the origin-pull solver pin by default: the pull recipient
  (`to` for ERC-3009, `spender` for Permit2) must equal the canonical Riddler
  solver `0x97D447561fDe10E959E782a29411D8F89586d80b`, so a forged or MITM'd
  quote that retargets the pull aborts before any signature. Override the pinned
  address with `XOCHI_LIVE_SOLVER` (a solver rotation is an env change), or set
  `XOCHI_LIVE_SOLVER_PIN=false` to disable the pin while debugging. The pin is
  scoped to this module -- it does not change config for the rest of the suite.

  ## Matrix mode

  `XOCHI_LIVE_MATRIX=true` adds one test that settles every configured corridor
  for each token and settlement type -- the live counterpart of
  `settlement_matrix_test.exs`. It moves real funds per cell (corridor x token x
  settlement), so it is bounded by env:

  - `XOCHI_LIVE_CORRIDORS` -- `"from>to,from>to"` chain-id pairs (default
    `"8453>42161,42161>8453"`), or `"mesh"` for every ordered pair of the five
    supported EVM chains (1, 10, 137, 8453, 42161). Tokens resolve per chain via
    `Raxol.Payments.Assets`.
  - `XOCHI_LIVE_TOKENS` -- `"USDC,USDT,WETH"` (default `"USDC"`). USDC pulls via
    ERC-3009; USDT/WETH via Permit2 (needs a standing Permit2 allowance on each
    origin chain). The preflight asserts the served pull method per token
    (USDC -> erc3009, USDT/WETH -> permit2) read-only.
  - `XOCHI_LIVE_SETTLE_PERMIT2` -- set to `true` to settle USDT/WETH cells in the
    funded matrix. Off by default: those pulls need a standing Permit2 allowance
    this gate does not broadcast, so order them through raxol_acp
    (`run_live_acp_order_gate.sh`), which sets the allowance and settles for real.
    The funded matrix re-quotes each cell and skips (logs) any the solver cannot
    fill right now, settling only the fillable subset.
  - `XOCHI_LIVE_SETTLEMENTS` -- `"public,stealth"` (default `"public"`). Stealth
    cells require `XOCHI_LIVE_RECIPIENT_META`.
  - `XOCHI_LIVE_AMOUNT` -- per-cell stablecoin amount (default `1.10`, above the
    solver's >1 USDC floor).
  - `XOCHI_LIVE_WETH_AMOUNT` -- per-cell WETH amount (default `0.001`); WETH is
    18-decimal and worth thousands per unit, so it is sized separately.
  - `XOCHI_LIVE_ALLOW_ETH_ORIGIN` -- set to `true` to settle Ethereum-origin
    (chain 1) cells; by default they are skipped (quote-only) for L1 gas cost.

  A companion `:live_xochi_preflight` test quotes every corridor x token
  read-only (no funds) and asserts `can_solve` plus the pinned origin-pull
  solver, so a bad corridor, unpriceable amount, or rotated solver is caught
  before any funded run. `examples/run_live_xochi_gate.sh` runs it first.

  Run only the matrix:

      XOCHI_LIVE_URL=https://api.xochi.fi \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential')" \\
      XOCHI_LIVE_KEY=0x<funded key> \\
      XOCHI_LIVE_MATRIX=true \\
      XOCHI_LIVE_TOKENS=USDC,USDT,WETH \\
      XOCHI_LIVE_SETTLEMENTS=public,stealth \\
      XOCHI_LIVE_RECIPIENT_META=st:eth:0x... \\
        mix test --only live_xochi_matrix test/raxol/payments/xochi/live_xochi_test.exs
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi
  # Live settlement can take longer than the ExUnit default.
  @moduletag timeout: 300_000

  if System.get_env("XOCHI_LIVE_URL") && System.get_env("XOCHI_LIVE_KEY") do
    alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
    alias Raxol.Payments.{Assets, Ledger, Mandate, SpendingPolicy}
    alias Raxol.Payments.Mandate.Store, as: MandateStore
    alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
    alias Raxol.Payments.Xochi.Schemas.QuoteRequest

    # Riddler's universal solver (HD index-0), the address it serves as the
    # origin-pull `to`/`spender`. The default pin; rotate via XOCHI_LIVE_SOLVER.
    @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"

    defmodule LiveWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "XOCHI_LIVE_KEY"
    end

    setup do
      pin_live_solver()

      url = System.fetch_env!("XOCHI_LIVE_URL")
      host = url |> URI.parse() |> Map.get(:host)
      member_token = System.get_env("XOCHI_LIVE_TOKEN", "")
      ledger = start_supervised!({Ledger, [name: nil]})

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("50.00"),
        session_max: Decimal.new("100.00"),
        lifetime_max: Decimal.new("500.00"),
        session_window_ms: 3_600_000,
        approved_domains: [host]
      }

      {exec_config, poll_config} =
        auth_configs(System.get_env("XOCHI_LIVE_AUTH", "mandate"), url, member_token)

      context = %{
        wallet: LiveWallet,
        xochi_config: exec_config,
        ledger: ledger,
        policy: policy,
        agent_id: :live_gate
      }

      # Status/history are not mandate scopes, so polling authenticates with the
      # Member service token even when quote/execute go through a mandate.
      {:ok, context: context, poll_context: %{context | xochi_config: poll_config}}
    end

    # Enforce the origin-pull solver pin for the gate: the pull recipient/spender
    # must equal the canonical solver, so a forged or MITM'd quote that retargets
    # the pull aborts before any signature. Scoped here and restored on exit, so
    # the rest of the suite keeps its own (unpinned) config. Override the address
    # with XOCHI_LIVE_SOLVER; set XOCHI_LIVE_SOLVER_PIN=false to opt out.
    defp pin_live_solver do
      if System.get_env("XOCHI_LIVE_SOLVER_PIN", "true") != "false" do
        solver = System.get_env("XOCHI_LIVE_SOLVER", @canonical_solver)
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

    test "agent completes a crosschain payment end-to-end", %{
      context: context,
      poll_context: poll_context
    } do
      params =
        %{
          amount: System.get_env("XOCHI_LIVE_AMOUNT", "10.00"),
          from_chain_id: env_int("XOCHI_LIVE_FROM_CHAIN", 8453),
          to_chain_id: env_int("XOCHI_LIVE_TO_CHAIN", 42_161),
          from_token:
            System.get_env("XOCHI_LIVE_FROM_TOKEN", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
          to_token:
            System.get_env("XOCHI_LIVE_TO_TOKEN", "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
          settlement: System.get_env("XOCHI_LIVE_SETTLEMENT", "public")
        }
        |> maybe_put_recipient()

      started = System.monotonic_time(:millisecond)
      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      assert is_binary(intent.intent_id)

      assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, poll_context)
      assert status.terminal == true

      assert status.status == "completed",
             "live intent #{intent.intent_id} ended in #{status.status}, expected completed"

      report_settlement("end-to-end", intent, status, params, started)
    end

    test "a resumed run reuses the in-flight intent without a second signature", %{
      context: context,
      poll_context: poll_context
    } do
      # The crash-recovery path: an idempotency checkpoint lets a re-run of the
      # same payment resume the dispatched intent instead of quoting and signing
      # again. One real settlement; the second call must not move funds.
      store = Raxol.Payments.Checkpoint.ETS.new()
      context = Map.merge(context, %{checkpoint: store, idempotency_key: "live-resume"})

      params =
        %{
          amount: System.get_env("XOCHI_LIVE_AMOUNT", "10.00"),
          from_chain_id: env_int("XOCHI_LIVE_FROM_CHAIN", 8453),
          to_chain_id: env_int("XOCHI_LIVE_TO_CHAIN", 42_161),
          from_token:
            System.get_env("XOCHI_LIVE_FROM_TOKEN", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"),
          to_token:
            System.get_env("XOCHI_LIVE_TO_TOKEN", "0xaf88d065e77c8cc2239327c5edb3a432268e5831"),
          settlement: System.get_env("XOCHI_LIVE_SETTLEMENT", "public")
        }
        |> maybe_put_recipient()

      started = System.monotonic_time(:millisecond)
      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      assert is_binary(intent.intent_id)
      charged = lifetime(context)

      # The agent "restarts" and runs the same payment; recovery resumes it.
      assert {:ok, resumed} = ExecuteXochiIntent.call(params, context)

      assert resumed.intent_id == intent.intent_id,
             "resume signed a new intent #{resumed.intent_id} instead of reusing #{intent.intent_id}"

      assert Decimal.equal?(lifetime(context), charged),
             "resume charged the ledger a second time"

      assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, poll_context)
      assert status.terminal == true

      assert status.status == "completed",
             "live intent #{intent.intent_id} ended in #{status.status}, expected completed"

      report_settlement("crash-resume", intent, status, params, started)
    end

    # Opt-in matrix: settle every configured corridor for each settlement type in
    # one run -- the live counterpart of `settlement_matrix_test.exs`. Each cell
    # moves real funds, so it is compile-gated behind `XOCHI_LIVE_MATRIX=true` and
    # bounded by `XOCHI_LIVE_CORRIDORS` ("from>to,from>to"; default Base<->Arbitrum),
    # `XOCHI_LIVE_SETTLEMENTS` ("public,stealth"; default public), and
    # `XOCHI_LIVE_AMOUNT` per cell. Stealth cells need `XOCHI_LIVE_RECIPIENT_META`.
    # Run it alone with `--only live_xochi_matrix`.
    if System.get_env("XOCHI_LIVE_MATRIX") == "true" do
      @tag :live_xochi_matrix
      test "settles every configured corridor for each token and settlement type", %{
        context: context,
        poll_context: poll_context
      } do
        corridors =
          parse_corridors(System.get_env("XOCHI_LIVE_CORRIDORS", "8453>42161,42161>8453"))

        tokens = parse_list(System.get_env("XOCHI_LIVE_TOKENS", "USDC"))
        settlements = parse_list(System.get_env("XOCHI_LIVE_SETTLEMENTS", "public"))
        stable_amount = System.get_env("XOCHI_LIVE_AMOUNT", "1.10")
        meta = System.get_env("XOCHI_LIVE_RECIPIENT_META")

        cells =
          for {from, to} <- corridors, token <- tokens, s <- settlements, do: {from, to, token, s}

        IO.puts(
          "[live_xochi:matrix] running #{length(cells)} cells (corridor x token x settlement)"
        )

        for {from, to, token, settlement} <- cells do
          label = "#{from}->#{to}:#{token}:#{settlement}"

          cond do
            settlement == "stealth" and is_nil(meta) ->
              flunk("stealth cell #{label} needs XOCHI_LIVE_RECIPIENT_META")

            # Ethereum-origin settlement burns real L1 gas and has no confirmed
            # instant-settlement inventory; keep it quote-only unless opted in.
            from == 1 and System.get_env("XOCHI_LIVE_ALLOW_ETH_ORIGIN") != "true" ->
              IO.puts(
                "[live_xochi:matrix] SKIP #{label}: Ethereum origin is quote-only " <>
                  "(set XOCHI_LIVE_ALLOW_ETH_ORIGIN=true to settle from L1)"
              )

            # USDT/WETH pull via Permit2, which needs a standing on-chain allowance
            # this gate does not broadcast (raxol_payments holds no tx code). Set the
            # allowance via the ACP order gate, then opt in with XOCHI_LIVE_SETTLE_PERMIT2.
            permit2_token?(token) and System.get_env("XOCHI_LIVE_SETTLE_PERMIT2") != "true" ->
              IO.puts(
                "[live_xochi:matrix] SKIP #{label}: #{token} pulls via Permit2 and needs a " <>
                  "standing allowance. Order it through raxol_acp (run_live_acp_order_gate.sh), " <>
                  "or set XOCHI_LIVE_SETTLE_PERMIT2=true once the allowance is in place."
              )

            true ->
              settle_fillable_cell(
                {context, poll_context},
                {from, to, token, settlement},
                stable_amount,
                meta,
                label
              )
          end
        end
      end

      # Settle one matrix cell, but only if the solver can actually fill it now:
      # re-quote read-only first and skip (log) a non-fillable cell instead of
      # failing the whole run. Implements "settle the fillable subset".
      defp settle_fillable_cell(
             {context, poll_context},
             {from, to, token, settlement},
             stable_amount,
             meta,
             label
           ) do
        amount = amount_for(token, stable_amount)

        case preflight_cell(context, from, to, token, amount) do
          {:error, reason} ->
            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: not fillable now " <>
                "(#{inspect(reason)}); no funds moved"
            )

          {:ok, _info} ->
            params = matrix_params(from, to, token, settlement, amount, meta)
            settle_and_assert({context, poll_context}, params, label)
        end
      end

      defp settle_and_assert({context, poll_context}, params, label) do
        started = System.monotonic_time(:millisecond)

        assert {:ok, intent} = ExecuteXochiIntent.call(params, context),
               "execute failed for #{label}"

        assert {:ok, status} = PollXochiStatus.call(%{intent_id: intent.intent_id}, poll_context)
        assert status.terminal == true

        assert status.status == "completed",
               "#{label} (#{intent.intent_id}) ended #{status.status}"

        report_settlement(label, intent, status, params, started)
      end

      defp permit2_token?(token), do: String.upcase(token) in ["USDT", "WETH"]

      @tag :live_xochi_preflight
      test "every configured corridor x token quotes can_solve and serves the pinned solver", %{
        context: context
      } do
        corridors =
          parse_corridors(System.get_env("XOCHI_LIVE_CORRIDORS", "8453>42161,42161>8453"))

        tokens = parse_list(System.get_env("XOCHI_LIVE_TOKENS", "USDC"))
        stable_amount = System.get_env("XOCHI_LIVE_AMOUNT", "1.10")
        cells = for {from, to} <- corridors, token <- tokens, do: {from, to, token}

        IO.puts(
          "[live_xochi:preflight] checking #{length(cells)} cells read-only (NO funds move)"
        )

        results =
          Enum.map(cells, fn {from, to, token} ->
            outcome = preflight_cell(context, from, to, token, amount_for(token, stable_amount))
            report_preflight(from, to, token, outcome)
            {{from, to, token}, outcome}
          end)

        failures = for {cell, {:error, reason}} <- results, do: {cell, reason}

        assert failures == [],
               "preflight failed for #{length(failures)} cell(s), no funds moved: #{inspect(failures)}"
      end

      # Quote one corridor x token read-only and confirm the solver can fill it and
      # serves the pinned origin-pull recipient/spender. No spend gate, no signature,
      # no execute -- nothing moves. Public settlement is enough: can_solve and the
      # pull pin are independent of the settlement privacy.
      defp preflight_cell(context, from, to, token, amount) do
        config = context.xochi_config
        wallet = context.wallet

        with {:ok, request} <- preflight_request(wallet, from, to, token, amount),
             {:ok, quote} <- XochiProtocol.get_quote(config, request),
             :ok <- preflight_can_solve(quote),
             :ok <- preflight_method(token, quote.payment_method),
             :ok <- XochiProtocol.validate_pull(quote, request, wallet) do
          {:ok, %{method: quote.payment_method, to_amount: quote.to_amount, fee: quote.xochi_fee}}
        end
      end

      # USDC pulls via ERC-3009; USDT/WETH pull via Permit2. Asserting the served
      # method per token catches a token routed to the wrong rail (which would
      # otherwise fail on-chain at pull time) before any funds move.
      defp preflight_method(token, method) do
        want = expected_method(String.upcase(token))
        got = method && String.downcase(method)
        if got == want, do: :ok, else: {:error, {:method_mismatch, token, got, want}}
      end

      defp expected_method("USDC"), do: "erc3009"
      defp expected_method(_token), do: "permit2"

      defp preflight_request(wallet, from, to, token, amount) do
        with {:ok, from_token} <- Assets.address(from, token),
             {:ok, to_token} <- Assets.address(to, token) do
          decimals = Assets.decimals(from, from_token)
          from_amount = Integer.to_string(Assets.to_atomic(Decimal.new(amount), decimals))

          {:ok,
           %QuoteRequest{
             wallet: wallet.address(),
             from_chain_id: from,
             to_chain_id: to,
             from_token: from_token,
             to_token: to_token,
             from_amount: from_amount,
             settlement_preference: "public",
             slippage_bps: 50
           }}
        else
          :error -> {:error, {:unknown_token, token}}
        end
      end

      defp preflight_can_solve(%{can_solve: true}), do: :ok
      defp preflight_can_solve(%{error: err}), do: {:error, {:cannot_solve, err}}

      defp report_preflight(from, to, token, {:ok, info}) do
        IO.puts(
          "  PASS #{from}->#{to} #{token} via #{info.method || "?"}" <>
            " (to_amount #{info.to_amount}, fee #{info.fee})" <>
            preflight_notes(from, info.method)
        )
      end

      defp report_preflight(from, to, token, {:error, reason}) do
        IO.puts("  FAIL #{from}->#{to} #{token}: #{inspect(reason)}")
      end

      # Per-cell operator notes that are not failures: an L1 origin costs real gas,
      # and a Permit2 pull (USDT/WETH) needs a standing allowance the gate does not
      # set, so a first run on a fresh wallet would revert the pull on-chain.
      defp preflight_notes(from, method) do
        l1 =
          if from == 1,
            do: " [eth-origin: L1 gas; quote-only unless XOCHI_LIVE_ALLOW_ETH_ORIGIN=true]",
            else: ""

        permit2 =
          if method == "permit2",
            do: " [permit2: needs a standing Permit2 allowance on chain #{from}]",
            else: ""

        l1 <> permit2
      end

      # The five supported EVM chains: Ethereum, Optimism, Polygon, Base, Arbitrum.
      @evm_chains [1, 10, 137, 8453, 42_161]

      # "mesh" (or "all") expands to every ordered pair of the five EVM chains (20
      # corridors), so the preflight validates the full grid in one run. The
      # explicit "from>to,from>to" form still works for a narrower run.
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

      defp parse_list(spec),
        do: spec |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

      # Per-token live amount. Stablecoins use XOCHI_LIVE_AMOUNT (USD-ish, default
      # 1.10, just above the solver's >1 USDC floor). WETH is 18-decimal and worth
      # thousands per unit, so it takes a small default well under the spend cap;
      # override with XOCHI_LIVE_WETH_AMOUNT.
      defp amount_for("WETH", _stable), do: System.get_env("XOCHI_LIVE_WETH_AMOUNT", "0.001")
      defp amount_for(_token, stable), do: stable

      defp matrix_params(from, to, token, settlement, amount, meta) do
        params = %{
          amount: amount,
          from_chain_id: from,
          to_chain_id: to,
          from_token: token_for(from, token),
          to_token: token_for(to, token),
          settlement: settlement
        }

        if settlement == "stealth",
          do: Map.put(params, :recipient_meta_address, meta),
          else: params
      end

      # Resolve a token symbol to its contract via Assets. An unknown token
      # raises here rather than mis-scaling the amount on the wire.
      defp token_for(chain, symbol) do
        case Assets.address(chain, symbol) do
          {:ok, address} ->
            address

          :error ->
            raise "no #{symbol} address for chain #{chain}; extend @evm_tokens in Raxol.Payments.Assets"
        end
      end
    end

    defp lifetime(context) do
      Ledger.get_totals(context.ledger, context.agent_id, context.policy).lifetime
    end

    # Build {execute, poll} client configs for the chosen auth mode. Mandate is the
    # agent-native default: the funded key presents an EIP-712 delegation envelope
    # it signed itself on quote/execute, inheriting its own Member tier. Status
    # polling is out of mandate scope, so it keeps the Member service token.
    defp auth_configs("mandate", url, member_token) do
      agent_wallet =
        "XOCHI_LIVE_AGENT_WALLET"
        |> System.get_env(LiveWallet.address())
        |> String.downcase()

      install_mandate(agent_wallet)

      {%{base_url: url, auth: {:mandate, agent_wallet}},
       %{base_url: url, auth_token: member_token}}
    end

    defp auth_configs(_member, url, member_token) do
      config = %{base_url: url, auth_token: member_token}
      {config, config}
    end

    # Sign and store a mandate the Req.Mandate plugin resolves by agent_wallet. The
    # funded key self-delegates: it is the human_wallet (the EIP-712 signer whose
    # tier the worker applies, and which must equal the quote wallet) and the
    # presenting agent. max_amount_usd: 0 caps by call count only -- the worker
    # prices a notional cap fee-inclusive, so a fixed cap risks tripping the gate.
    defp install_mandate(agent_wallet) do
      start_supervised!(MandateStore)

      {:ok, mandate} =
        Mandate.build(%{
          human_wallet: LiveWallet.address(),
          agent_wallet: agent_wallet,
          scopes: ["quote", "execute"],
          max_amount_usd: 0,
          max_calls: 50,
          expires_at: System.system_time(:second) + 3600
        })

      {:ok, signed} = Mandate.sign(mandate, LiveWallet)
      :ok = Mandate.verify(signed)
      :ok = MandateStore.put(signed)
    end

    defp maybe_put_recipient(params) do
      case System.get_env("XOCHI_LIVE_RECIPIENT_META") do
        nil -> params
        meta -> Map.put(params, :recipient_meta_address, meta)
      end
    end

    defp env_int(name, default) do
      case System.get_env(name) do
        nil -> default
        val -> String.to_integer(val)
      end
    end

    # Print the verifiable settlement artifacts so an operator running the gate can
    # confirm the real on-chain transfer independently and eyeball end-to-end latency.
    defp report_settlement(label, intent, status, params, started_ms) do
      elapsed = System.monotonic_time(:millisecond) - started_ms

      IO.puts("""

      [live_xochi:#{label}] settled in #{elapsed}ms
        intent_id     #{intent.intent_id}
        status        #{status.status}
        fill tx       #{tx_line(Map.get(status, :tx_hash), params.to_chain_id)}
        receiving tx  #{tx_line(Map.get(status, :receiving_tx_hash), params.to_chain_id)}\
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
