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
      XOCHI_LIVE_TOKEN=<Xochi Member token> XOCHI_LIVE_KEY=0x<funded Base key> \\
        mix test --include live_xochi test/raxol/payments/xochi/live_xochi_test.exs

  ## Solver pin

  The gate enforces the origin-pull solver pin by default: the pull recipient
  (`to` for ERC-3009, `spender` for Permit2) must equal the canonical Riddler
  solver `0x97D447561fDe10E959E782a29411D8F89586d80b`, so a forged or MITM'd
  quote that retargets the pull aborts before any signature. `XOCHI_LIVE_SOLVER`
  overrides the pinned address; `XOCHI_LIVE_SOLVER_PIN=false` disables the pin
  while debugging. The pin is scoped to this module.

  ## Matrix mode

  `XOCHI_LIVE_MATRIX=true` adds one test that settles every configured corridor
  (`XOCHI_LIVE_CORRIDORS`, or `"mesh"`) for each token and settlement type -- the
  live counterpart of `settlement_matrix_test.exs`. It moves real funds per cell,
  re-quotes each, and settles only the fillable subset (skipping eth-origin/dest,
  unpriced amounts, Permit2-without-allowance, and transient worker errors),
  failing only on a client integration fault. `XOCHI_LIVE_RECORD_MARGIN=true`
  prints a per-corridor fee-vs-gas margin + native-drain report after the sweep.
  A companion `:live_xochi_preflight` test quotes the settle-eligible subset
  read-only first (no funds), asserting `can_solve` and the pinned solver.

  Runner + full env/corridor reference (auth modes, all `XOCHI_LIVE_*` overrides,
  cross-asset Robinhood/USDG corridors, matrix bounds): the unified gate at the
  repo root, `scripts/run_live_gates.sh --route xochi`, runs preflight then matrix.
  """

  use ExUnit.Case, async: false

  @moduletag :live_xochi
  # Live settlement can take longer than the ExUnit default.
  @moduletag timeout: 300_000

  if System.get_env("XOCHI_LIVE_URL") && System.get_env("XOCHI_LIVE_KEY") do
    alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}

    alias Raxol.Payments.{
      Assets,
      ChainReader,
      Failure,
      Ledger,
      Mandate,
      Prices,
      SettlementLedger,
      SettlementRecorder,
      SpendingPolicy
    }

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

        recorder = margin_recorder()

        outcomes =
          for {from, to, token, settlement} <- cells do
            label = "#{from}->#{to}:#{token}:#{settlement}"

            skip = settle_skip_reason(from, to, token)

            cond do
              settlement == "stealth" and is_nil(meta) ->
                IO.puts("[live_xochi:matrix] FAULT #{label}: needs XOCHI_LIVE_RECIPIENT_META")
                {:fault, label, :missing_recipient_meta}

              # An env-gated skip the funded run does not settle by default: an
              # Ethereum-origin/destination cell (real L1 gas, drains mainnet ETH) or
              # a Permit2-pull cell that needs a standing on-chain allowance this gate
              # does not broadcast. Shared with the preflight via settle_skip_reason/3
              # so the two never disagree on what is in scope.
              skip != nil ->
                {reason, message} = skip
                IO.puts("[live_xochi:matrix] SKIP #{label}: #{message}")
                {:skipped, label, reason}

              true ->
                settle_fillable_cell(
                  {context, poll_context},
                  {from, to, token, settlement},
                  stable_amount,
                  meta,
                  label,
                  recorder
                )
            end
          end

        report_matrix_summary(outcomes)
        print_margin_report(recorder)
      end

      # Tally the per-cell outcomes and fail the run only on a client FAULT -- an
      # intent that could not be submitted (bad signature, spend gate, solver pin).
      # A submitted intent the solver does not fill is a logged SKIP, not a failure:
      # the matrix settles the fillable subset, so a corridor the solver cannot fund
      # right now must not abort the sweep. Prints a settled/skipped/fault summary.
      defp report_matrix_summary(outcomes) do
        settled = for {:settled, l} <- outcomes, do: l
        skipped = for {:skipped, l, r} <- outcomes, do: {l, r}
        faults = for {:fault, l, r} <- outcomes, do: {l, r}

        transient = for {l, {:transient, _}} <- skipped, do: l

        reconcile =
          for {l, {:poll_error, r}} <- skipped, r in [:stranded, :settlement_failed], do: {l, r}

        IO.puts("\n[live_xochi:matrix] summary")
        IO.puts("  settled  #{length(settled)}#{settled_list(settled)}")

        for {label, reason} <- skipped do
          IO.puts("  skip     #{label} (#{inspect(reason)})")
        end

        for {label, reason} <- faults do
          IO.puts("  FAULT    #{label} (#{inspect(reason)})")
        end

        IO.puts(
          "  totals   #{length(settled)} settled, #{length(skipped)} skipped " <>
            "(#{length(transient)} transient), #{length(faults)} fault(s)"
        )

        if transient != [] do
          IO.puts(
            "  note     #{length(transient)} corridor(s) hit a transient worker error; " <>
              "re-run for a verdict: #{Enum.join(transient, ", ")}"
          )
        end

        if reconcile != [] do
          IO.puts(
            "  RECONCILE #{length(reconcile)} intent(s) submitted but did not cleanly " <>
              "settle; funds may be in flight -- check: #{inspect(reconcile)}"
          )
        end

        assert faults == [],
               "matrix hit #{length(faults)} client fault(s) -- our integration bug " <>
                 "(bad signature / spend gate / solver pin / malformed request), not a " <>
                 "solver or worker condition: #{inspect(faults)}"
      end

      defp settled_list([]), do: ""
      defp settled_list(settled), do: ": " <> Enum.join(settled, ", ")

      # Opt-in P&L accounting (XOCHI_LIVE_RECORD_MARGIN=true): start a settlement
      # ledger + an on-chain reader so each settled fill's fee can be booked against
      # the native gas it burned. Returns nil (a no-op) when the flag is off, so a
      # normal run is unchanged.
      defp margin_recorder do
        if System.get_env("XOCHI_LIVE_RECORD_MARGIN") == "true" do
          table = String.to_atom("margin_#{System.unique_integer([:positive])}")
          ledger = start_supervised!({SettlementLedger, table_name: table})
          reader = ChainReader.JSONRPC.new(chains: rpc_urls())
          {ledger, reader}
        else
          nil
        end
      end

      # Read-only RPC per chain for receipt lookups. Public defaults, overridable
      # via XOCHI_LIVE_RPC_<chain_id>.
      defp rpc_urls do
        %{
          1 => System.get_env("XOCHI_LIVE_RPC_1", "https://eth.llamarpc.com"),
          10 => System.get_env("XOCHI_LIVE_RPC_10", "https://mainnet.optimism.io"),
          137 => System.get_env("XOCHI_LIVE_RPC_137", "https://polygon-rpc.com"),
          8453 => System.get_env("XOCHI_LIVE_RPC_8453", "https://mainnet.base.org"),
          42_161 => System.get_env("XOCHI_LIVE_RPC_42161", "https://arb1.arbitrum.io/rpc")
        }
      end

      # Build the closure poll_settlement calls on a completed fill. A nil recorder
      # yields a no-op so the settle path is unchanged when accounting is off.
      defp margin_record_fn(nil, _from, _to, _token, _params, _info),
        do: fn _intent, _status -> :ok end

      defp margin_record_fn({ledger, reader}, from, to, token, params, info) do
        fn intent, status ->
          SettlementRecorder.record(
            ledger,
            reader,
            %{
              intent_id: intent.intent_id,
              from_chain_id: from,
              to_chain_id: to,
              token_symbol: token,
              token_address: Map.get(params, :from_token),
              fee_collected: Map.get(info, :fee) || 0,
              tx_hash: Map.get(status, :tx_hash),
              settlement_type: settlement_type_atom(params)
            },
            record_pending: true
          )
        end
      end

      defp settlement_type_atom(params) do
        case Map.get(params, :settlement) do
          "public" -> :public
          "stealth" -> :stealth
          "shielded" -> :shielded
          _ -> nil
        end
      end

      # Per-corridor margin + native-drain summary after a recorded sweep. USD via
      # CoinGecko; unpriced entries degrade to raw totals ("n/a").
      defp print_margin_report(nil), do: :ok

      defp print_margin_report({ledger, _reader}) do
        report = SettlementLedger.report(ledger, price_fn: Prices.CoinGecko.price_fn())

        IO.puts("\n[live_xochi:margin] report (fee vs on-chain gas)")
        IO.puts("  totals      #{format_agg(report.totals)}")

        for {dest, agg} <- Enum.sort_by(report.destinations, &elem(&1, 0)) do
          IO.puts("  dest #{dest}    #{format_agg(agg)}")
        end

        for {chain, wei} <- Enum.sort_by(report.drain, &elem(&1, 0)) do
          native = wei |> Assets.to_human(18) |> Decimal.round(6) |> Decimal.to_string()
          IO.puts("  drain #{chain}   #{native} #{Assets.native_symbol(chain)}")
        end

        :ok
      end

      defp format_agg(agg) do
        "n=#{agg.count} fee_usd=#{fmt_usd(agg.usd_fee)} gas_usd=#{fmt_usd(agg.usd_gas)} " <>
          "margin_usd=#{fmt_usd(agg.usd_margin)} gas_unknown=#{agg.gas_unknown_count}"
      end

      defp fmt_usd(nil), do: "n/a"
      defp fmt_usd(%Decimal{} = d), do: "$" <> Decimal.to_string(Decimal.round(d, 4))

      # Settle one matrix cell, but only if the solver can actually fill it now:
      # re-quote read-only first and skip (log) a non-fillable cell instead of
      # failing the whole run. Implements "settle the fillable subset". Returns a
      # {:settled | :skipped | :fault, ...} outcome for the run summary.
      defp settle_fillable_cell(
             {context, poll_context},
             {from, to, token, settlement},
             stable_amount,
             meta,
             label,
             recorder
           ) do
        pace()
        amount = amount_for(token, stable_amount)

        case preflight_cell(context, from, to, token, amount) do
          {:error, reason} ->
            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: not fillable now " <>
                "(#{inspect(reason)}); no funds moved"
            )

            {:skipped, label, {:not_fillable, reason}}

          {:ok, info} ->
            params = matrix_params(from, to, token, settlement, amount, meta)
            record_fn = margin_record_fn(recorder, from, to, token, params, info)
            settle_cell({context, poll_context}, params, label, record_fn)
        end
      end

      # Space out network-touching cells so a 20-corridor sweep does not trip the
      # worker's rate limit (HTTP 429) or overload it into 5xx. Tunable via
      # XOCHI_LIVE_PACE_MS (default 1500ms); set 0 to fire back-to-back.
      defp pace do
        case Integer.parse(System.get_env("XOCHI_LIVE_PACE_MS", "1500")) do
          {ms, _} when ms > 0 -> Process.sleep(ms)
          _ -> :ok
        end
      end

      # Submit and settle one fillable cell, returning an outcome for the summary.
      # A submission failure (execute returns {:error, ...}: bad signature, spend
      # gate, solver pin) is a client FAULT that fails the run -- the intent never
      # reached the worker. A submitted intent that does not complete (the solver is
      # out of gas/inventory on that corridor now) is a logged SKIP; the sweep goes
      # on to the next corridor rather than aborting.
      defp settle_cell({context, poll_context}, params, label, record_fn) do
        started = System.monotonic_time(:millisecond)

        case ExecuteXochiIntent.call(params, context) do
          {:ok, intent} ->
            poll_settlement(poll_context, intent, params, label, started, record_fn)

          {:error, error} ->
            classify_execute_error(error, label)
        end
      end

      # Client/config faults are OUR integration bug: a bad signature, a tripped
      # spend gate, a solver-pin mismatch, a method mismatch, or a malformed
      # request. They would break every corridor, so they fail the run. Everything
      # else is a per-corridor or transient condition -- a worker 5xx/429 or a
      # solver "no liquidity" -- that must not abort a multi-corridor probe.
      @client_fault_reasons [
        :sign_failed,
        :method_mismatch,
        :invalid_request,
        :config_error,
        :checkpoint_required,
        :policy_required,
        :over_budget,
        :requires_confirmation,
        :rejected,
        :delivery_below_floor,
        :stealth_keys_required,
        :stealth_address_missing,
        :unknown
      ]

      defp classify_execute_error(error, label) do
        failure = Failure.from(error)

        cond do
          failure.reason in @client_fault_reasons ->
            IO.puts("[live_xochi:matrix] FAULT #{label}: #{failure.reason} -- #{failure.message}")
            {:fault, label, failure}

          # Transient worker error (HTTP 5xx/429, timeout): the intent may or may
          # not have been submitted before the error, so re-run for a verdict.
          failure.retryable? ->
            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: transient #{failure.reason} " <>
                "(#{failure.message}); re-run to confirm this corridor"
            )

            {:skipped, label, {:transient, failure.reason}}

          # The solver cannot fill this corridor now (no liquidity, unsupported
          # route): a rejected execute moved no funds.
          true ->
            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: #{failure.reason} " <>
                "(#{failure.message}); no funds moved"
            )

            {:skipped, label, {:unfillable, failure.reason}}
        end
      end

      # Poll a submitted intent to terminal. "completed" is a real settlement; any
      # other terminal state means the solver did not fill. A poll ERROR after a
      # successful execute is more serious -- the intent was submitted, so funds may
      # be in flight; the reason atom (e.g. :stranded) rides the outcome so the
      # summary can flag it for reconciliation.
      defp poll_settlement(poll_context, intent, params, label, started, record_fn) do
        case PollXochiStatus.call(%{intent_id: intent.intent_id}, poll_context) do
          {:ok, %{status: "completed"} = status} ->
            record_fn.(intent, status)
            report_settlement(label, intent, status, params, started)
            {:settled, label}

          {:ok, status} ->
            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: #{intent.intent_id} ended " <>
                "#{status.status}, not filled"
            )

            {:skipped, label, {:not_filled, status.status}}

          {:error, error} ->
            failure = Failure.from(error)

            IO.puts(
              "[live_xochi:matrix] SKIP #{label}: #{intent.intent_id} #{failure.reason} " <>
                "-- #{failure.message}"
            )

            {:skipped, label, {:poll_error, failure.reason}}
        end
      end

      # The origin pull rail for a corridor: USDC pulls via ERC-3009, every other
      # token (USDT, WETH, and Robinhood's USDG) via Permit2. Keyed on the ORIGIN
      # leg's resolved token, so a Robinhood-origin corridor (USDG) is classified
      # as Permit2 -- and skipped without a standing allowance -- even when the
      # logical corridor token is USDC.
      defp permit2_origin?(from, token),
        do: String.upcase(leg_symbol(from, token)) != "USDC"

      # The env-gated reasons the FUNDED matrix skips a cell, shared by the matrix
      # and the preflight so the two can never disagree on what is in scope.
      # Returns nil for a settle-eligible cell, or {reason_atom, message} for one
      # the funded run would skip by default: an Ethereum-origin/destination cell
      # (real L1 gas, opt in with XOCHI_LIVE_ALLOW_ETH_ORIGIN / _DEST) or a
      # Permit2-pull cell (USDT/WETH, and Robinhood-origin USDG) that needs a
      # standing on-chain allowance this gate does not broadcast (opt in with
      # XOCHI_LIVE_SETTLE_PERMIT2 once the ACP order gate has set it). The preflight
      # skips quoting these entirely -- no point validating a cell the real run will
      # never touch -- unless XOCHI_LIVE_PREFLIGHT_ALL=true forces the full grid.
      defp settle_skip_reason(from, to, token) do
        cond do
          from == 1 and System.get_env("XOCHI_LIVE_ALLOW_ETH_ORIGIN") != "true" ->
            {:eth_origin,
             "Ethereum origin is quote-only (set XOCHI_LIVE_ALLOW_ETH_ORIGIN=true to settle from L1)"}

          to == 1 and System.get_env("XOCHI_LIVE_ALLOW_ETH_DEST") != "true" ->
            {:eth_dest,
             "Ethereum destination is quote-only (set XOCHI_LIVE_ALLOW_ETH_DEST=true to settle to L1)"}

          permit2_origin?(from, token) and System.get_env("XOCHI_LIVE_SETTLE_PERMIT2") != "true" ->
            {:permit2_allowance,
             "#{token} pulls via Permit2 and needs a standing allowance. Order it through " <>
               "the acp route (run_live_gates.sh --route acp), or set XOCHI_LIVE_SETTLE_PERMIT2=true " <>
               "once the allowance is in place."}

          true ->
            nil
        end
      end

      # Read-only preflight retries: a transient worker/oracle blip clears in
      # seconds and quoting moves no funds, so retry a transient cell before judging
      # it structurally unfillable.
      @preflight_attempts 3
      @preflight_retry_backoff_ms 1500

      # Substrings marking a temporary worker/oracle condition in a can_solve error.
      # A cannot_solve carrying one is transient (retry, do not block); every other
      # reason is structural.
      @transient_preflight_markers [
        "gas_price_unavailable",
        "temporarily",
        "unavailable",
        "oracle",
        "timeout"
      ]

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

        # Quote only the cells the funded run would actually attempt. A cell the
        # funded matrix skips by default (eth-origin/dest, Permit2 allowance) is
        # reported without a quote -- no network call, no retries -- so the preflight
        # does not hammer the worker validating corridors the real run never touches.
        # XOCHI_LIVE_PREFLIGHT_ALL=true forces a full-grid quote for pricing visibility.
        preflight_all? = System.get_env("XOCHI_LIVE_PREFLIGHT_ALL") == "true"

        results =
          Enum.map(cells, fn {from, to, token} = cell ->
            outcome =
              case preflight_all? || settle_skip_reason(from, to, token) do
                {reason, _message} ->
                  {:skipped, reason}

                _ ->
                  pace()
                  preflight_cell(context, from, to, token, amount_for(token, stable_amount))
              end

            report_preflight(from, to, token, outcome)
            {cell, outcome}
          end)

        passed = for {_cell, {:ok, _info}} <- results, do: :ok
        skipped_reasons = for {_cell, {:skipped, reason}} <- results, do: reason
        failures = for {cell, {:error, reason}} <- results, do: {cell, reason}

        {transient, blocking} =
          Enum.split_with(failures, fn {_cell, reason} -> transient_preflight?(reason) end)

        # The 16 PASS lines above are the point: every cell the funded run will
        # attempt is fillable via the pinned solver. The skips are corridors gated
        # behind opt-in flags -- tally them by reason on one line instead of a page
        # of "you didn't opt into this".
        report_skips(skipped_reasons)

        for {cell, reason} <- transient do
          IO.puts("  transient  #{cell_label(cell)} (#{terse_reason(reason)})")
        end

        IO.puts(
          "[live_xochi:preflight] checked #{length(cells)}: #{length(passed)} quoted OK, " <>
            "#{length(skipped_reasons)} skipped, #{length(transient)} transient, " <>
            "#{length(blocking)} blocking"
        )

        if transient != [] do
          IO.puts(
            "  note     transient cells are a worker/oracle blip, not blocking; the funded " <>
              "matrix re-quotes and skips any still-unpriceable cell."
          )
        end

        assert blocking == [],
               "preflight failed for #{length(blocking)} structural cell(s) -- bad corridor, " <>
                 "unpriceable amount, wrong pull rail, or solver-pin mismatch; no funds moved: " <>
                 "#{format_blocking(blocking)}"
      end

      # Terse cell + reason rendering for the summary, so a transient or blocking
      # line reads "8453->1 USDC (http 503)" instead of dumping the raw HTTP body
      # (intent_id/quote_id/expiry) the worker returns on every 5xx.
      defp cell_label({from, to, token}), do: "#{from}->#{to} #{asset_pair(from, to, token)}"

      defp format_blocking(blocking) do
        blocking
        |> Enum.map(fn {cell, reason} -> "#{cell_label(cell)} (#{terse_reason(reason)})" end)
        |> Enum.join(", ")
      end

      defp terse_reason({:http, code, _body}), do: "http #{code}"
      defp terse_reason({:cannot_solve, msg}) when is_binary(msg), do: String.slice(msg, 0, 80)
      defp terse_reason(%Failure{reason: reason}), do: inspect(reason)
      defp terse_reason(other), do: inspect(other)

      # Tally skipped cells by reason on one line, with the flag that would include
      # them. A skip is not a failure -- it is a corridor the funded run does not
      # settle by default (eth-origin/dest burn L1 gas; a Permit2 pull needs a
      # standing allowance this gate does not broadcast), so it is not worth quoting.
      defp report_skips([]), do: :ok

      defp report_skips(reasons) do
        tally =
          reasons
          |> Enum.frequencies()
          |> Enum.sort_by(fn {_reason, count} -> -count end)
          |> Enum.map_join(", ", fn {reason, count} -> "#{count} #{reason}" end)

        IO.puts("  skipped #{length(reasons)} not settle-eligible by default: #{tally}")

        IO.puts(
          "          include via XOCHI_LIVE_ALLOW_ETH_ORIGIN / _DEST / SETTLE_PERMIT2, " <>
            "or XOCHI_LIVE_PREFLIGHT_ALL to quote the whole grid"
        )
      end

      # Quote one corridor x token read-only and confirm the solver can fill it and
      # serves the pinned origin-pull recipient/spender. No spend gate, no signature,
      # no execute -- nothing moves. Public settlement is enough: can_solve and the
      # pull pin are independent of the settlement privacy. A transient worker/oracle
      # blip is retried (read-only, so free and safe); a structural failure returns
      # at once.
      defp preflight_cell(context, from, to, token, amount),
        do: preflight_cell(context, from, to, token, amount, @preflight_attempts)

      defp preflight_cell(context, from, to, token, amount, attempts_left) do
        config = context.xochi_config
        wallet = context.wallet

        result =
          with {:ok, request} <- preflight_request(wallet, from, to, token, amount),
               {:ok, quote} <- XochiProtocol.get_quote(config, request),
               :ok <- preflight_can_solve(quote),
               :ok <- preflight_method(from, token, quote.payment_method),
               :ok <- XochiProtocol.validate_pull(quote, request, wallet) do
            {:ok,
             %{method: quote.payment_method, to_amount: quote.to_amount, fee: quote.xochi_fee}}
          end

        case result do
          {:error, reason} when attempts_left > 1 ->
            if transient_preflight?(reason) do
              Process.sleep(@preflight_retry_backoff_ms)
              preflight_cell(context, from, to, token, amount, attempts_left - 1)
            else
              result
            end

          _ ->
            result
        end
      end

      # A preflight error is transient only when it is a temporary worker/oracle
      # condition -- a gas-price oracle blip or a network 5xx/429/timeout -- never a
      # structural problem with the corridor. The default is NOT transient, so a
      # wrong pull rail, a rotated or forged solver (authorization_mismatch), an
      # unpriceable amount, or an unknown token always blocks the gate before funds
      # move.
      defp transient_preflight?(%Failure{reason: reason}), do: reason == :network

      defp transient_preflight?({:cannot_solve, reason}) when is_binary(reason) do
        down = String.downcase(reason)
        Enum.any?(@transient_preflight_markers, &String.contains?(down, &1))
      end

      defp transient_preflight?(reason), do: Failure.from(reason).reason == :network

      # USDC pulls via ERC-3009; USDT/WETH/USDG pull via Permit2. Asserting the
      # served method per token catches a token routed to the wrong rail (which
      # would otherwise fail on-chain at pull time) before any funds move. Keyed on
      # the ORIGIN leg's resolved token: a Robinhood-origin corridor pulls USDG via
      # Permit2 even when the logical corridor token is USDC.
      defp preflight_method(from, token, method) do
        want = expected_method(String.upcase(leg_symbol(from, token)))
        got = method && String.downcase(method)
        if got == want, do: :ok, else: {:error, {:method_mismatch, token, got, want}}
      end

      defp expected_method("USDC"), do: "erc3009"
      defp expected_method(_token), do: "permit2"

      # Robinhood Chain (4663) carries no USDC/USDT: its only stablecoin is USDG.
      # A stablecoin corridor touching 4663 is therefore cross-asset -- USDC/USDT
      # on the EVM leg, USDG on the Robinhood leg -- which is exactly the fungible
      # stablecoin group the solver fills ([USDC, USDT, DAI, USDG]). Resolve each
      # leg to the token that actually exists on that chain; every non-Robinhood
      # leg, and WETH (canonical on 4663 too), passes through unchanged.
      defp leg_symbol(4663, token) do
        if stablecoin_symbol?(token), do: "USDG", else: token
      end

      defp leg_symbol(_chain, token), do: token

      defp stablecoin_symbol?(token),
        do: String.upcase(token) in ["USDC", "USDT", "DAI", "USDG"]

      defp preflight_request(wallet, from, to, token, amount) do
        with {:ok, from_token} <- Assets.address(from, leg_symbol(from, token)),
             {:ok, to_token} <- Assets.address(to, leg_symbol(to, token)) do
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

      # A quoted cell is the proof -- it can_solve, pulls via the asserted rail, and
      # targets the pinned solver -- so PASS prints with its numbers. Skips are the
      # opposite: cells the funded run won't touch by default, tallied once after the
      # loop rather than one noisy line each. FAIL is always worth a line.
      defp report_preflight(from, to, token, {:ok, info}) do
        IO.puts(
          "  PASS #{from}->#{to} #{asset_pair(from, to, token)} via #{info.method || "?"} " <>
            "(to_amount #{info.to_amount}, fee #{info.fee})"
        )
      end

      defp report_preflight(_from, _to, _token, {:skipped, _reason}), do: :ok

      defp report_preflight(from, to, token, {:error, reason}) do
        IO.puts("  FAIL #{from}->#{to} #{asset_pair(from, to, token)}: #{terse_reason(reason)}")
      end

      # Render the corridor's asset pairing: "USDC" for a same-asset corridor, or
      # "USDC->USDG" when a Robinhood leg swaps a stablecoin for USDG, so the log
      # makes the cross-asset fill explicit.
      defp asset_pair(from, to, token) do
        f = leg_symbol(from, token)
        t = leg_symbol(to, token)
        if f == t, do: f, else: "#{f}->#{t}"
      end

      # The six supported EVM chains: Ethereum, Optimism, Polygon, Base, Arbitrum,
      # Robinhood Chain (4663). Robinhood corridors are cross-asset (USDG on 4663,
      # USDC/USDT/WETH elsewhere) and need a funded solver + deployed Xochi server.
      @evm_chains [1, 10, 137, 8453, 42_161, 4663]

      # "mesh" (or "all") expands to every ordered pair of the six EVM chains (30
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
          from_token: token_for(from, leg_symbol(from, token)),
          to_token: token_for(to, leg_symbol(to, token)),
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
    @explorers %{
      1 => "https://etherscan.io/tx/",
      10 => "https://optimistic.etherscan.io/tx/",
      137 => "https://polygonscan.com/tx/",
      8453 => "https://basescan.org/tx/",
      42_161 => "https://arbiscan.io/tx/"
    }

    defp report_settlement(label, intent, status, params, started_ms) do
      elapsed = System.monotonic_time(:millisecond) - started_ms
      fill = tx_line(Map.get(status, :tx_hash), params.to_chain_id)

      recv =
        case Map.get(status, :receiving_tx_hash) do
          nil -> ""
          hash -> " recv=" <> tx_line(hash, params.to_chain_id)
        end

      IO.puts(
        "[live_xochi:#{label}] settled #{elapsed}ms " <>
          "intent=#{intent.intent_id} status=#{status.status} fill=#{fill}" <> recv
      )
    end

    defp tx_line(nil, _chain), do: "(none)"
    defp tx_line(hash, chain), do: Map.get(@explorers, chain, "") <> hash
  end
end
