#!/usr/bin/env elixir

# Basic Buffer Usage
#
# The buffer is the 2D grid of cells underneath the View DSL.
# Most apps never touch it directly, but understanding this layer
# helps when debugging or building custom renderers.
#
# What you'll learn:
#   - Buffer = 2D grid of cells, the canvas underneath the View DSL
#   - Coordinates: (x, y), 0-indexed, (0,0) at top-left
#   - Immutable: write_at returns a new buffer (pipe-friendly)
#   - Operations: create, write_at, get_cell, resize, clear, to_string

# Add the lib directory to the code path
Code.prepend_path("_build/dev/lib/raxol/ebin")

alias Raxol.Core.Buffer

IO.puts("=== Raxol.Core.Buffer Example ===\n")

# Create a small buffer
IO.puts("1. Creating a 40x10 buffer...")
buffer = Buffer.create_blank_buffer(40, 10)
IO.puts("   Buffer created: #{buffer.width}x#{buffer.height}\n")

# Write some text
IO.puts("2. Writing text to buffer...")

buffer =
  buffer
  |> Buffer.write_at(5, 2, "Hello, Raxol!")
  |> Buffer.write_at(5, 4, "Core Buffer Demo")
  |> Buffer.write_at(5, 6, "Pure Functional Design")

# Draw a simple border using ASCII characters
IO.puts("3. Drawing a border...")

buffer =
  buffer
  |> Buffer.write_at(0, 0, String.duplicate("-", 40))
  |> Buffer.write_at(0, 9, String.duplicate("-", 40))

# Render and display
IO.puts("4. Rendering buffer to string:\n")
IO.puts(Buffer.to_string(buffer))

# Demonstrate cell operations
IO.puts("\n5. Getting a specific cell...")
cell = Buffer.get_cell(buffer, 5, 2)
IO.puts("   Cell at (5, 2): '#{cell.char}'")

# Demonstrate resize
IO.puts("\n6. Resizing buffer to 50x12...")
buffer = Buffer.resize(buffer, 50, 12)
IO.puts("   New dimensions: #{buffer.width}x#{buffer.height}")

# Clear the buffer
IO.puts("\n7. Clearing buffer...")
buffer = Buffer.clear(buffer)
first_cell = Buffer.get_cell(buffer, 0, 0)
IO.puts("   First cell after clear: '#{first_cell.char}' (blank)")

IO.puts("\n=== Example Complete ===")
