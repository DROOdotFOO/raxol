defmodule Mix.Tasks.Raxol.Gen.Specs do
  @moduledoc """
  Automatically generates type specs for private functions in Raxol modules.

  This task analyzes private functions and generates appropriate @spec annotations
  based on function signatures, pattern matching, and usage patterns.

  ## Usage

      # Generate specs for a specific file
      mix raxol.gen.specs lib/raxol/terminal/color/true_color.ex

      # Generate specs for all files in a directory
      mix raxol.gen.specs lib/raxol/terminal --recursive

      # Dry run to see what would be generated
      mix raxol.gen.specs lib/raxol/terminal/color/true_color.ex --dry-run

      # Generate only for functions with certain patterns
      mix raxol.gen.specs lib/raxol --filter validate_

  ## Options

    * `--dry-run` - Show what would be generated without modifying files
    * `--recursive` - Process all .ex files in directory recursively
    * `--filter` - Only generate specs for functions matching pattern
    * `--interactive` - Prompt for confirmation on each spec
    * `--backup` - Create backup files before modifying
  """

  use Mix.Task

  @shortdoc "Generate type specs for private functions"

  @type spec_info :: %{
          function: atom(),
          arity: non_neg_integer(),
          args: [String.t()],
          return_type: String.t(),
          line: non_neg_integer()
        }

  @impl Mix.Task
  def run(args) do
    {opts, paths, _} =
      OptionParser.parse(args,
        switches: [
          dry_run: :boolean,
          recursive: :boolean,
          filter: :string,
          interactive: :boolean,
          backup: :boolean
        ]
      )

    Mix.Task.run("compile")

    case paths do
      [] ->
        Mix.shell().error("Please provide a file or directory path")
        Mix.shell().info("\nUsage: mix raxol.gen.specs <path> [options]")

      paths ->
        Enum.each(paths, &process_path(&1, opts))
    end
  end

  defp process_path(path, opts) do
    cond do
      File.regular?(path) and Path.extname(path) == ".ex" ->
        process_file(path, opts)

      File.dir?(path) and opts[:recursive] ->
        path
        |> find_ex_files()
        |> Enum.each(&process_file(&1, opts))

      File.dir?(path) ->
        Mix.shell().info(
          "Directory provided but --recursive not set. Use --recursive to process all files."
        )

      true ->
        Mix.shell().error("Path not found or not an Elixir file: #{path}")
    end
  end

  defp find_ex_files(dir) do
    Path.wildcard(Path.join(dir, "**/*.ex"))
  end

  defp process_file(file_path, opts) do
    Mix.shell().info("Processing: #{file_path}")

    with {:ok, content} <- File.read(file_path),
         {:ok, ast} <- Code.string_to_quoted(content),
         :ok <- maybe_backup_file(file_path, opts) do
      specs = analyze_ast(ast, opts)
      updated_content = insert_specs(content, specs, opts)

      if opts[:dry_run] do
        show_dry_run_results(file_path, specs)
      else
        write_updated_file(file_path, updated_content, specs)
      end
    else
      {:error, reason} ->
        Mix.shell().error("Failed to process #{file_path}: #{inspect(reason)}")
    end
  end

  defp analyze_ast(ast, opts) do
    filter = opts[:filter]

    ast
    |> find_private_functions()
    |> filter_functions(filter)
    |> Enum.map(&generate_spec/1)
    |> Enum.reject(&is_nil/1)
  end

  defp find_private_functions(ast) do
    {_, acc} = Macro.prewalk(ast, [], &collect_private_function/2)
    Enum.reverse(acc)
  end

  # Handle defp with guard clauses
  defp collect_private_function(
         {:defp, meta, [{:when, _, [{name, _, args} | _guards]} | _]} = node,
         acc
       )
       when is_atom(name) and is_list(args) do
    {node, [build_func_info(name, args, meta, node, true) | acc]}
  end

  # Handle regular defp without guards
  defp collect_private_function(
         {:defp, meta, [{name, _, args} = fun | _]} = node,
         acc
       )
       when is_atom(name) and is_list(args) do
    {node, [build_func_info(name, args, meta, fun, false) | acc]}
  end

  defp collect_private_function(node, acc), do: {node, acc}

  defp build_func_info(name, args, meta, ast_node, has_guard) do
    %{
      name: name,
      arity: length(args),
      args: extract_arg_patterns(args),
      line: meta[:line] || 0,
      full_ast: ast_node,
      has_guard: has_guard
    }
  end

  defp extract_arg_patterns(args) do
    Enum.map(args, &extract_arg_pattern/1)
  end

  defp extract_arg_pattern({:\\, _, [pattern, _default]}),
    do: extract_arg_pattern(pattern)

  defp extract_arg_pattern({name, _, nil}) when is_atom(name),
    do: to_string(name)

  defp extract_arg_pattern({:%, _, [struct_alias, _]}),
    do: struct_to_type(struct_alias)

  defp extract_arg_pattern({:%{}, _, _}), do: "map()"
  defp extract_arg_pattern({name, _, _}) when is_atom(name), do: to_string(name)
  defp extract_arg_pattern([_ | _]), do: "list()"
  defp extract_arg_pattern(literal) when is_binary(literal), do: "String.t()"
  defp extract_arg_pattern(literal) when is_integer(literal), do: "integer()"
  defp extract_arg_pattern(literal) when is_float(literal), do: "float()"
  defp extract_arg_pattern(literal) when is_boolean(literal), do: "boolean()"
  defp extract_arg_pattern(literal) when is_atom(literal), do: "atom()"
  defp extract_arg_pattern(_), do: "any()"

  defp struct_to_type({:__MODULE__, _, _}), do: "t()"

  defp struct_to_type({:__aliases__, _, parts}),
    do: "#{Module.concat(parts)}.t()"

  defp struct_to_type(_), do: "struct()"

  defp filter_functions(functions, nil), do: functions

  defp filter_functions(functions, filter) do
    Enum.filter(functions, fn %{name: name} ->
      String.contains?(to_string(name), filter)
    end)
  end

  defp generate_spec(%{name: name} = func_info) do
    arg_types = infer_arg_types(func_info)
    return_type = infer_return_type(func_info)

    %{
      function: name,
      arity: func_info.arity,
      line: func_info.line,
      spec: build_spec_string(name, arg_types, return_type)
    }
  end

  defp infer_arg_types(%{args: args, name: name}) do
    args
    |> Enum.with_index()
    |> Enum.map(fn {arg, index} ->
      infer_single_arg_type(arg, name, index)
    end)
  end

  defp infer_single_arg_type(arg, function_name, _index) do
    infer_by_contains(arg) ||
      infer_by_prefix(arg) ||
      infer_by_function_name(function_name) ||
      "any()"
  end

  @contains_type_map %{
    "state" => "map()",
    "buffer" => "Raxol.Terminal.ScreenBuffer.t()",
    "color" => "Raxol.Terminal.Color.TrueColor.t()",
    "cursor" => "Raxol.Terminal.Cursor.t()",
    "opts" => "keyword()",
    "config" => "map()",
    "metadata" => "map()",
    "errors" => "[String.t()]",
    "path" => "String.t()",
    "content" => "String.t()",
    "data" => "any()",
    "id" => "String.t() | integer()",
    "name" => "String.t() | atom()",
    "value" => "any()",
    "result" => "any()",
    "reason" => "any()",
    "message" => "String.t()",
    "timeout" => "timeout()",
    "pid" => "pid()",
    "ref" => "reference()",
    "module" => "module()",
    "function" => "atom()",
    "args" => "list()"
  }

  defp infer_by_contains(arg) do
    Enum.find_value(@contains_type_map, fn {pattern, type} ->
      if String.contains?(arg, pattern), do: type
    end)
  end

  @prefix_type_rules [
    {["x", "y"], "non_neg_integer()"},
    {["width", "height"], "pos_integer()"},
    {["count", "size", "index"], "non_neg_integer()"},
    {["is_", "has_"], "boolean()"},
    {["enable", "disable"], "boolean()"}
  ]

  defp infer_by_prefix(arg) do
    Enum.find_value(@prefix_type_rules, fn {prefixes, type} ->
      if Enum.any?(prefixes, &String.starts_with?(arg, &1)), do: type
    end)
  end

  defp infer_by_function_name(function_name) do
    fname = to_string(function_name)

    cond do
      String.starts_with?(fname, "validate_") -> "any()"
      String.starts_with?(fname, "parse_") -> "String.t()"
      String.starts_with?(fname, "format_") -> "any()"
      String.starts_with?(fname, "build_") -> "any()"
      String.starts_with?(fname, "create_") -> "any()"
      true -> nil
    end
  end

  @return_type_prefix_rules [
    {"validate_", "{:ok, any()} | {:error, any()}"},
    {"parse_", "{:ok, any()} | {:error, any()}"},
    {"is_", "boolean()"},
    {"has_", "boolean()"},
    {"get_", "any() | nil"},
    {"set_", "any()"},
    {"update_", "any()"},
    {"handle_", :analyze_handle},
    {"format_", "String.t()"},
    {"build_", "any()"},
    {"create_", "any()"},
    {"init_", "any()"}
  ]

  @return_type_suffix_rules [
    {"?", "boolean()"},
    {"!", "any() | no_return()"}
  ]

  defp infer_return_type(%{name: name, full_ast: ast}) do
    fname = to_string(name)

    infer_return_by_prefix(fname, ast) ||
      infer_return_by_suffix(fname) ||
      analyze_function_body(ast)
  end

  defp infer_return_by_prefix(fname, ast) do
    fname
    |> match_prefix_rule()
    |> resolve_prefix_type(ast)
  end

  defp match_prefix_rule(fname) do
    Enum.find_value(@return_type_prefix_rules, fn {prefix, type} ->
      if String.starts_with?(fname, prefix), do: type
    end)
  end

  defp resolve_prefix_type(:analyze_handle, ast), do: analyze_handle_return(ast)
  defp resolve_prefix_type(nil, _ast), do: nil
  defp resolve_prefix_type(static_type, _ast), do: static_type

  defp infer_return_by_suffix(fname) do
    Enum.find_value(@return_type_suffix_rules, fn {suffix, type} ->
      if String.ends_with?(fname, suffix), do: type
    end)
  end

  defp analyze_handle_return(_ast) do
    # Common handle_* return patterns
    "{:ok, any()} | {:error, any()} | {:reply, any(), any()} | {:noreply, any()}"
  end

  defp analyze_function_body(ast) do
    # Simple heuristic - look for common return patterns
    case ast do
      {:ok, _} -> "{:ok, any()}"
      {:error, _} -> "{:error, any()}"
      :ok -> ":ok"
      _ -> "any()"
    end
  end

  defp build_spec_string(name, arg_types, return_type) do
    args_string =
      case arg_types do
        [] -> "()"
        types -> "(#{Enum.join(types, ", ")})"
      end

    "@spec #{name}#{args_string} :: #{return_type}"
  end

  defp insert_specs(content, specs, opts) do
    lines = String.split(content, "\n")

    updated_lines =
      specs
      |> Enum.reverse()
      |> Enum.reduce(lines, fn spec, acc ->
        insert_spec_before_line(acc, spec, opts)
      end)

    Enum.join(updated_lines, "\n")
  end

  defp insert_spec_before_line(
         lines,
         %{line: line, spec: spec} = spec_info,
         opts
       ) do
    if opts[:interactive] do
      show_spec_prompt(spec_info)

      case Mix.shell().yes?("Add this spec?") do
        true -> do_insert_spec(lines, line, spec)
        false -> lines
      end
    else
      do_insert_spec(lines, line, spec)
    end
  end

  defp do_insert_spec(lines, line_number, spec) do
    # Insert spec before the function definition
    # Adjust for 0-based indexing
    index = max(line_number - 1, 0)

    {before_lines, [func_line | after_lines]} = Enum.split(lines, index)

    # Check if there's already a spec
    if has_spec?(before_lines) do
      lines
    else
      # Get indentation from function line
      indent = get_indentation(func_line)
      before_lines ++ ["#{indent}#{spec}", func_line] ++ after_lines
    end
  end

  defp has_spec?(lines) do
    # Check if the last few lines contain a @spec
    lines
    |> Enum.take(-3)
    |> Enum.any?(&String.contains?(&1, "@spec"))
  end

  defp get_indentation(line) do
    case Regex.run(~r/^(\s*)/, line) do
      [_, indent] -> indent
      _ -> "  "
    end
  end

  defp show_spec_prompt(%{function: name, arity: arity, spec: spec}) do
    Mix.shell().info("\nFunction: #{name}/#{arity}")
    Mix.shell().info("Generated spec: #{spec}")
  end

  defp maybe_backup_file(file_path, opts) do
    if opts[:backup] do
      backup_path = "#{file_path}.backup"
      File.copy!(file_path, backup_path)
      Mix.shell().info("Backup created: #{backup_path}")
    end

    :ok
  end

  defp show_dry_run_results(file_path, specs) do
    Mix.shell().info(
      "\n[DRY RUN] Would add #{length(specs)} specs to #{file_path}:"
    )

    Enum.each(specs, fn %{function: name, arity: arity, spec: spec} ->
      Mix.shell().info("  #{name}/#{arity}: #{spec}")
    end)
  end

  defp write_updated_file(file_path, content, specs) do
    case File.write(file_path, content) do
      :ok ->
        Mix.shell().info(
          "Successfully added #{length(specs)} specs to #{file_path}"
        )

      {:error, reason} ->
        Mix.shell().error("Failed to write #{file_path}: #{inspect(reason)}")
    end
  end
end
