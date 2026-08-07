defmodule ANSIParserBenchmark do
  @moduledoc """
  Benchmarks for ANSI escape sequence parsing performance.
  """

  def run do
    # Test data with various ANSI sequences
    simple_text = "Hello, World!"
    colored_text = "\e[31mRed\e[0m \e[32mGreen\e[0m \e[34mBlue\e[0m"
    complex_sequence = "\e[1;31;47mBold Red on White\e[0m\e[2J\e[H\e[?25l"
    cursor_movements = "\e[10A\e[5B\e[3C\e[2D\e[s\e[u"

    # Large text with many sequences
    large_text =
      Enum.map(1..100, fn i ->
        "\e[#{rem(i, 7) + 30}m#{String.duplicate("x", 50)}\e[0m"
      end)
      |> Enum.join("\n")

    Benchee.run(
      %{
        "simple_text" => fn ->
          parse_ansi(simple_text)
        end,
        "colored_text" => fn ->
          parse_ansi(colored_text)
        end,
        "complex_sequence" => fn ->
          parse_ansi(complex_sequence)
        end,
        "cursor_movements" => fn ->
          parse_ansi(cursor_movements)
        end,
        "large_text" => fn ->
          parse_ansi(large_text)
        end
      },
      time: 10,
      memory_time: 2,
      formatters: [
        Benchee.Formatters.Console,
        {Benchee.Formatters.HTML,
         file: "bench/output/ansi_parser.html", auto_open: false}
      ]
    )
  end

  defp parse_ansi(text) do
    # Simulate ANSI parsing
    text
    |> String.to_charlist()
    |> parse_chars([])
  end

  defp parse_chars([], acc), do: Enum.reverse(acc)

  defp parse_chars([?\e, ?[ | rest], acc) do
    # Parse ANSI escape sequence
    {sequence, remaining} = parse_escape_sequence(rest, [])
    parse_chars(remaining, [{:escape, sequence} | acc])
  end

  defp parse_chars([char | rest], acc) do
    parse_chars(rest, [{:char, char} | acc])
  end

  defp parse_escape_sequence([char | rest], acc)
       when char in ?0..?9 or char in [?;, ??] do
    parse_escape_sequence(rest, [char | acc])
  end

  defp parse_escape_sequence([char | rest], acc) do
    {[char | Enum.reverse(acc)], rest}
  end

  defp parse_escape_sequence([], acc) do
    {Enum.reverse(acc), []}
  end
end

# Run the benchmark
ANSIParserBenchmark.run()
