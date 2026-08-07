defmodule Raxol.Benchmark.Suites.TerminalBenchmarks do
  @moduledoc """
  Performance benchmarks for terminal emulation operations.
  """

  alias Raxol.Terminal.Emulator

  def run(opts \\ []) do
    Benchee.run(
      %{
        "ANSI sequence parsing" => fn input ->
          emulator = setup_emulator()
          Emulator.SafeEmulator.process_input(emulator, input)
        end,
        "Plain text writing" => fn input ->
          emulator = setup_emulator()
          write_plain_text(emulator, input)
        end,
        "Colored text rendering" => fn ->
          emulator = setup_emulator()
          write_colored_text(emulator)
        end,
        "Cursor movement operations" => fn ->
          emulator = setup_emulator()
          perform_cursor_movements(emulator)
        end,
        "Screen clearing" => fn ->
          emulator = setup_emulator()
          clear_operations(emulator)
        end,
        "Scrolling performance" => fn ->
          emulator = setup_emulator_with_content()
          scroll_operations(emulator)
        end,
        "Buffer resize" => fn ->
          emulator = setup_emulator()
          resize_operations(emulator)
        end,
        "Complex ANSI art" => fn ->
          emulator = setup_emulator()
          render_ansi_art(emulator)
        end
      },
      Keyword.merge(default_options(), opts)
    )
  end

  defp default_options do
    [
      warmup: 2,
      time: 5,
      memory_time: 2,
      inputs: %{
        "small (100 chars)" => generate_text(100),
        "medium (1KB)" => generate_text(1_024),
        "large (10KB)" => generate_text(10_240),
        "huge (100KB)" => generate_text(102_400)
      },
      formatters: [
        {Benchee.Formatters.Console, extended_statistics: true},
        {Benchee.Formatters.HTML,
         file: "bench/output/terminal_benchmarks.html", auto_open: false}
      ]
    ]
  end

  defp setup_emulator do
    {:ok, pid} = Emulator.SafeEmulator.start_link(width: 80, height: 24)
    pid
  end

  defp setup_emulator_with_content do
    emulator = setup_emulator()

    # Fill buffer with content
    Enum.each(1..100, fn i ->
      Emulator.SafeEmulator.process_input(
        emulator,
        "Line #{i}: " <> String.duplicate("x", 70) <> "\n"
      )
    end)

    emulator
  end

  defp write_plain_text(emulator, text) do
    Emulator.SafeEmulator.process_input(emulator, text)
  end

  defp write_colored_text(emulator) do
    colors = [31, 32, 33, 34, 35, 36, 37]

    Enum.each(1..10, fn i ->
      color = Enum.at(colors, rem(i, length(colors)))

      Emulator.SafeEmulator.process_input(
        emulator,
        "\e[#{color}mColored line #{i}\e[0m\n"
      )
    end)
  end

  defp perform_cursor_movements(emulator) do
    movements = [
      # Home
      "\e[H",
      # Absolute position
      "\e[10;20H",
      # Up 5
      "\e[5A",
      # Down 3
      "\e[3B",
      # Right 15
      "\e[15C",
      # Left 8
      "\e[8D",
      # Save position
      "\e[s",
      # Restore position
      "\e[u"
    ]

    Enum.each(movements, fn seq ->
      Emulator.SafeEmulator.process_input(emulator, seq)
    end)
  end

  defp clear_operations(emulator) do
    operations = [
      # Clear screen
      "\e[2J",
      # Clear to end of line
      "\e[K",
      # Clear to beginning of line
      "\e[1K",
      # Clear entire line
      "\e[2K"
    ]

    Enum.each(operations, fn seq ->
      Emulator.SafeEmulator.process_input(emulator, seq)
      Emulator.SafeEmulator.process_input(emulator, "Some text")
    end)
  end

  defp scroll_operations(emulator) do
    # Scroll down
    Enum.each(1..10, fn _ ->
      Emulator.SafeEmulator.process_input(emulator, "\n")
    end)

    # Scroll regions
    # Set scroll region
    Emulator.SafeEmulator.process_input(emulator, "\e[10;20r")

    # Reverse scroll
    Enum.each(1..5, fn _ ->
      Emulator.SafeEmulator.process_input(emulator, "\eM")
    end)
  end

  defp resize_operations(emulator) do
    sizes = [
      {100, 30},
      {120, 40},
      {80, 50},
      {160, 48},
      # Back to original
      {80, 24}
    ]

    Enum.each(sizes, fn {width, height} ->
      Emulator.SafeEmulator.resize(emulator, width, height)
    end)
  end

  defp render_ansi_art(emulator) do
    # Complex ANSI art with multiple colors and positioning
    art = """
    \e[H\e[2J\e[3J
    \e[1;1H\e[48;5;17m                                        \e[0m
    \e[2;1H\e[48;5;17m  \e[48;5;21m    \e[48;5;17m  \e[48;5;21m    \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m    \e[48;5;17m  \e[48;5;21m  \e[48;5;17m      \e[0m
    \e[3;1H\e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m    \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m      \e[0m
    \e[4;1H\e[48;5;17m  \e[48;5;21m    \e[48;5;17m  \e[48;5;21m    \e[48;5;17m    \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m      \e[0m
    \e[5;1H\e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m      \e[0m
    \e[6;1H\e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m  \e[48;5;17m  \e[48;5;21m    \e[48;5;17m  \e[48;5;21m    \e[48;5;17m    \e[0m
    \e[7;1H\e[48;5;17m                                        \e[0m
    """

    Emulator.SafeEmulator.process_input(emulator, art)
  end

  defp generate_text(size) do
    # Generate realistic text with some ANSI sequences
    base_text = "The quick brown fox jumps over the lazy dog. "
    repetitions = div(size, byte_size(base_text))

    text = String.duplicate(base_text, repetitions)

    # Add some ANSI sequences
    case size > 1000 do
      true ->
        text
        |> String.split(" ")
        |> Enum.map_every(10, fn word ->
          color = Enum.random(31..37)
          "\e[#{color}m#{word}\e[0m"
        end)
        |> Enum.join(" ")

      false ->
        text
    end
  end
end
