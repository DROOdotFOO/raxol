
# Buffer Performance Benchmark
# Target: All operations < 1ms for 80x24 buffer

alias Raxol.Core.Buffer

Benchee.run(
  %{
    "create_blank_buffer(80, 24)" => fn ->
      Buffer.create_blank_buffer(80, 24)
    end,
    "write_at (single char)" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.write_at(buffer, 40, 12, "X")
    end,
    "write_at (short string)" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.write_at(buffer, 0, 0, "Hello World")
    end,
    "write_at (long string)" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.write_at(buffer, 0, 0, String.duplicate("Test ", 15))
    end,
    "get_cell" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      buffer = Buffer.write_at(buffer, 40, 12, "X")
      Buffer.get_cell(buffer, 40, 12)
    end,
    "set_cell" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.set_cell(buffer, 40, 12, "X", %{bold: true})
    end,
    "clear" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      buffer = Buffer.write_at(buffer, 0, 0, "Test")
      Buffer.clear(buffer)
    end,
    "resize (grow)" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.resize(buffer, 100, 30)
    end,
    "resize (shrink)" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      Buffer.resize(buffer, 40, 12)
    end,
    "to_string" => fn ->
      buffer = Buffer.create_blank_buffer(80, 24)
      buffer = Buffer.write_at(buffer, 0, 0, "Test")
      Buffer.to_string(buffer)
    end
  },
  time: 2,
  memory_time: 1,
  print: [
    fast_warning: false,
    configuration: false
  ]
)

# Check if performance targets are met
IO.puts("\n\n=== Performance Target Validation ===")
IO.puts("Target: All operations < 1ms (1000 microseconds)")
IO.puts("\nMeasuring key operations:")

measurements = [
  {"create_blank_buffer", fn -> Buffer.create_blank_buffer(80, 24) end},
  {"write_at", fn ->
    buffer = Buffer.create_blank_buffer(80, 24)
    Buffer.write_at(buffer, 0, 0, "Hello World")
  end},
  {"to_string", fn ->
    buffer = Buffer.create_blank_buffer(80, 24)
    Buffer.to_string(buffer)
  end}
]

results = Enum.map(measurements, fn {name, func} ->
  {time_us, _result} = :timer.tc(func)
  status = if time_us < 1000, do: "PASS", else: "FAIL"
  IO.puts("  #{name}: #{time_us}μs [#{status}]")
  {name, time_us < 1000}
end)

all_passed = Enum.all?(results, fn {_name, passed} -> passed end)

if all_passed do
  IO.puts("\n✓ All performance targets met!")
else
  IO.puts("\n✗ Some performance targets not met")
end
