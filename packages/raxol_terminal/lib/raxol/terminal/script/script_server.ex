defmodule Raxol.Terminal.Script.ScriptServer do
  @moduledoc """
  Unified scripting system for the Raxol terminal emulator.
  Handles script execution, management, and integration with the terminal.

  REFACTORED: All try/rescue blocks replaced with functional patterns using Task.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Runtime.Log
  @type script_id :: String.t()
  @type script_type :: :lua | :python | :javascript | :elixir
  @type script_state :: %{
          id: script_id,
          name: String.t(),
          type: script_type,
          source: String.t(),
          config: map(),
          status: :idle | :running | :paused | :error,
          error: String.t() | nil,
          output: [String.t()],
          metadata: map()
        }

  def start_script_manager(opts \\ []) do
    start_link([{:name, __MODULE__} | opts])
  end

  @doc """
  Loads a script from a file or string source.
  """
  def load_script(source, type, opts \\ []) do
    GenServer.call(__MODULE__, {:load_script, source, type, opts})
  end

  @doc """
  Unloads a script by its ID.
  """
  def unload_script(script_id) do
    GenServer.call(__MODULE__, {:unload_script, script_id})
  end

  @doc """
  Gets the state of a script.
  """
  def get_script_state(script_id) do
    GenServer.call(__MODULE__, {:get_script_state, script_id})
  end

  @doc """
  Updates a script's configuration.
  """
  def update_script_config(script_id, config) do
    GenServer.call(__MODULE__, {:update_script_config, script_id, config})
  end

  @doc """
  Executes a script with optional arguments.
  """
  def execute_script(script_id, args \\ []) do
    GenServer.call(__MODULE__, {:execute_script, script_id, args})
  end

  @doc """
  Pauses a running script.
  """
  def pause_script(script_id) do
    GenServer.call(__MODULE__, {:pause_script, script_id})
  end

  @doc """
  Resumes a paused script.
  """
  def resume_script(script_id) do
    GenServer.call(__MODULE__, {:resume_script, script_id})
  end

  @doc """
  Stops a running script.
  """
  def stop_script(script_id) do
    GenServer.call(__MODULE__, {:stop_script, script_id})
  end

  @doc """
  Gets the output of a script.
  """
  def get_script_output(script_id) do
    GenServer.call(__MODULE__, {:get_script_output, script_id})
  end

  @doc """
  Gets all loaded scripts.
  """
  def get_scripts(opts \\ []) do
    GenServer.call(__MODULE__, {:get_scripts, opts})
  end

  @doc """
  Exports a script to a file.
  """
  def export_script(script_id, path) do
    GenServer.call(__MODULE__, {:export_script, script_id, path})
  end

  @doc """
  Imports a script from a file.
  """
  def import_script(path, opts \\ []) do
    GenServer.call(__MODULE__, {:import_script, path, opts})
  end

  # BaseManager Callbacks
  @impl true
  def init_manager(opts) do
    state = %{
      scripts: %{},
      script_paths: Keyword.get(opts, :script_paths, ["scripts"]),
      auto_load: Keyword.get(opts, :auto_load, false),
      max_scripts: Keyword.get(opts, :max_scripts, 100),
      script_timeout: Keyword.get(opts, :script_timeout, 30_000)
    }

    {:ok, maybe_load_scripts(state, state.auto_load)}
  end

  @impl true
  def handle_manager_call({:load_script, source, type, opts}, _from, state) do
    script_id = generate_script_id()
    script_state = load_script_state(source, type, opts)

    case validate_script(script_state) do
      :ok ->
        new_state = put_in(state.scripts[script_id], script_state)
        {:reply, {:ok, script_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:unload_script, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      _script ->
        new_state = update_in(state.scripts, &Map.delete(&1, script_id))
        {:reply, :ok, new_state}
    end
  end

  def handle_manager_call({:get_script_state, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        {:reply, {:ok, script}, state}
    end
  end

  def handle_manager_call(
        {:update_script_config, script_id, config},
        _from,
        state
      ) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        update_script_config_if_valid(config, script, script_id, state)
    end
  end

  def handle_manager_call({:execute_script, script_id, args}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        case do_execute_script(script, args, state.script_timeout) do
          {:ok, result} ->
            new_script = %{
              script
              | status: :running,
                output: [result | script.output]
            }

            new_state = put_in(state.scripts[script_id], new_script)
            {:reply, {:ok, result}, new_state}

          {:error, reason} ->
            new_script = %{script | status: :error, error: reason}
            new_state = put_in(state.scripts[script_id], new_script)
            {:reply, {:error, reason}, new_state}
        end
    end
  end

  def handle_manager_call({:pause_script, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        pause_script_if_running(script.status, script, script_id, state)
    end
  end

  def handle_manager_call({:resume_script, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        resume_script_if_paused(script.status, script, script_id, state)
    end
  end

  def handle_manager_call({:stop_script, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        stop_script_if_active(script.status, script, script_id, state)
    end
  end

  def handle_manager_call({:get_script_output, script_id}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      %{output: [latest | _]} ->
        format_script_output(latest, state)

      %{output: []} ->
        {:reply, {:ok, ""}, state}

      _ ->
        {:reply, {:ok, ""}, state}
    end
  end

  def handle_manager_call({:get_scripts, opts}, _from, state) do
    scripts = filter_scripts(state.scripts, opts)
    {:reply, {:ok, scripts}, state}
  end

  def handle_manager_call({:export_script, script_id, path}, _from, state) do
    case Map.get(state.scripts, script_id) do
      nil ->
        {:reply, {:error, :script_not_found}, state}

      script ->
        case export_script_to_file(script, path) do
          :ok ->
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_manager_call({:import_script, path, opts}, _from, state) do
    case import_script_from_file(path, opts) do
      {:ok, script} ->
        script_id = generate_script_id()
        new_state = put_in(state.scripts[script_id], script)
        {:reply, {:ok, script_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp generate_script_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16()
    |> binary_part(0, 8)
  end

  defp load_script_state(source, type, opts) do
    %{
      id: nil,
      name: Keyword.get(opts, :name, "Unnamed Script"),
      type: type,
      source: source,
      config: Keyword.get(opts, :config, %{}),
      status: :idle,
      error: nil,
      output: [],
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp validate_script(script) do
    case validate_script_type(script.type) do
      :ok ->
        case validate_script_source(script.source) do
          :ok ->
            validate_script_config(script.config)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_script_type(type)
       when type in [:lua, :python, :javascript, :elixir],
       do: :ok

  defp validate_script_type(_), do: {:error, :invalid_script_type}

  defp validate_script_source(source)
       when is_binary(source) and byte_size(source) > 0,
       do: :ok

  defp validate_script_source(_), do: {:error, :invalid_script_source}

  defp validate_script_config(config) when is_map(config), do: :ok
  defp validate_script_config(_), do: {:error, :invalid_script_config}

  defp do_execute_script(script, args, timeout) do
    # Use Task for safe execution with timeout
    task =
      Task.async(fn ->
        case script.type do
          :elixir -> execute_elixir_script(script, args, timeout)
          :lua -> execute_lua_script(script, args, timeout)
          :python -> execute_python_script(script, args, timeout)
          :javascript -> execute_javascript_script(script, args, timeout)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Log.error("Script execution timeout")
        {:error, :execution_timeout}

      {:exit, reason} ->
        Log.error("Script execution failed: #{inspect(reason)}")
        {:error, :execution_failed}
    end
  end

  defp execute_elixir_script(script, args, _timeout) do
    module_name = "ScriptModule_#{generate_script_id()}"

    wrapped_code = """
    defmodule #{module_name} do
      #{script.source}
    end
    """

    # Use Task for safe code compilation and execution
    task =
      Task.async(fn ->
        [{mod, _bin}] = Code.compile_string(wrapped_code)

        execute_main_function_if_exported(mod, args)
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Log.error("Elixir script compilation/execution timeout")
        {:error, :execution_failed}

      {:exit, reason} ->
        Log.error("Script execution failed: #{inspect(reason)}")
        {:error, :execution_failed}
    end
  end

  defp execute_lua_script(script, args, timeout) do
    case execute_external_script("lua", script.source, args, timeout) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_python_script(script, args, timeout) do
    case execute_external_script("python3", script.source, args, timeout) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_javascript_script(script, args, timeout) do
    case execute_external_script("node", script.source, args, timeout) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_external_script(interpreter, source, args, timeout) do
    temp_file =
      Path.join(
        System.tmp_dir!(),
        "raxol_script_#{:crypto.strong_rand_bytes(8) |> Base.encode16()}"
      )

    # Use Task for safe file operations and script execution
    task =
      Task.async(fn ->
        # Write script to temporary file
        File.write!(temp_file, source)

        # Execute script with arguments
        cmd = [temp_file] ++ args

        case System.cmd(interpreter, cmd, stderr_to_stdout: true) do
          {output, 0} ->
            # Clean up
            _ = File.rm(temp_file)
            {:ok, String.trim(output)}

          {error_output, _exit_code} ->
            # Clean up
            _ = File.rm(temp_file)
            {:error, String.trim(error_output)}
        end
      end)

    case Task.yield(task, timeout + 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        # Try to clean up temp file
        _ = Task.start(fn -> File.rm(temp_file) end)
        {:error, "Script execution timeout"}

      {:exit, reason} ->
        # Try to clean up temp file
        _ = Task.start(fn -> File.rm(temp_file) end)
        {:error, "Failed to execute script: #{inspect(reason)}"}
    end
  end

  defp filter_scripts(scripts, opts) do
    scripts
    |> Enum.filter(fn {_id, script} ->
      Enum.all?(opts, fn
        {:type, type} -> script.type == type
        {:status, status} -> script.status == status
        _ -> true
      end)
    end)
    |> Map.new()
  end

  defp export_script_to_file(script, path) do
    # Use Task for safe file operations
    task =
      Task.async(fn ->
        # Create directory if it doesn't exist
        File.mkdir_p!(Path.dirname(path))

        # Determine file extension based on script type
        extension = get_script_extension(script.type)

        script_path = add_extension_if_needed(path, extension)

        # Write script source
        File.write!(script_path, script.source)

        # Create metadata file
        metadata_path = script_path <> ".json"

        metadata = %{
          "name" => script.name,
          "type" => Atom.to_string(script.type),
          "config" => script.config,
          "metadata" => script.metadata,
          "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        File.write!(metadata_path, Jason.encode!(metadata, pretty: true))

        :ok
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} ->
        :ok

      nil ->
        Log.error("Script export timeout")
        {:error, :export_failed}

      {:exit, reason} ->
        Log.error("Script export failed: #{inspect(reason)}")
        {:error, :export_failed}
    end
  end

  defp get_script_extension(type) do
    case type do
      :elixir -> ".exs"
      :lua -> ".lua"
      :python -> ".py"
      :javascript -> ".js"
      _ -> ".txt"
    end
  end

  defp import_script_from_file(path, opts) do
    # Use Task for safe file operations
    task =
      Task.async(fn ->
        # Check if path is a directory or file
        case File.stat(path) do
          {:ok, %{type: :directory}} ->
            import_script_from_directory(path, opts)

          {:ok, %{type: :regular}} ->
            import_script_from_single_file(path, opts)

          _ ->
            {:error, :invalid_path}
        end
      end)

    case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        Log.error("Script import timeout")
        {:error, :import_failed}

      {:exit, reason} ->
        Log.error("Script import failed: #{inspect(reason)}")
        {:error, :import_failed}
    end
  end

  defp import_script_from_directory(path, opts) do
    case File.ls(path) do
      {:ok, files} ->
        case find_script_file(files) do
          {:ok, script_file} ->
            load_script_with_metadata(path, script_file, opts)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_script_file(files) do
    script_files = Enum.filter(files, &script_file?/1)

    case script_files do
      [script_file | _] -> {:ok, script_file}
      [] -> {:error, :no_script_files}
    end
  end

  defp load_script_with_metadata(path, script_file, opts) do
    script_path = Path.join(path, script_file)
    metadata_path = Path.join(path, script_file <> ".json")

    with {:ok, source} <- File.read(script_path) do
      metadata = load_script_metadata(metadata_path)
      type = determine_script_type(metadata, script_file)
      merged_opts = merge_metadata_with_opts(metadata, opts)
      {:ok, load_script_state(source, type, merged_opts)}
    end
  end

  defp determine_script_type(metadata, script_file) do
    type = metadata["type"] || infer_script_type(script_file)
    String.to_existing_atom(type)
  end

  defp merge_metadata_with_opts(metadata, opts) do
    metadata_opts =
      [
        name: metadata["name"],
        config: metadata["config"] || %{},
        metadata: metadata["metadata"] || %{}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Keyword.merge(opts, metadata_opts)
  end

  defp import_script_from_single_file(path, opts) do
    case File.read(path) do
      {:ok, source} ->
        # Determine script type from file extension
        type = infer_script_type(path)
        {:ok, load_script_state(source, type, opts)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp script_file?(filename) do
    String.ends_with?(filename, [".exs", ".lua", ".py", ".js", ".txt"])
  end

  defp load_script_metadata(metadata_path) do
    case File.read(metadata_path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, metadata} -> metadata
          {:error, _} -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  defp infer_script_type(filename) do
    case Path.extname(filename) do
      ".exs" -> :elixir
      ".lua" -> :lua
      ".py" -> :python
      ".js" -> :javascript
      _ -> :elixir
    end
  end

  defp load_scripts_from_paths(scripts, paths) do
    Enum.reduce(paths, scripts, fn path, acc ->
      case File.stat(path) do
        {:ok, %{type: :directory}} ->
          load_scripts_from_directory(acc, path)

        {:ok, %{type: :regular}} ->
          load_script_from_single_file(acc, path)

        _ ->
          Log.warning("Invalid script path: #{path}")
          acc
      end
    end)
  end

  defp load_scripts_from_directory(scripts, path) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, scripts, &process_directory_entry(&2, path, &1))

      {:error, reason} ->
        Log.error("Failed to list directory #{path}: #{inspect(reason)}")
        scripts
    end
  end

  defp process_directory_entry(scripts, base_path, entry) do
    entry_path = Path.join(base_path, entry)

    case File.stat(entry_path) do
      {:ok, %{type: :directory}} ->
        load_scripts_from_directory(scripts, entry_path)

      {:ok, %{type: :regular}} ->
        load_script_from_single_file(scripts, entry_path)

      _ ->
        scripts
    end
  end

  defp load_script_from_single_file(scripts, path) do
    load_script_if_valid_file(scripts, script_file?(Path.basename(path)), path)
  end

  # Helper functions for if statement elimination

  defp maybe_load_scripts(state, false), do: state

  defp maybe_load_scripts(state, true) do
    %{state | scripts: load_scripts_from_paths(state.scripts, state.script_paths)}
  end

  defp update_script_config_if_valid(config, script, script_id, state)
       when is_map(config) do
    script_config = get_script_config(script.config)
    new_script = %{script | config: Map.merge(script_config, config)}
    new_state = put_in(state.scripts[script_id], new_script)
    {:reply, :ok, new_state}
  end

  defp update_script_config_if_valid(_config, _script, _script_id, state) do
    {:reply, {:error, :invalid_script_config}, state}
  end

  defp get_script_config(config) when is_map(config), do: config
  defp get_script_config(_config), do: %{}

  defp pause_script_if_running(:running, script, script_id, state) do
    new_script = %{script | status: :paused}
    new_state = put_in(state.scripts[script_id], new_script)
    {:reply, :ok, new_state}
  end

  defp pause_script_if_running(_status, _script, _script_id, state) do
    {:reply, {:error, :invalid_script_state}, state}
  end

  defp resume_script_if_paused(:paused, script, script_id, state) do
    new_script = %{script | status: :running}
    new_state = put_in(state.scripts[script_id], new_script)
    {:reply, :ok, new_state}
  end

  defp resume_script_if_paused(_status, _script, _script_id, state) do
    {:reply, {:error, :invalid_script_state}, state}
  end

  defp stop_script_if_active(status, script, script_id, state)
       when status in [:running, :paused] do
    new_script = %{script | status: :idle}
    new_state = put_in(state.scripts[script_id], new_script)
    {:reply, :ok, new_state}
  end

  defp stop_script_if_active(_status, _script, _script_id, state) do
    {:reply, {:error, :invalid_script_state}, state}
  end

  defp format_script_output(latest, state) when is_binary(latest) do
    output = handle_single_output(length([latest | []]), latest)
    {:reply, {:ok, output}, state}
  end

  defp format_script_output(latest, state) do
    {:reply, {:ok, [latest | []]}, state}
  end

  defp handle_single_output(1, latest), do: latest
  defp handle_single_output(_, latest), do: [latest | []]

  defp execute_main_function_if_exported(mod, args) do
    case function_exported?(mod, :main, length(args)) do
      true ->
        result = apply(mod, :main, args)
        format_elixir_result(result)

      false ->
        {:ok, "Elixir script executed successfully"}
    end
  end

  defp format_elixir_result(result) when is_binary(result), do: {:ok, result}
  defp format_elixir_result(result), do: {:ok, inspect(result)}

  defp add_extension_if_needed(path, extension) do
    case Path.extname(path) do
      "" -> path <> extension
      _ -> path
    end
  end

  defp load_script_if_valid_file(scripts, false, _path), do: scripts

  defp load_script_if_valid_file(scripts, true, path) do
    case import_script_from_file(path, []) do
      {:ok, script} ->
        Log.info("Loaded script: #{script.name} from #{path}")
        Map.put(scripts, generate_script_id(), script)

      {:error, reason} ->
        Log.error("Failed to load script from #{path}: #{inspect(reason)}")
        scripts
    end
  end
end
