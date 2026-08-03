defmodule Mix.Tasks.RaxolEarn.Bench do
  @shortdoc "Drive synthetic ACP jobs through the seller stack and gate on consecutive successes"

  @moduledoc """
  Sandbox graduation harness for `raxol_earn`.

  Boots the supervisor tree with `Raxol.Earn.Seller.Backend.InMemory`,
  registers `Raxol.Earn.Bench.Offering`, and drives N jobs through the
  full v2 ACP lifecycle (offered -> budget_set -> funded/submitted ->
  completed) via `Raxol.Earn.Seller.Queue` and `Raxol.Earn.JobSession`.
  Reports per-job timing, longest consecutive successes, and exits
  non-zero if the gate is not met.

  No chain or RPC required. The bench is the local validation step
  before attempting graduation against the real Virtuals sandbox.

  ## Usage

      mix raxol_earn.bench
      mix raxol_earn.bench --jobs 25
      mix raxol_earn.bench --jobs 50 --gate 10
      mix raxol_earn.bench --timeout 5000

  ## Options

  - `--jobs N` (default `10`) -- number of jobs to drive
  - `--gate N` (default `3`) -- minimum consecutive successes
    required to pass
  - `--timeout MS` (default `2000`) -- per-job timeout in milliseconds
  - `--quiet` -- skip per-job lines, print only the summary

  ## Exit codes

  - `0` -- gate met
  - `1` -- gate not met (longest consecutive successes < `--gate`)

  ## Wallet

  Uses `Raxol.Earn.Bench.Wallet`, which reads its private key from
  `RAXOL_ACP_BENCH_PRIVKEY`. If unset, the task seeds it with the
  canonical Anvil/Foundry test account #0
  (`0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`).
  Override by exporting your own key first.
  """

  use Mix.Task

  alias Raxol.Earn.Bench.Runner

  @bench_privkey_env "RAXOL_ACP_BENCH_PRIVKEY"
  # Anvil/Foundry test account #0. Public test value, not a real key.
  @anvil_test_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @verifying_contract "0x" <> String.duplicate("ab", 20)

  @switches [jobs: :integer, gate: :integer, timeout: :integer, quiet: :boolean]
  @aliases [j: :jobs, g: :gate, t: :timeout, q: :quiet]

  @impl true
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    seed_privkey_if_missing()
    configure_app()
    Mix.Task.run("app.start")
    register_offering()

    summary =
      Runner.run(
        offering: Raxol.Earn.Bench.Offering.offering_name(),
        jobs: Keyword.get(opts, :jobs, 10),
        gate: Keyword.get(opts, :gate, 3),
        job_timeout_ms: Keyword.get(opts, :timeout, 2_000)
      )

    print_report(summary, Keyword.get(opts, :quiet, false))

    if summary.gate_met?, do: :ok, else: System.halt(1)
  end

  # -- Setup --

  defp seed_privkey_if_missing do
    case System.get_env(@bench_privkey_env) do
      nil -> System.put_env(@bench_privkey_env, @anvil_test_key)
      _ -> :ok
    end
  end

  defp configure_app do
    Application.put_env(:raxol_earn, :seller_enabled, true)
    Application.put_env(:raxol_earn, :seller_backend, Raxol.Earn.Seller.Backend.InMemory)
    Application.put_env(:raxol_earn, :seller_wallet, Raxol.Earn.Bench.Wallet)

    Application.put_env(:raxol_earn, :seller_memo_opts,
      chain_id: 8453,
      verifying_contract: @verifying_contract
    )

    Application.put_env(:raxol_earn, :seller_address, "0x" <> String.duplicate("11", 20))
  end

  defp register_offering do
    case Raxol.Earn.Bench.Offering.register() do
      {:ok, _spec} -> :ok
      {:error, {:already_registered, _name}} -> :ok
    end
  end

  # -- Reporting --

  defp print_report(summary, quiet?) do
    Mix.shell().info("")
    Mix.shell().info("raxol_earn bench")
    Mix.shell().info(String.duplicate("-", 60))

    unless quiet? do
      summary.jobs
      |> Enum.with_index(1)
      |> Enum.each(fn {outcome, idx} ->
        Mix.shell().info(format_outcome(idx, outcome))
      end)

      Mix.shell().info(String.duplicate("-", 60))
    end

    Mix.shell().info(format_summary(summary))
  end

  defp format_outcome(idx, outcome) do
    status_str =
      case outcome.status do
        :success -> "OK    "
        :failure -> "FAIL  "
      end

    base =
      [
        String.pad_leading("##{idx}", 4),
        status_str,
        String.pad_leading("#{outcome.elapsed_ms}ms", 8),
        String.pad_trailing(outcome.job_id, 14)
      ]
      |> Enum.join("  ")

    case outcome.reason do
      nil -> base
      reason -> base <> "  " <> inspect(reason)
    end
  end

  defp format_summary(s) do
    pass_or_fail = if s.gate_met?, do: "PASS", else: "FAIL"

    """

    Jobs:        #{s.successes}/#{s.successes + s.failures} succeeded
    Longest:     #{s.longest_consecutive_successes} consecutive successes
    Gate:        >= #{s.gate}  (#{pass_or_fail})
    Total:       #{s.elapsed_ms}ms
    """
  end
end
