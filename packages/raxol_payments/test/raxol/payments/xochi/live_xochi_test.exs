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
  for each settlement type -- the live counterpart of `settlement_matrix_test.exs`,
  ready to fire end-to-end once Riddler's EIP-712 parity redeploys. It moves real
  funds per cell, so it is bounded by env:

  - `XOCHI_LIVE_CORRIDORS` -- `"from>to,from>to"` chain-id pairs (default
    `"8453>42161,42161>8453"`). USDC is resolved per chain for Base/Optimism/Arbitrum.
  - `XOCHI_LIVE_SETTLEMENTS` -- `"public,stealth"` (default `"public"`). Stealth
    cells require `XOCHI_LIVE_RECIPIENT_META`.
  - `XOCHI_LIVE_AMOUNT` -- per-cell amount (default `1.00`).

  Run only the matrix:

      XOCHI_LIVE_URL=https://api.xochi.fi \\
      XOCHI_LIVE_TOKEN="$(op read 'op://Employee/Xochi production AGENT_SERVICE_TOKENS/credential')" \\
      XOCHI_LIVE_KEY=0x<funded key> \\
      XOCHI_LIVE_MATRIX=true \\
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
    alias Raxol.Payments.{Ledger, Mandate, SpendingPolicy}
    alias Raxol.Payments.Mandate.Store, as: MandateStore

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
      test "settles every configured corridor for each settlement type", %{
        context: context,
        poll_context: poll_context
      } do
        corridors =
          parse_corridors(System.get_env("XOCHI_LIVE_CORRIDORS", "8453>42161,42161>8453"))

        settlements = parse_settlements(System.get_env("XOCHI_LIVE_SETTLEMENTS", "public"))
        amount = System.get_env("XOCHI_LIVE_AMOUNT", "1.00")
        meta = System.get_env("XOCHI_LIVE_RECIPIENT_META")

        cells = for {from, to} <- corridors, s <- settlements, do: {from, to, s}
        IO.puts("[live_xochi:matrix] running #{length(cells)} cells at #{amount} USDC each")

        for {from, to, settlement} <- cells do
          if settlement == "stealth" and is_nil(meta),
            do: flunk("stealth cell #{from}->#{to} needs XOCHI_LIVE_RECIPIENT_META")

          params = matrix_params(from, to, settlement, amount, meta)
          started = System.monotonic_time(:millisecond)

          assert {:ok, intent} = ExecuteXochiIntent.call(params, context),
                 "execute failed for #{from}->#{to} #{settlement}"

          assert {:ok, status} =
                   PollXochiStatus.call(%{intent_id: intent.intent_id}, poll_context)

          assert status.terminal == true

          assert status.status == "completed",
                 "#{from}->#{to} #{settlement} (#{intent.intent_id}) ended #{status.status}"

          report_settlement("#{from}->#{to}:#{settlement}", intent, status, params, started)
        end
      end

      defp parse_corridors(spec) do
        spec
        |> String.split(",", trim: true)
        |> Enum.map(fn pair ->
          [from, to] = String.split(pair, ">", parts: 2)
          {String.to_integer(String.trim(from)), String.to_integer(String.trim(to))}
        end)
      end

      defp parse_settlements(spec),
        do: spec |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

      defp matrix_params(from, to, settlement, amount, meta) do
        params = %{
          amount: amount,
          from_chain_id: from,
          to_chain_id: to,
          from_token: usdc_for(from),
          to_token: usdc_for(to),
          settlement: settlement
        }

        if settlement == "stealth",
          do: Map.put(params, :recipient_meta_address, meta),
          else: params
      end

      defp usdc_for(8453), do: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
      defp usdc_for(10), do: "0x0b2c639c533813f4aa9d7837caf62653d097ff85"
      defp usdc_for(42_161), do: "0xaf88d065e77c8cc2239327c5edb3a432268e5831"

      defp usdc_for(chain),
        do: raise("no USDC mapping for chain #{chain}; extend usdc_for/1 in live_xochi_test.exs")
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
        source tx     #{tx_line(status.tx_hash, params.from_chain_id)}
        receiving tx  #{tx_line(status.receiving_tx_hash, params.to_chain_id)}\
      """)
    end

    defp tx_line(nil, _chain_id), do: "(none reported)"

    defp tx_line(hash, chain_id) do
      case explorer_base(chain_id) do
        nil -> hash
        base -> base <> hash
      end
    end

    defp explorer_base(8453), do: "https://basescan.org/tx/"
    defp explorer_base(42_161), do: "https://arbiscan.io/tx/"
    defp explorer_base(10), do: "https://optimistic.etherscan.io/tx/"
    defp explorer_base(_), do: nil
  end
end
