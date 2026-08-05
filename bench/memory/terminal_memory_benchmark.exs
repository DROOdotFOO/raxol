#!/usr/bin/env elixir

# Terminal Memory Benchmark
# Measures memory usage for buffer, ANSI parsing, and cursor operations.
# Run with `mix run bench/memory/terminal_memory_benchmark.exs`
# Emit machine-readable output with `-- --json`.

defmodule TerminalMemoryBenchmark do
  @moduledoc """
  Memory benchmarks for the terminal core: buffer allocation at three sizes,
  writes, ANSI sequence parsing through the real emulator, cursor movement,
  and a full-screen render.
  """

  alias Raxol.Core.Buffer
  alias Raxol.Terminal.{Emulator, TerminalParser}
  alias Raxol.Terminal.Cursor.Manager, as: Cursor

  @scenarios %{
    "small_buffer_create" => :small_buffer_create,
    "medium_buffer_create" => :medium_buffer_create,
    "large_buffer_create" => :large_buffer_create,
    "buffer_write_operations" => :buffer_write_operations,
    "ansi_sequence_processing" => :ansi_sequence_processing,
    "cursor_management" => :cursor_management,
    "large_screen_render" => :large_screen_render
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

    IO.puts("Running Terminal Memory Benchmarks...")

    jobs =
      Map.new(@scenarios, fn {name, fun} ->
        {name, fn -> apply(__MODULE__, fun, []) end}
      end)

    Benchee.run(jobs, config)
  end

  def small_buffer_create, do: Buffer.create_blank_buffer(80, 24)
  def medium_buffer_create, do: Buffer.create_blank_buffer(120, 40)
  def large_buffer_create, do: Buffer.create_blank_buffer(200, 60)

  def buffer_write_operations do
    buffer = Buffer.create_blank_buffer(80, 24)

    Enum.reduce(0..9, buffer, fn row, acc ->
      Buffer.write_at(
        acc,
        0,
        row,
        "Line #{row}: #{String.duplicate("test ", 10)}"
      )
    end)
  end

  def ansi_sequence_processing do
    emulator = Emulator.new(80, 24)

    sequences = [
      "\e[31mRed text\e[0m",
      "\e[1;32mBold green\e[0m",
      "\e[4;34mUnderlined blue\e[0m",
      "\e[7;35mReverse magenta\e[0m",
      "\e[48;5;214mOrange background\e[0m"
    ]

    Enum.reduce(sequences, emulator, fn sequence, acc ->
      acc |> TerminalParser.parse(sequence) |> elem(0)
    end)
  end

  def cursor_management do
    cursor = Cursor.new(0, 0)

    Enum.reduce(1..20, cursor, fn i, acc ->
      Cursor.move_to(acc, rem(i * 3, 24), rem(i * 7, 80))
    end)
  end

  def large_screen_render do
    buffer = Buffer.create_blank_buffer(200, 60)
    row_text = String.duplicate("#", 200)

    filled =
      Enum.reduce(0..59, buffer, fn row, acc ->
        Buffer.write_at(acc, 0, row, row_text)
      end)

    Buffer.to_string(filled)
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

TerminalMemoryBenchmark.run_benchmarks(benchmark_opts)
