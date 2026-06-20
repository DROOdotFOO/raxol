#!/usr/bin/env elixir
IO.puts("[bin/demo.exs] Script started!")

# This script launches a Raxol Example Application
# You can run it with: mix run bin/demo.exs [demo_name]
# Examples:
#   mix run bin/demo.exs form
#   mix run bin/demo.exs accessibility
#   mix run bin/demo.exs --list

# --- Demo Configuration ---

defmodule DemoDiscovery do
  @moduledoc """
  Automatically discovers available demo modules in the Raxol.Examples namespace.
  """

  def discover_demos do
    # Get all modules in Raxol.Examples that have a run/0 function
    :code.all_loaded()
    |> Enum.filter(fn {module, _} ->
      module_string = Atom.to_string(module)
      String.starts_with?(module_string, "Elixir.Raxol.Examples.") and
        not String.ends_with?(module_string, ".Component") and
        function_exported?(module, :run, 0)
    end)
    |> Enum.map(fn {module, _} -> module end)
    |> Enum.sort()
    |> Enum.map(fn module ->
      # Extract demo name from module
      name = module
             |> Atom.to_string()
             |> String.replace("Elixir.Raxol.Examples.", "")
             |> String.downcase()
             |> String.to_atom()

      {name, module}
    end)
    |> Map.new()
  end

  def get_descriptions do
    # Could be auto-generated from @moduledoc or stored in a separate config
    %{
      accessibility: "Demonstrates various accessibility features and compliance.",
      color_system: "Comprehensive color system demonstration with themes.",
      table: "Advanced table component with sorting, filtering, and pagination.",
      keyboard_shortcuts: "Demonstrates keyboard shortcut handling and customization.",
      component_showcase: "Complete component library showcase with examples.",
      select_list_showcase: "Enhanced select list with search and pagination."
    }
  end
end

# Auto-discover demos
@demos DemoDiscovery.discover_demos()
@descriptions DemoDiscovery.get_descriptions()

# --- Command Line Argument Parsing ---

defmodule DemoRunner do
  require IO

  def parse_arguments(args) do
    case args do
      ["--list"] ->
        list_available_demos()
        System.halt(0)

      ["--help"] ->
        show_help()
        System.halt(0)

      ["--version"] ->
        show_version()
        System.halt(0)

      ["--info", demo_name] ->
        show_demo_info(demo_name)
        System.halt(0)

      ["--search", search_term] ->
        search_demos(search_term)
        System.halt(0)

      [demo_name] ->
        case Map.get(@demos, String.to_atom(demo_name)) do
          nil ->
            IO.puts("Error: Unknown demo '#{demo_name}'")
            suggest_similar_demos(demo_name)
            list_available_demos()
            System.halt(1)

          module ->
            {:ok, module}
        end

      [] ->
        {:interactive}

      _ ->
        IO.puts("Error: Invalid arguments")
        show_help()
        System.halt(1)
    end
  end

  defp list_available_demos do
    IO.puts("""
    Available demos:
    """)

    Enum.each(@demos, fn {key, _module} ->
      description = Map.get(@descriptions, key, "No description available.")
      IO.puts("  #{key} - #{description}")
    end)

    IO.puts("""

    Usage:
      mix run bin/demo.exs [demo_name]
      mix run bin/demo.exs --list
      mix run bin/demo.exs --help
    """)
  end

  defp show_help do
    IO.puts("""
    Raxol Demo Runner

    Usage:
      mix run bin/demo.exs [demo_name]    Run a specific demo
      mix run bin/demo.exs --list         List all available demos
      mix run bin/demo.exs --help         Show this help message
      mix run bin/demo.exs --version      Show version information
      mix run bin/demo.exs --info DEMO    Show detailed demo information
      mix run bin/demo.exs --search TERM  Search demos by name or description
      mix run bin/demo.exs                Show interactive menu

    Examples:
      mix run bin/demo.exs form
      mix run bin/demo.exs accessibility
      mix run bin/demo.exs color_system
    """)
  end

  defp show_version do
    IO.puts("""
    Raxol Demo Runner v#{get_version()}
    Raxol Framework v#{get_raxol_version()}
    """)
  end

  defp show_demo_info(demo_name) do
    case Map.get(@demos, String.to_atom(demo_name)) do
      nil ->
        IO.puts("Error: Unknown demo '#{demo_name}'")
        System.halt(1)

      module ->
        description = Map.get(@descriptions, String.to_atom(demo_name), "No description available.")
        IO.puts("""
        Demo: #{demo_name}
        Module: #{module}
        Description: #{description}

        Run with: mix run bin/demo.exs #{demo_name}
        """)
    end
  end

  defp search_demos(search_term) do
    matching_demos = @demos
    |> Enum.filter(fn {key, _module} ->
      key_string = Atom.to_string(key)
      description = Map.get(@descriptions, key, "")
      String.contains?(key_string, search_term) or String.contains?(description, search_term)
    end)

    if Enum.empty?(matching_demos) do
      IO.puts("No demos found matching '#{search_term}'")
    else
      IO.puts("Demos matching '#{search_term}':")
      Enum.each(matching_demos, fn {key, _module} ->
        description = Map.get(@descriptions, key, "No description available.")
        IO.puts("  #{key} - #{description}")
      end)
    end
  end

  defp suggest_similar_demos(unknown_demo) do
    suggestions = @demos
    |> Map.keys()
    |> Enum.filter(fn key ->
      key_string = Atom.to_string(key)
      String.jaro_distance(key_string, unknown_demo) > 0.7
    end)
    |> Enum.take(3)

    if not Enum.empty?(suggestions) do
      IO.puts("\nDid you mean one of these?")
      Enum.each(suggestions, fn suggestion ->
        IO.puts("  #{suggestion}")
      end)
    end
  end

  def display_menu_and_get_choice(demos, descriptions) do
    IO.puts("""
    ========================================================
      Raxol Demo Runner - Select an Example
    ========================================================
    """)

    # Group demos by category
    categorized_demos = categorize_demos(demos)

    Enum.each(categorized_demos, fn {category, category_demos} ->
      IO.puts("\n#{String.upcase(category)}:")
      Enum.each(category_demos, fn {{key, _module}, index} ->
        description = Map.get(descriptions, key, "No description available.")
        IO.puts("  #{index}. #{key} - #{description}")
      end)
    end)

    IO.puts("""
    ========================================================
    Commands: [number] Select demo | [q] Quit | [s] Search | [h] Help
    """)

    prompt_for_choice(demos, length(demos))
  end

  defp prompt_for_choice(indexed_demos, max_index) do
    case IO.gets("Enter the number of the demo to run (1-#{max_index}): ") do
      {:error, reason} ->
        IO.puts("Error reading input: #{reason}. Exiting.")
        System.halt(1)

      :eof ->
        IO.puts("\nExiting.")
        System.halt(0)

      {:ok, input} ->
        case Integer.parse(String.trim(input)) do
          {index, ""} when index >= 1 and index <= max_index ->
            # Valid choice, find the corresponding demo
            {_key, module} =
              Enum.find(indexed_demos, fn {_demo, i} -> i == index end)
              |> elem(0)

            # Return the selected module
            module

          _ ->
            IO.puts(
              "Invalid selection. Please enter a number between 1 and #{max_index}."
            )

            # Retry
            prompt_for_choice(indexed_demos, max_index)
        end
    end
  end

  defp categorize_demos(demos) do
    # Define categories based on demo names or metadata
    categories = %{
      "Basic Examples" => ["table"],
      "Advanced Features" => ["accessibility", "keyboard_shortcuts"],
      "Showcases" => ["component_showcase", "color_system"]
    }

    # Group demos into categories
    Enum.reduce(categories, %{}, fn {category, demo_keys}, acc ->
      category_demos = demos
      |> Enum.filter(fn {key, _} -> key in demo_keys end)
      |> Enum.with_index(1)

      Map.put(acc, category, category_demos)
    end)
  end

  def run_with_monitoring(module) do
    start_time = System.monotonic_time(:millisecond)

    try do
      Raxol.run(module, [])
    after
      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time
      IO.puts("Demo completed in #{duration}ms")
    end
  end

  def validate_demo_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, "Module #{module} could not be loaded"}

      not function_exported?(module, :run, 0) ->
        {:error, "Module #{module} does not export run/0 function"}

      true ->
        {:ok, module}
    end
  end

  def run_demo_safely(module) do
    case validate_demo_module(module) do
      {:ok, valid_module} ->
        try do
          IO.puts("Starting demo: #{module}")
          Raxol.run(valid_module, [])
        rescue
          e ->
            IO.puts("Error running demo: #{Exception.message(e)}")
            IO.puts("Stacktrace: #{Exception.format_stacktrace(__STACKTRACE__)}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts("Error: #{reason}")
        System.halt(1)
    end
  end
end

# --- Main Script Logic ---

# Parse command line arguments
args = System.argv()
example_module = case DemoRunner.parse_arguments(args) do
  {:ok, module} ->
    # Command line argument provided and valid
    module
  {:interactive} ->
    # No arguments, show interactive menu
    DemoRunner.display_menu_and_get_choice(@demos, @descriptions)
end

IO.puts("[bin/demo.exs] Example module selected: #{inspect(example_module)}")

# Add the lib directory to the code path - Handled by `mix run`
# Code.prepend_path("_build/dev/lib/raxol/ebin")

# Ensure all dependencies are loaded - Handled by `mix run`
# Application.ensure_all_started(:raxol)

# Print welcome message (Optional, Raxol app should take over immediately)
# IO.puts """
# ========================================================
#   Raxol Demo Runner
# ========================================================
#
# Launching: #{inspect example_module}
# """

# Wait for key press - Removed, Raxol takes over terminal
# IO.gets("")

# Start the Raxol runtime with the specified example application
opts = [application_module: example_module]

IO.puts("[bin/demo.exs] Attempting to start Raxol with opts: #{inspect(opts)}")

# {:ok, _pid} = Raxol.start_link(opts) # Change to use Raxol.run/2
Raxol.run(example_module, opts)

# Keep the script running until Raxol exits (or manually stopped)
# Temporarily commented out -> Uncommented
IO.puts("[bin/demo.exs] Script finished.")
