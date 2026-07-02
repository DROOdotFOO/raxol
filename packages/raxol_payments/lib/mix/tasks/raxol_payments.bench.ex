defmodule Mix.Tasks.RaxolPayments.Bench do
  @shortdoc "Microbenchmark the payment hot paths: signing, ledger, checkpoint"

  @moduledoc """
  Measures the throughput of the fund-moving hot paths that actually gate DEX
  volume: secp256k1 signing, atomic ledger reservations, and idempotency
  checkpoint reads/writes. (The render frame budget does not gate volume; these
  do.)

      mix raxol_payments.bench
      mix raxol_payments.bench --iterations 20000 --concurrency 16

  Reports operations/sec and average latency per path. The concurrent ledger
  figure exercises the single-GenServer reservation point (`Ledger.try_spend`),
  the serialization ceiling for spend decisions.

  The signing bench sets a throwaway key in `RAXOL_WALLET_KEY` for the run and
  clears it after; it is for local measurement only.
  """

  use Mix.Task

  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}
  alias Raxol.Payments.Wallets.Env, as: EnvWallet

  # Hardhat account 0; a throwaway key for benchmarking only.
  @privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @default_iterations 5_000

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv, strict: [iterations: :integer, concurrency: :integer])

    iterations = Keyword.get(opts, :iterations, @default_iterations)
    concurrency = Keyword.get(opts, :concurrency, System.schedulers_online())

    Mix.Task.run("app.start")

    IO.puts("""
    raxol_payments.bench
      iterations:  #{iterations}
      concurrency: #{concurrency}
    """)

    bench_signing(iterations)
    bench_ledger(iterations, concurrency)
    bench_checkpoint(iterations)
    :ok
  end

  defp bench_signing(n) do
    System.put_env("RAXOL_WALLET_KEY", @privkey)
    digest = :crypto.strong_rand_bytes(32)

    domain = %{
      name: "Bench",
      version: "1",
      chainId: 8453,
      verifyingContract: "0x" <> String.duplicate("ab", 20)
    }

    types = %{"T" => [{"to", "address"}, {"value", "uint256"}]}
    message = %{"to" => "0x" <> String.duplicate("cd", 20), "value" => 1_000_000}

    {us_hash, _} =
      :timer.tc(fn ->
        Enum.each(1..n, fn _ -> {:ok, _} = EnvWallet.sign_hash(digest) end)
      end)

    report("wallet sign_hash (secp256k1)", n, us_hash)

    {us_typed, _} =
      :timer.tc(fn ->
        Enum.each(1..n, fn _ ->
          {:ok, _} = EnvWallet.sign_typed_data(domain, types, message)
        end)
      end)

    report("wallet sign_typed_data (EIP-712 + secp256k1)", n, us_typed)
  after
    System.delete_env("RAXOL_WALLET_KEY")
  end

  defp bench_ledger(n, concurrency) do
    policy = bench_policy()
    amount = Decimal.new("0.0001")

    ledger_seq = start_ledger(:seq)

    {us_seq, _} =
      :timer.tc(fn ->
        Enum.each(1..n, fn _ -> :ok = Ledger.try_spend(ledger_seq, "a", amount, policy) end)
      end)

    report("Ledger.try_spend sequential", n, us_seq)

    ledger_conc = start_ledger(:conc)

    {us_conc, _} =
      :timer.tc(fn ->
        1..n
        |> Task.async_stream(
          fn _ -> Ledger.try_spend(ledger_conc, "a", amount, policy) end,
          max_concurrency: concurrency,
          ordered: false
        )
        |> Stream.run()
      end)

    report("Ledger.try_spend concurrent (#{concurrency})", n, us_conc)
  end

  defp bench_checkpoint(n) do
    store = Checkpoint.ETS.new()

    {us, _} =
      :timer.tc(fn ->
        Enum.each(1..n, fn i ->
          key = "k#{i}"
          :ok = Checkpoint.put(store, key, %{intent_id: key, status: :dispatched})
          {:ok, _} = Checkpoint.fetch(store, key)
        end)
      end)

    report("Checkpoint put+fetch (ETS)", n, us)
  end

  # Caps set far above the bench volume so every reservation succeeds and the
  # measurement is the reservation cost, not cap rejection.
  defp bench_policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1000000"),
      session_max: Decimal.new("1000000000"),
      lifetime_max: Decimal.new("1000000000000"),
      session_window_ms: 3_600_000,
      approved_domains: nil
    }
  end

  defp start_ledger(tag) do
    name = :"bench_ledger_#{tag}_#{System.unique_integer([:positive])}"
    {:ok, ledger} = Ledger.start_link(table_name: name)
    ledger
  end

  defp report(label, n, microseconds) do
    ops = if microseconds > 0, do: round(n * 1_000_000 / microseconds), else: 0
    avg_us = Float.round(microseconds / n, 2)

    IO.puts(
      "  " <>
        String.pad_trailing(label, 48) <>
        String.pad_leading(Integer.to_string(ops), 10) <>
        " ops/s  " <> String.pad_leading(Float.to_string(avg_us), 8) <> " us/op"
    )
  end
end
