#!/usr/bin/env elixir

defmodule DuplicateFileChecker do
  @moduledoc """
  Script to detect duplicate filenames in the Raxol codebase.
  
  This helps maintain code organization and prevents navigation issues
  caused by multiple files with identical names.
  
  Usage:
    mix run scripts/check_duplicate_filenames.exs
    mix run scripts/check_duplicate_filenames.exs --fix-suggestions
  """

  # File patterns that are commonly duplicated and should be avoided
  @problematic_patterns [
    "manager.ex",
    "handler.ex", 
    "server.ex",
    "supervisor.ex",
    "renderer.ex",
    "processor.ex",
    "validator.ex",
    "buffer.ex",
    "parser.ex",
    "state.ex",
    "types.ex",
    "config.ex",
    "client.ex",
    "worker.ex"
  ]

  # Directories to scan
  @scan_dirs ["lib", "test"]
  
  # Files to ignore (legitimate duplicates)
  @ignore_files [
    "mix.exs",
    "README.md", 
    ".gitignore",
    "Dockerfile"
  ]

  def main(args \\ []) do
    show_suggestions = "--fix-suggestions" in args
    
    IO.puts("[CHECK] Scanning for duplicate filenames...")
    IO.puts("Directories: #{Enum.join(@scan_dirs, ", ")}")
    IO.puts("")
    
    duplicates = find_duplicates()
    
    if Enum.empty?(duplicates) do
      IO.puts("[OK] No duplicate filenames found!")
    else
      IO.puts("[FAIL] Found #{length(duplicates)} sets of duplicate filenames:")
      IO.puts("")
      
      display_duplicates(duplicates, show_suggestions)
      
      exit_code = if has_problematic_duplicates?(duplicates), do: 1, else: 0
      System.halt(exit_code)
    end
  end

  defp find_duplicates do
    @scan_dirs
    |> Enum.flat_map(&find_files/1)
    |> Enum.reject(&(&1 |> Path.basename() |> should_ignore?()))
    |> Enum.group_by(&Path.basename/1)
    |> Enum.filter(fn {_basename, paths} -> length(paths) > 1 end)
    |> Enum.sort_by(fn {basename, paths} -> {-length(paths), basename} end)
  end

  defp find_files(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)
          cond do
            File.dir?(path) and not String.starts_with?(entry, ".") ->
              find_files(path)
            String.ends_with?(entry, ".ex") or String.ends_with?(entry, ".exs") ->
              [path]
            true ->
              []
          end
        end)
      {:error, _} ->
        []
    end
  end

  defp should_ignore?(filename) do
    filename in @ignore_files
  end

  defp display_duplicates(duplicates, show_suggestions) do
    Enum.each(duplicates, fn {basename, paths} ->
      problem_level = cond do
        basename in @problematic_patterns -> "[CRITICAL]"
        length(paths) > 3 -> "[WARNING]"
        true -> "[INFO]"
      end
      
      IO.puts("#{problem_level} - '#{basename}' (#{length(paths)} files):")
      
      Enum.each(paths, fn path ->
        IO.puts("  - #{path}")
      end)
      
      if show_suggestions and basename in @problematic_patterns do
        show_naming_suggestions(basename, paths)
      end
      
      IO.puts("")
    end)
  end

  defp show_naming_suggestions(basename, paths) do
    IO.puts("  [NOTE] Suggested renames:")
    
    Enum.each(paths, fn path ->
      suggestion = generate_rename_suggestion(path, basename)
      IO.puts("    #{path} -> #{suggestion}")
    end)
  end

  defp generate_rename_suggestion(path, basename) do
    # Extract the parent directory name for context
    parent_dir = path |> Path.dirname() |> Path.basename()
    
    # Create a contextual name
    case basename do
      "manager.ex" -> 
        "#{parent_dir}_manager.ex"
      "handler.ex" -> 
        "#{parent_dir}_handler.ex"
      "server.ex" -> 
        "#{parent_dir}_server.ex"
      "supervisor.ex" -> 
        "#{parent_dir}_supervisor.ex"
      "renderer.ex" -> 
        "#{parent_dir}_renderer.ex"
      "processor.ex" -> 
        "#{parent_dir}_processor.ex"
      "validator.ex" -> 
        "#{parent_dir}_validator.ex"
      "buffer.ex" -> 
        "#{parent_dir}_buffer.ex"
      "parser.ex" -> 
        "#{parent_dir}_parser.ex"
      "state.ex" -> 
        "#{parent_dir}_state.ex"
      "types.ex" -> 
        "#{parent_dir}_types.ex"
      "config.ex" -> 
        "#{parent_dir}_config.ex"
      "client.ex" -> 
        "#{parent_dir}_client.ex"
      "worker.ex" -> 
        "#{parent_dir}_worker.ex"
      _ -> 
        "#{parent_dir}_#{basename}"
    end
  end

  defp has_problematic_duplicates?(duplicates) do
    Enum.any?(duplicates, fn {basename, _paths} ->
      basename in @problematic_patterns
    end)
  end
end

# Run the script
DuplicateFileChecker.main(System.argv())