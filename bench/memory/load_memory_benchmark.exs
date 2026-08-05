#!/usr/bin/env elixir

# Load Memory Benchmark
# Measures memory usage under sustained and concurrent load.
# Run with `mix run bench/memory/load_memory_benchmark.exs`
# Emit machine-readable output with `-- --json`.

defmodule LoadMemoryBenchmark do
  @moduledoc """
  Memory benchmarks for load-shaped workloads: many buffers at once, rapid
  updates to one buffer, several simulated sessions, sustained ANSI parsing,
  and a churn scenario that allocates and drops buffers repeatedly.

  The churn scenario exists to make a leak visible: memory should scale with
  the buffers alive at the end, not with how many were created along the way.
  """

  alias Raxol.Core.Buffer
  alias Raxol.Terminal.{Emulator, TerminalParser}

  @scenarios %{
    "concurrent_buffers" => :concurrent_buffers,
    "high_frequency_updates" => :high_frequency_updates,
    "multi_session_simulation" => :multi_session_simulation,
    "stress_ansi_processing" => :stress_ansi_processing,
    "memory_pressure" => :memory_pressure,
    "buffer_churn" => :buffer_churn
  }

  def run_benchmarks(opts \\ []) do
    config =
      [
        time: 3,
        memory_time: 2,
        warmup: 1,
        formatters: [Benchee.Formatters.Console]
      ]
      |> Keyword.merge(opts)

    IO.puts("Running Load Memory Benchmarks...")

    jobs =
      Map.new(@scenarios, fn {name, fun} ->
        {name, fn -> apply(__MODULE__, fun, []) end}
      end)

    Benchee.run(jobs, config)
  end

  def concurrent_buffers do
    1..10
    |> Enum.map(fn i ->
      Task.async(fn ->
        Buffer.create_blank_buffer(80, 24)
        |> Buffer.write_at(0, 0, "worker #{i}")
      end)
    end)
    |> Task.await_many(30_000)
  end

  def high_frequency_updates do
    buffer = Buffer.create_blank_buffer(80, 24)

    Enum.reduce(1..200, buffer, fn i, acc ->
      Buffer.write_at(acc, 0, rem(i, 24), "update #{i}")
    end)
  end

  def multi_session_simulation do
    Enum.map(1..5, fn session ->
      buffer = Buffer.create_blank_buffer(80, 24)

      Enum.reduce(0..23, buffer, fn row, acc ->
        Buffer.write_at(acc, 0, row, "session #{session} row #{row}")
      end)
    end)
  end

  def stress_ansi_processing do
    emulator = Emulator.new(80, 24)

    Enum.reduce(1..100, emulator, fn i, acc ->
      sequence = "\e[#{rem(i, 8) + 30}m\e[#{rem(i, 2) + 1}mComplex #{i}\e[0m"
      acc |> TerminalParser.parse(sequence) |> elem(0)
    end)
  end

  def memory_pressure do
    Enum.map(1..5, fn _i ->
      buffer = Buffer.create_blank_buffer(100, 30)
      row_text = String.duplicate("X", 100)

      Enum.reduce(0..29, buffer, fn row, acc ->
        Buffer.write_at(acc, 0, row, row_text)
      end)
    end)
  end

  # Allocates and drops 100 buffers, keeping only the last. Memory should
  # reflect one surviving buffer, not a hundred.
  def buffer_churn do
    Enum.reduce(1..100, nil, fn i, _previous ->
      Buffer.create_blank_buffer(80, 24)
      |> Buffer.write_at(0, 0, "iteration #{i}")
    end)
  end
end

# `mix run file.exs -- --json` leaves the literal "--" in argv, and
# OptionParser reads that as end-of-options, dropping every flag after it.
argv =
  case System.argv() do
    ["--" | rest] -> rest
    argv -> argv
  end

{opts, _args, _invalid} =
  OptionParser.parse(argv,
    switches: [
      json: :boolean,
      time: :integer,
      memory_time: :integer,
      warmup: :integer
    ]
  )

# Built in one pass: rebinding inside `if` does not escape the block in Elixir,
# which is how this file previously ignored every flag.
benchmark_opts =
  Enum.reduce(opts, [], fn
    {:json, true}, acc ->
      Keyword.put(acc, :formatters, [
        {Benchee.Formatters.JSON, file: "/dev/stdout"}
      ])

    {:time, value}, acc ->
      Keyword.put(acc, :time, value)

    {:memory_time, value}, acc ->
      Keyword.put(acc, :memory_time, value)

    {:warmup, value}, acc ->
      Keyword.put(acc, :warmup, value)

    _other, acc ->
      acc
  end)

File.mkdir_p("bench/output")

LoadMemoryBenchmark.run_benchmarks(benchmark_opts)
