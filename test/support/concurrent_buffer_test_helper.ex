defmodule ConcurrentBufferTestHelper do
  @moduledoc """
  Shared helper functions for concurrent buffer tests.

  This module contains common functions used across different concurrent
  buffer test modules to avoid code duplication and ensure consistent
  test behavior.
  """

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Buffer.Cell
  alias Raxol.Terminal.Buffer.ConcurrentBuffer

  @doc """
  Creates a unique buffer server for testing.

  Generates a unique name using crypto random bytes and starts a buffer server
  with standard test dimensions (80x24).

  ## Parameters

  - `prefix` - String prefix for the unique name (defaults to "TestBuffer")

  ## Returns

  `{:ok, %{buffer_pid: pid, buffer_name: unique_name}}`
  """
  def setup_unique_buffer(prefix \\ "TestBuffer") do
    test_name = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    unique_name = :"#{prefix}_#{test_name}"

    {:ok, pid} =
      ConcurrentBuffer.start_server(width: 80, height: 24, name: unique_name)

    {:ok, %{buffer_pid: pid, buffer_name: unique_name}}
  end

  @doc """
  Tears down buffer server safely.

  Stops the buffer server if it's still alive.

  `Process.alive?/1` is a check-then-act race: an `async: true` concurrent
  test can let the server die between the liveness probe and the stop call,
  so `GenServer.stop/3` would exit with `:noproc` inside `on_exit` and fail an
  otherwise-green test. Swallow ONLY that specific `:noproc` teardown race — a
  genuine teardown crash (`:normal` mismatch, a `terminate/2` error, a timeout)
  must still surface, not be hidden by a blanket `:exit, _`.
  """
  def teardown_buffer(pid) do
    if Process.alive?(pid) do
      try do
        ConcurrentBuffer.stop(pid)
      catch
        :exit, reason
        when reason == :noproc or
               (is_tuple(reason) and elem(reason, 0) == :noproc) ->
          :ok
      end
    else
      :ok
    end
  end

  @doc """
  Creates multiple concurrent writer tasks.

  ## Parameters

  - `pid` - Buffer server PID
  - `writer_count` - Number of writer tasks to create
  - `regions` - Whether writers should write to different regions (default: true)
  - `iterations` - Number of write operations per writer (default: 100)

  ## Returns

  List of Task structs
  """
  def create_concurrent_writers(pid, writer_count, opts \\ []) do
    regions = Keyword.get(opts, :regions, true)
    iterations = Keyword.get(opts, :iterations, 100)
    color = Keyword.get(opts, :color, :red)

    Enum.map(1..writer_count, fn writer_id ->
      Task.async(fn ->
        write_to_region(pid, writer_id, regions, iterations, color)
      end)
    end)
  end

  defp write_to_region(pid, writer_id, regions, iterations, color) do
    {start_x, start_y, width, height} = get_writer_region(writer_id, regions)

    if iterations > 0 do
      cell = Cell.new("W", TextFormatting.new(foreground: color))
      write_cell_grid(pid, start_x, start_y, width, height, cell)
    else
      :ok
    end
  end

  defp write_cell_grid(pid, start_x, start_y, width, height, cell) do
    Enum.each(0..(height - 1), fn y ->
      Enum.each(0..(width - 1), fn x ->
        ConcurrentBuffer.set_cell(pid, start_x + x, start_y + y, cell)
      end)
    end)
  end

  @doc """
  Creates multiple concurrent reader tasks.

  ## Parameters

  - `pid` - Buffer server PID
  - `reader_count` - Number of reader tasks to create
  - `iterations` - Number of read operations per reader (default: 100)

  ## Returns

  List of Task structs
  """
  def create_concurrent_readers(pid, reader_count, iterations \\ 100) do
    Enum.map(1..reader_count, fn _reader_id ->
      Task.async(fn -> random_reads(pid, iterations) end)
    end)
  end

  @doc """
  Creates mixed concurrent operations (readers, writers, scrollers, region fillers).

  ## Parameters

  - `pid` - Buffer server PID
  - `opts` - Options for operation configuration

  ## Returns

  List of Task structs with mixed operations
  """
  def create_mixed_operations(pid, opts \\ []) do
    read_iterations = Keyword.get(opts, :read_iterations, 100)
    write_iterations = Keyword.get(opts, :write_iterations, 100)
    scroll_iterations = Keyword.get(opts, :scroll_iterations, 20)
    fill_iterations = Keyword.get(opts, :fill_iterations, 10)

    [
      Task.async(fn -> random_reads(pid, read_iterations) end),
      Task.async(fn -> random_writes(pid, write_iterations) end),
      Task.async(fn -> scroll_operations(pid, scroll_iterations) end),
      Task.async(fn -> fill_operations(pid, fill_iterations) end)
    ]
  end

  defp random_reads(pid, iterations) do
    Enum.each(1..iterations, fn _ ->
      x = :rand.uniform(80) - 1
      y = :rand.uniform(24) - 1
      {:ok, _cell} = ConcurrentBuffer.get_cell(pid, x, y)
    end)
  end

  defp random_writes(pid, iterations) do
    Enum.each(1..iterations, fn _ ->
      x = :rand.uniform(80) - 1
      y = :rand.uniform(24) - 1
      cell = Cell.new("W", TextFormatting.new(foreground: :yellow))
      ConcurrentBuffer.set_cell(pid, x, y, cell)
    end)
  end

  defp scroll_operations(pid, iterations) do
    Enum.each(1..iterations, fn _ ->
      ConcurrentBuffer.scroll(pid, 1)
    end)
  end

  defp fill_operations(pid, iterations) do
    Enum.each(1..iterations, fn i ->
      x = rem(i, 8) * 10
      y = div(i, 8) * 3
      ConcurrentBuffer.fill_region(pid, x, y, 10, 3, "F", %{foreground: :red})
    end)
  end

  @doc """
  Creates a stress test with many concurrent operations.

  ## Parameters

  - `pid` - Buffer server PID
  - `operation_count` - Number of operation pairs to create (default: 20)
  - `iterations_per_op` - Iterations per operation (default: 50)

  ## Returns

  List of Task structs for stress testing
  """
  def create_stress_operations(
        pid,
        operation_count \\ 20,
        iterations_per_op \\ 50
      ) do
    Enum.flat_map(1..operation_count, fn _i ->
      [
        # Reader
        Task.async(fn ->
          Enum.each(1..iterations_per_op, fn _ ->
            x = :rand.uniform(80) - 1
            y = :rand.uniform(24) - 1
            {:ok, _cell} = ConcurrentBuffer.get_cell(pid, x, y)
          end)
        end),

        # Writer
        Task.async(fn ->
          Enum.each(1..iterations_per_op, fn _j ->
            x = :rand.uniform(80) - 1
            y = :rand.uniform(24) - 1
            cell = Cell.new("W", TextFormatting.new(foreground: :blue))
            ConcurrentBuffer.set_cell(pid, x, y, cell)
          end)
        end)
      ]
    end)
  end

  @doc """
  Waits for all tasks to complete and verifies results.

  ## Parameters

  - `tasks` - List of Task structs
  - `timeout` - Timeout in milliseconds (default: 5000)

  ## Returns

  `:ok` if all tasks completed successfully
  """
  def await_and_verify_tasks(tasks, timeout \\ 5000) do
    results = Task.await_many(tasks, timeout)

    # Verify all tasks completed successfully
    all_ok =
      Enum.all?(results, fn result ->
        case result do
          :ok -> true
          {:ok, _} -> true
          _ -> false
        end
      end)

    case all_ok do
      true -> :ok
      false -> {:error, :some_tasks_failed}
    end
  end

  @doc """
  Verifies basic cell content after concurrent operations.

  ## Parameters

  - `pid` - Buffer server PID
  - `x` - X coordinate to check
  - `y` - Y coordinate to check
  - `expected_char` - Expected character content

  ## Returns

  `:ok` if verification passes, `{:error, reason}` otherwise
  """
  def verify_cell_content(pid, x, y, expected_char) do
    case ConcurrentBuffer.get_cell(pid, x, y) do
      {:ok, %{char: ^expected_char}} ->
        :ok

      {:ok, %{char: actual_char}} ->
        {:error, "Expected char '#{expected_char}', got '#{actual_char}'"}

      error ->
        error
    end
  end

  # Private helper functions

  defp get_writer_region(writer_id, true) do
    # Different regions for each writer
    start_x = rem(writer_id, 8) * 10
    start_y = div(writer_id, 8) * 3
    {start_x, start_y, 10, 3}
  end

  defp get_writer_region(_writer_id, false) do
    # Same region for all writers (overlap testing)
    {0, 0, 5, 5}
  end
end
