defmodule Raxol.Terminal.Buffer.BufferServerRefactoredIntegrationTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Buffer.BufferServer
  alias Raxol.Terminal.Cell

  setup do
    # Start a buffer server for each test
    {:ok, pid} = BufferServer.start_link(width: 10, height: 5)
    %{buffer_pid: pid}
  end

  describe "basic operations" do
    test "can set and get cells", %{buffer_pid: pid} do
      cell = Cell.new("A", TextFormatting.new())

      # Set cell asynchronously
      :ok = BufferServer.set_cell(pid, 1, 1, cell)

      # Flush to ensure operation completes
      :ok = BufferServer.flush(pid)

      # Get cell and verify
      {:ok, retrieved_cell} = BufferServer.get_cell(pid, 1, 1)
      assert Cell.get_char(retrieved_cell) == "A"
    end

    test "can set and get cell with style", %{buffer_pid: pid} do
      # Set a cell with style
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("B", TextFormatting.new())
        )

      # Get the cell
      {:ok, retrieved_cell} = BufferServer.get_cell(pid, 0, 0)

      # Verify the cell content
      assert Cell.get_char(retrieved_cell) == "B"
    end

    test "handles invalid coordinates gracefully", %{buffer_pid: pid} do
      cell = Cell.new("X", TextFormatting.new())

      # Try to set cell at invalid coordinates
      {:error, :invalid_coordinates} =
        BufferServer.set_cell_sync(pid, 15, 15, cell)

      # Try to get cell at invalid coordinates
      {:error, :invalid_coordinates} =
        BufferServer.get_cell(pid, 15, 15)
    end
  end

  describe "batch operations" do
    test "can process batch operations", %{buffer_pid: pid} do
      operations = [
        {:set_cell, 0, 0, Cell.new("H", TextFormatting.new())},
        {:set_cell, 1, 0, Cell.new("i", TextFormatting.new())},
        {:write_string, 0, 1, "Hello"},
        {:fill_region, 0, 2, 3, 2, Cell.new("X", TextFormatting.new())}
      ]

      # Process batch operations
      :ok = BufferServer.batch_operations(pid, operations)

      # Flush to ensure all operations complete
      :ok = BufferServer.flush(pid)

      # Verify results
      {:ok, cell1} = BufferServer.get_cell(pid, 0, 0)
      {:ok, cell2} = BufferServer.get_cell(pid, 1, 0)
      {:ok, cell3} = BufferServer.get_cell(pid, 0, 1)
      {:ok, cell4} = BufferServer.get_cell(pid, 0, 2)

      assert Cell.get_char(cell1) == "H"
      assert Cell.get_char(cell2) == "i"
      assert Cell.get_char(cell3) == "H"
      assert Cell.get_char(cell4) == "X"
    end

    test "batch operations with mixed valid and invalid coordinates", %{
      buffer_pid: pid
    } do
      operations = [
        # Valid
        {:set_cell, 0, 0, Cell.new("A", TextFormatting.new())},
        # Invalid
        {:set_cell, 15, 15, Cell.new("B", TextFormatting.new())},
        # Valid
        {:set_cell, 1, 1, Cell.new("C", TextFormatting.new())}
      ]

      # Process batch operations
      :ok = BufferServer.batch_operations(pid, operations)
      :ok = BufferServer.flush(pid)

      # Verify valid operations succeeded
      {:ok, cell1} = BufferServer.get_cell(pid, 0, 0)
      {:ok, cell2} = BufferServer.get_cell(pid, 1, 1)

      assert Cell.get_char(cell1) == "A"
      assert Cell.get_char(cell2) == "C"
    end
  end

  describe "atomic operations" do
    test "can perform atomic operations", %{buffer_pid: pid} do
      # Perform atomic operation
      :ok =
        BufferServer.atomic_operation(pid, fn buffer ->
          buffer
          |> Raxol.Terminal.ScreenBuffer.write_char(0, 0, "A", %{
            foreground: 7,
            background: 0
          })
          |> Raxol.Terminal.ScreenBuffer.write_char(1, 0, "B", %{
            foreground: 7,
            background: 0
          })
          |> Raxol.Terminal.ScreenBuffer.write_char(2, 0, "C", %{
            foreground: 7,
            background: 0
          })
        end)

      # Verify all cells were set atomically
      {:ok, cell1} = BufferServer.get_cell(pid, 0, 0)
      {:ok, cell2} = BufferServer.get_cell(pid, 1, 0)
      {:ok, cell3} = BufferServer.get_cell(pid, 2, 0)

      assert Cell.get_char(cell1) == "A"
      assert Cell.get_char(cell2) == "B"
      assert Cell.get_char(cell3) == "C"
    end
  end

  describe "metrics tracking" do
    test "tracks operation metrics", %{buffer_pid: pid} do
      # Perform some operations
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("A", TextFormatting.new())
        )

      :ok =
        BufferServer.set_cell_sync(
          pid,
          1,
          0,
          Cell.new("B", TextFormatting.new())
        )

      {:ok, _} = BufferServer.get_cell(pid, 0, 0)

      # Get metrics
      {:ok, metrics} = BufferServer.get_metrics(pid)

      # Verify metrics are being tracked
      assert metrics.operation_counts.writes >= 2
      assert metrics.operation_counts.reads >= 1
      assert metrics.total_operations >= 3
    end

    test "tracks memory usage", %{buffer_pid: pid} do
      # Get initial memory usage
      initial_memory = BufferServer.get_memory_usage(pid)
      assert is_integer(initial_memory)
      assert initial_memory > 0

      # Perform operations to potentially change memory usage
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("A", TextFormatting.new())
        )

      # Get updated memory usage
      updated_memory = BufferServer.get_memory_usage(pid)
      assert is_integer(updated_memory)
      assert updated_memory > 0
    end
  end

  describe "damage tracking" do
    test "tracks damage regions", %{buffer_pid: pid} do
      # Perform operations that should create damage regions
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("A", TextFormatting.new())
        )

      :ok =
        BufferServer.set_cell_sync(
          pid,
          1,
          1,
          Cell.new("B", TextFormatting.new())
        )

      # Get damage regions
      damage_regions = BufferServer.get_damage_regions(pid)

      # Verify damage regions are tracked
      assert is_list(damage_regions)
      assert [_ | _] = damage_regions

      # Clear damage regions
      :ok = BufferServer.clear_damage_regions(pid)

      # Verify damage regions are cleared
      cleared_regions = BufferServer.get_damage_regions(pid)
      assert cleared_regions == []
    end
  end

  describe "buffer state operations" do
    test "can get buffer dimensions", %{buffer_pid: pid} do
      {width, height} = BufferServer.get_dimensions(pid)
      assert width == 10
      assert height == 5
    end

    test "can get buffer content", %{buffer_pid: pid} do
      # Set some content
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("H", TextFormatting.new())
        )

      :ok =
        BufferServer.set_cell_sync(
          pid,
          1,
          0,
          Cell.new("i", TextFormatting.new())
        )

      # Get buffer content
      content = BufferServer.get_content(pid)
      assert is_binary(content)
      assert String.contains?(content, "H")
    end

    test "can resize buffer", %{buffer_pid: pid} do
      # Set content before resize
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("A", TextFormatting.new())
        )

      # Resize buffer
      :ok = BufferServer.resize(pid, 15, 8)

      # Flush to ensure resize operation completes
      :ok = BufferServer.flush(pid)

      # Verify new dimensions
      {width, height} = BufferServer.get_dimensions(pid)
      assert width == 15
      assert height == 8

      # Verify content is preserved
      {:ok, cell} = BufferServer.get_cell(pid, 0, 0)
      assert Cell.get_char(cell) == "A"
    end
  end

  describe "concurrent operations" do
    test "handles concurrent writes", %{buffer_pid: pid} do
      # Create multiple processes writing to the buffer
      tasks =
        for i <- 0..9 do
          Task.async(fn ->
            cell = Cell.new("X#{i}", TextFormatting.new())
            BufferServer.set_cell(pid, i, 0, cell)
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Flush to ensure all operations complete
      :ok = BufferServer.flush(pid)

      # Verify all cells were written
      for i <- 0..9 do
        {:ok, cell} = BufferServer.get_cell(pid, i, 0)
        assert Cell.get_char(cell) == "X#{i}"
      end
    end

    test "handles concurrent reads and writes", %{buffer_pid: pid} do
      # Set initial content
      :ok =
        BufferServer.set_cell_sync(
          pid,
          0,
          0,
          Cell.new("A", TextFormatting.new())
        )

      # Create tasks that read and write concurrently
      read_tasks =
        for _ <- 1..5 do
          Task.async(fn ->
            {:ok, cell} = BufferServer.get_cell(pid, 0, 0)
            Cell.get_char(cell)
          end)
        end

      write_tasks =
        for i <- 1..3 do
          Task.async(fn ->
            cell = Cell.new("B#{i}", TextFormatting.new())
            BufferServer.set_cell(pid, i, 0, cell)
          end)
        end

      # Wait for all tasks to complete
      read_results = Enum.map(read_tasks, &Task.await/1)
      Enum.each(write_tasks, &Task.await/1)

      # Flush to ensure all writes complete
      :ok = BufferServer.flush(pid)

      # Verify read results
      assert Enum.all?(read_results, &(&1 == "A"))

      # Verify write results
      for i <- 1..3 do
        {:ok, cell} = BufferServer.get_cell(pid, i, 0)
        assert Cell.get_char(cell) == "B#{i}"
      end
    end
  end

  describe "error handling" do
    test "handles invalid operations gracefully", %{buffer_pid: pid} do
      # Test with invalid cell data
      invalid_cell = %{invalid: "data"}

      # Should handle gracefully
      result = BufferServer.set_cell_sync(pid, 0, 0, invalid_cell)
      assert result == :ok or match?({:error, _}, result)
    end

    test "handles server shutdown gracefully", %{buffer_pid: pid} do
      # Stop the server
      :ok = BufferServer.stop(pid)

      # Try to use the stopped server - should raise an exit
      assert_raise RuntimeError, fn ->
        try do
          BufferServer.get_cell(pid, 0, 0)
        catch
          :exit, {:noproc, _} -> raise "Process not alive"
          :exit, _ -> raise "Process not alive"
        end
      end
    end
  end

  describe "batched writes" do
    test "a batch of writes is visible after one flush", %{buffer_pid: pid} do
      operations =
        for x <- 0..9, y <- 0..4 do
          cell = Cell.new("#{x}#{y}", TextFormatting.new())
          {:set_cell, x, y, cell}
        end

      :ok = BufferServer.batch_operations(pid, operations)
      :ok = BufferServer.flush(pid)

      for x <- 0..9, y <- 0..4 do
        {:ok, cell} = BufferServer.get_cell(pid, x, y)
        assert Cell.get_char(cell) == "#{x}#{y}"
      end
    end
  end
end
