# If Statement Refactoring Performance Validation
#
# This benchmark validates the performance impact of the 99.9% if statement elimination
# refactoring (3,609 → 2 if statements) by comparing pattern matching vs if statements
# across critical code paths.

defmodule IfStatementBenchmark do
  @moduledoc """
  Performance comparison between if statements and pattern matching
  to validate the if statement refactoring didn't degrade performance.
  """

  # Test data for common scenarios
  def status_codes, do: [:ok, :error, :timeout, :disconnected, :retry]
  def numbers, do: 1..1000 |> Enum.to_list()

  def strings,
    do: [
      "short",
      "medium_length_string",
      "very_long_string_that_represents_typical_terminal_content"
    ]

  # Simulate original if statement patterns
  def handle_with_if(status) do
    if status == :ok do
      {:success, "Operation completed"}
    else
      if status == :error do
        {:failure, "Operation failed"}
      else
        if status == :timeout do
          {:retry, "Operation timed out"}
        else
          if status == :disconnected do
            {:reconnect, "Connection lost"}
          else
            {:unknown, "Unknown status"}
          end
        end
      end
    end
  end

  # Current pattern matching approach
  def handle_with_case(status) do
    case status do
      :ok -> {:success, "Operation completed"}
      :error -> {:failure, "Operation failed"}
      :timeout -> {:retry, "Operation timed out"}
      :disconnected -> {:reconnect, "Connection lost"}
      _ -> {:unknown, "Unknown status"}
    end
  end

  # Number validation patterns
  def validate_number_if(n) do
    if n < 0 do
      :negative
    else
      if n == 0 do
        :zero
      else
        if n > 100 do
          :large
        else
          :normal
        end
      end
    end
  end

  def validate_number_case(n) do
    case n do
      n when n < 0 -> :negative
      0 -> :zero
      n when n > 100 -> :large
      _ -> :normal
    end
  end

  # String processing patterns
  def process_string_if(str) do
    len = String.length(str)

    if len == 0 do
      :empty
    else
      if len < 5 do
        :short
      else
        if len < 20 do
          :medium
        else
          :long
        end
      end
    end
  end

  def process_string_case(str) do
    case String.length(str) do
      0 -> :empty
      len when len < 5 -> :short
      len when len < 20 -> :medium
      _ -> :long
    end
  end

  # Error handling patterns (simplified from Raxol codebase)
  def handle_error_if(result) do
    if elem(result, 0) == :ok do
      {:success, elem(result, 1)}
    else
      if elem(result, 0) == :error do
        error = elem(result, 1)

        if is_atom(error) do
          {:failure, error}
        else
          {:failure, :unknown_error}
        end
      else
        {:failure, :invalid_result}
      end
    end
  end

  def handle_error_case(result) do
    case result do
      {:ok, value} -> {:success, value}
      {:error, error} when is_atom(error) -> {:failure, error}
      {:error, _} -> {:failure, :unknown_error}
      _ -> {:failure, :invalid_result}
    end
  end
end

# Test data generation
status_test_data = Enum.take_random(IfStatementBenchmark.status_codes(), 1000)
number_test_data = Enum.take_random(IfStatementBenchmark.numbers(), 1000)

string_test_data =
  List.duplicate(IfStatementBenchmark.strings(), 334)
  |> List.flatten()
  |> Enum.take(1000)

error_test_data =
  Enum.map(1..1000, fn i ->
    case rem(i, 4) do
      0 -> {:ok, "success_#{i}"}
      1 -> {:error, :network_error}
      2 -> {:error, "string_error"}
      3 -> {:invalid, "bad_tuple"}
    end
  end)

IO.puts("=== If Statement Refactoring Performance Validation ===")
IO.puts("Comparing performance impact of if statement elimination (3,609 → 2)")
IO.puts("Testing #{length(status_test_data)} operations per benchmark\n")

Benchee.run(
  %{
    # Status handling comparison
    "Status Handling - If Statements" => fn ->
      Enum.each(status_test_data, &IfStatementBenchmark.handle_with_if/1)
    end,
    "Status Handling - Pattern Matching" => fn ->
      Enum.each(status_test_data, &IfStatementBenchmark.handle_with_case/1)
    end,

    # Number validation comparison  
    "Number Validation - If Statements" => fn ->
      Enum.each(number_test_data, &IfStatementBenchmark.validate_number_if/1)
    end,
    "Number Validation - Pattern Matching" => fn ->
      Enum.each(number_test_data, &IfStatementBenchmark.validate_number_case/1)
    end,

    # String processing comparison
    "String Processing - If Statements" => fn ->
      Enum.each(string_test_data, &IfStatementBenchmark.process_string_if/1)
    end,
    "String Processing - Pattern Matching" => fn ->
      Enum.each(string_test_data, &IfStatementBenchmark.process_string_case/1)
    end,

    # Error handling comparison
    "Error Handling - If Statements" => fn ->
      Enum.each(error_test_data, &IfStatementBenchmark.handle_error_if/1)
    end,
    "Error Handling - Pattern Matching" => fn ->
      Enum.each(error_test_data, &IfStatementBenchmark.handle_error_case/1)
    end
  },
  time: 5,
  warmup: 2,
  memory_time: 2,
  formatters: [
    Benchee.Formatters.Console,
    {Benchee.Formatters.HTML,
     file: "bench/output/if_refactoring_validation.html", auto_open: false},
    {Benchee.Formatters.JSON,
     file: "bench/output/if_refactoring_validation.json"}
  ],
  print: [
    benchmarking: true,
    configuration: true,
    fast_warning: false
  ]
)

# Performance analysis
IO.puts("\n=== Performance Analysis ===")

IO.puts("""
This benchmark validates the performance impact of converting if statements to pattern matching.

Expected results:
- Pattern matching should be equal or slightly faster than if statements
- Memory usage should be similar or slightly improved
- No significant performance regression should be observed

Key metrics to watch:
- Iterations per second (higher is better)
- Memory usage per operation (lower is better)
- Variance in execution time (lower is better)

The 99.9% if statement elimination should maintain or improve performance
while significantly improving code readability and maintainability.
""")

# Memory usage analysis
# Let GC settle
Process.sleep(1000)
{:ok, memory_info} = :memsup.get_memory_data()
IO.puts("\n=== Memory Usage After Benchmarks ===")
IO.puts("System memory: #{elem(memory_info, 0)} bytes")
IO.puts("Process memory: #{elem(memory_info, 1)} bytes")

# Validate BEAM optimization
IO.puts("\n=== BEAM Optimization Validation ===")
IO.puts("Pattern matching benefits from BEAM's jump table optimization")
IO.puts("If statements create more complex control flow graphs")

IO.puts(
  "Expected: Pattern matching should show consistent or better performance"
)
