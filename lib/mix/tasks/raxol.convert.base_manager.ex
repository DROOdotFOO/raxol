defmodule Mix.Tasks.Raxol.Convert.BaseManager do
  @moduledoc """
  Converts GenServer modules to use BaseManager behavior.

  ## Usage

      mix raxol.convert.base_manager lib/path/to/module.ex
      mix raxol.convert.base_manager lib/dir --batch --dry-run

  ## Options

    * `--dry-run` - Preview changes without modifying files
    * `--batch` - Process all GenServer modules in directory
    * `--validate` - Check if conversion was successful
  """

  use Mix.Task
  alias Raxol.Core.Runtime.Log

  @shortdoc "Convert GenServer modules to BaseManager"

  def run(args) do
    {opts, paths, _} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, batch: :boolean, validate: :boolean]
      )

    paths
    |> expand_paths(opts)
    |> Enum.each(&convert_file(&1, opts))
  end

  defp expand_paths(paths, opts) do
    case Keyword.get(opts, :batch, false) do
      true ->
        paths
        |> Enum.flat_map(&find_genserver_files/1)

      false ->
        paths
    end
  end

  defp find_genserver_files(path) do
    case File.dir?(path) do
      true ->
        Raxol.Utils.Glob.under(path, "**/*.ex")
        |> Enum.filter(&uses_genserver?/1)

      false ->
        [path]
    end
  end

  defp uses_genserver?(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        String.contains?(content, "use GenServer") and
          not String.contains?(content, "use Raxol.Core.Behaviours.BaseManager")

      _ ->
        false
    end
  end

  defp convert_file(file_path, opts) do
    case File.read(file_path) do
      {:ok, content} ->
        converted = convert_content(content)
        handle_conversion_output(file_path, content, converted, opts)

      {:error, reason} ->
        Log.info("Error reading #{file_path}: #{reason}")
    end
  end

  defp convert_content(content) do
    content
    |> replace_use_genserver()
    |> add_init_manager_callback()
    |> update_start_link_conflicts()
  end

  defp replace_use_genserver(content) do
    String.replace(
      content,
      "use GenServer",
      "use Raxol.Core.Behaviours.BaseManager"
    )
  end

  defp add_init_manager_callback(content) do
    case Regex.run(~r/@impl GenServer\s+def init\((.*?)\) do(.*?)end/s, content) do
      [full_match, args, body] ->
        new_callback = """
        @impl Raxol.Core.Behaviours.BaseManager
        def init_manager(#{normalize_init_args(args)}) do#{body}end

        @impl GenServer
        def init(opts) do
          init_manager(opts)
        end
        """

        String.replace(content, full_match, new_callback)

      _ ->
        # No @impl GenServer, try plain init
        case Regex.run(~r/def init\((.*?)\) do(.*?)end/s, content) do
          [full_match, args, body] ->
            new_callback = """
            @impl Raxol.Core.Behaviours.BaseManager
            def init_manager(#{normalize_init_args(args)}) do#{body}end

            @impl GenServer
            def init(opts) do
              init_manager(opts)
            end
            """

            String.replace(content, full_match, new_callback)

          _ ->
            content
        end
    end
  end

  defp normalize_init_args(args) do
    # Convert various init argument patterns to opts
    case String.trim(args) do
      # Tuple destructuring
      "{" <> _ -> "opts"
      # List destructuring
      "[" <> _ -> "opts"
      # Map destructuring
      "%{" <> _ -> "opts"
      _ -> args
    end
  end

  defp update_start_link_conflicts(content) do
    # BaseManager provides start_link/1, so rename any conflicting start_link/2
    case Regex.match?(~r/def start_link\(.*?,.*?\)/, content) do
      true ->
        # Has start_link with multiple args - might conflict
        String.replace(
          content,
          ~r/def start_link\((.*?)\s*\\\\s*=/,
          "def start_link_legacy(\\1 \\\\="
        )

      false ->
        content
    end
  end

  defp show_diff(original, converted) do
    original_lines = String.split(original, "\n")
    converted_lines = String.split(converted, "\n")

    Enum.zip(original_lines, converted_lines)
    |> Enum.with_index(1)
    |> Enum.each(fn {{orig, conv}, line_num} ->
      case orig != conv do
        true ->
          Log.info("Line #{line_num}:")
          Log.info("  - #{orig}")
          Log.info("  + #{conv}")

        false ->
          :ok
      end
    end)
  end

  defp validate_conversion(file_path) do
    System.cmd("mix", ["compile", "--force", file_path], stderr_to_stdout: true)
    |> case do
      {_, 0} ->
        Log.info("✓ Compilation successful")
        :ok

      {output, _} ->
        Log.info("✗ Compilation failed:")
        Log.info(output)
        :error
    end
  end

  defp handle_conversion_output(file_path, content, converted, opts) do
    case Keyword.get(opts, :dry_run) do
      true ->
        Log.info("Would convert: #{file_path}")
        Log.info("Changes:")
        show_diff(content, converted)

      _ ->
        write_and_validate_conversion(file_path, converted, opts)
    end
  end

  defp write_and_validate_conversion(file_path, converted, opts) do
    File.write!(file_path, converted)
    Log.info("Converted: #{file_path}")

    case Keyword.get(opts, :validate) do
      true -> validate_conversion(file_path)
      _ -> :ok
    end
  end
end
