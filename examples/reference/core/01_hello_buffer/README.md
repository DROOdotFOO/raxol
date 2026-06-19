# Hello Buffer Example

A simple example demonstrating basic usage of `Raxol.Core.Buffer`.

## What This Example Shows

1. Creating a blank buffer
2. Writing text at specific coordinates
3. Getting individual cells
4. Rendering buffer to string
5. Resizing buffers
6. Clearing buffers

## Running the Example

```bash
# Compile the project first
mix compile

# Run the example
elixir examples/reference/core/01_hello_buffer/main.exs
```

## Expected Output

You should see a simple text display with borders, demonstrating the buffer's ability to store and render text in a grid format.

## Key Concepts

- **Pure Functional**: All operations return new buffers, the original is never modified
- **Coordinate System**: (x, y) where x is column and y is row
- **Cell Structure**: Each cell contains a character and optional style
- **Performance**: All operations complete in < 1ms for standard buffers

## Next Steps

See `examples/reference/core/02_box_drawing/` for more advanced drawing capabilities.
