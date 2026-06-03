defmodule Raxol.Config.Loader do
  @moduledoc """
  Configuration loading utilities for various formats and sources.

  Handles loading configuration from files, environment variables,
  and other sources with proper error handling and validation.
  """
  alias Raxol.Config.Schema
  alias Raxol.Core.Runtime.Log

  @supported_formats ~w(.toml .json .yaml .yml)
  @event_cleanup_delay_ms Raxol.Core.Defaults.monitor_interval_ms()

  @doc """
  Loads configuration from a file path.
  """
  def load_file(path) do
    with {:ok, content} <- read_file(path),
         {:ok, parsed} <- parse_content(content, Path.extname(path)),
         {:ok, config} <- normalize_config(parsed) do
      {:ok, config}
    else
      {:error, :enoent} ->
        {:error, {:file_not_found, path}}

      {:error, reason} ->
        {:error, {:load_failed, path, reason}}
    end
  end

  @doc """
  Loads configuration from multiple file paths, merging them.
  """
  def load_files(paths) when is_list(paths) do
    results = Enum.map(paths, &load_file/1)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    handle_load_results(length(failures) == length(paths), failures, successes)
  end

  @doc """
  Loads configuration from environment variables with a prefix.

  Env vars whose key segments do not exist as atoms in the schema are
  skipped with a debug log (prevents `String.to_atom` atom-table leak
  from arbitrary OS env input).
  """
  def load_environment(prefix \\ "RAXOL_") do
    ensure_schema_atoms_loaded()

    env_vars =
      System.get_env()
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, prefix) end)
      |> Enum.flat_map(fn {key, value} ->
        case parse_env_key(key, prefix) do
          nil ->
            []

          parsed_key ->
            [{parsed_key, parse_env_value(value)}]
        end
      end)

    config = build_nested_config(env_vars)
    {:ok, config}
  end

  @doc """
  Creates a configuration loader for a specific directory.
  """
  def create_directory_loader(directory) do
    fn ->
      config_files = find_config_files(directory)

      case load_files(config_files) do
        {:ok, config} ->
          Log.info(
            "Loaded configuration from #{length(config_files)} files in #{directory}"
          )

          {:ok, config}

        {:error, reason} ->
          Log.warning(
            "Failed to load configuration from #{directory}: #{inspect(reason)}"
          )

          {:ok, %{}}
      end
    end
  end

  @doc """
  Validates configuration against schema.
  """
  def validate_config(config, schema \\ Schema.schema()) do
    Schema.validate_config(config, schema)
  end

  @doc """
  Applies default values to configuration.
  """
  def apply_defaults(config, defaults) do
    deep_merge(defaults, config)
  end

  @doc """
  Transforms configuration using custom transformation functions.
  """
  def transform_config(config, transformers) do
    Enum.reduce(transformers, config, fn transformer, acc ->
      transformer.(acc)
    end)
  end

  @doc """
  Exports configuration to a file.
  """
  def export_config(config, path, opts \\ []) do
    format = Keyword.get(opts, :format) || detect_format(path)
    pretty = Keyword.get(opts, :pretty, true)

    with {:ok, content} <- encode_config(config, format, pretty),
         :ok <- ensure_directory(path),
         :ok <- File.write(path, content) do
      {:ok, path}
    else
      {:error, reason} ->
        {:error, {:export_failed, path, reason}}
    end
  end

  @doc """
  Creates a backup of a configuration file.
  """
  def backup_config(path) do
    create_backup_if_exists(File.exists?(path), path)
  end

  @doc """
  Watches configuration files for changes.
  """
  def watch_files(paths, callback)
      when is_list(paths) and is_function(callback) do
    case FileSystem.start_link(dirs: Enum.map(paths, &Path.dirname/1)) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)

        spawn_link(fn ->
          watch_loop(paths, callback, MapSet.new())
        end)

        {:ok, watcher}

      {:error, reason} ->
        {:error, {:watch_failed, reason}}
    end
  end

  # Private functions - Pattern Matching Helpers

  defp handle_load_results(true, failures, _successes) do
    {:error, {:all_files_failed, failures}}
  end

  defp handle_load_results(false, _failures, successes) do
    configs = Enum.map(successes, fn {:ok, config} -> config end)
    merged = Enum.reduce(configs, %{}, &deep_merge/2)
    {:ok, merged}
  end

  defp create_backup_if_exists(false, _path) do
    {:error, :file_not_found}
  end

  defp create_backup_if_exists(true, path) do
    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    backup_path = "#{path}.backup.#{timestamp}"

    case File.copy(path, backup_path) do
      {:ok, _} ->
        Log.info("Configuration backed up to #{backup_path}")
        {:ok, backup_path}

      {:error, reason} ->
        {:error, {:backup_failed, reason}}
    end
  end

  defp find_files_in_directory(false, _directory) do
    []
  end

  defp find_files_in_directory(true, directory) do
    @supported_formats
    |> Enum.flat_map(fn ext ->
      Path.wildcard(Path.join(directory, "*#{ext}"))
    end)
    |> Enum.sort()
  end

  defp process_file_event(
         false,
         _event_key,
         _file_path,
         paths,
         callback,
         processed_events
       ) do
    watch_loop(paths, callback, processed_events)
  end

  defp process_file_event(
         true,
         event_key,
         file_path,
         paths,
         callback,
         processed_events
       ) do
    handle_file_change(file_path in paths, file_path, callback)

    new_processed =
      reset_processed_events_if_needed(
        MapSet.size(processed_events) > 100,
        processed_events,
        event_key
      )

    Process.send_after(
      self(),
      {:remove_event, event_key},
      @event_cleanup_delay_ms
    )

    watch_loop(paths, callback, new_processed)
  end

  defp handle_file_change(false, _file_path, _callback), do: :ok

  defp handle_file_change(true, file_path, callback) do
    Log.debug("Configuration file changed: #{file_path}")

    case load_file(file_path) do
      {:ok, config} ->
        callback.({:file_changed, file_path, config})

      {:error, reason} ->
        callback.({:file_error, file_path, reason})
    end
  end

  defp reset_processed_events_if_needed(true, _processed_events, event_key) do
    MapSet.new([event_key])
  end

  defp reset_processed_events_if_needed(false, processed_events, event_key) do
    MapSet.put(processed_events, event_key)
  end

  # Private functions

  defp read_file(path) do
    expanded_path = Path.expand(path)
    File.read(expanded_path)
  end

  defp parse_content(content, ext) do
    case String.downcase(ext) do
      ".toml" -> parse_toml(content)
      ".json" -> parse_json(content)
      ".yaml" -> parse_yaml(content)
      ".yml" -> parse_yaml(content)
      _ -> {:error, {:unsupported_format, ext}}
    end
  end

  defp parse_toml(content) do
    case Toml.decode(content) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:toml_parse_error, reason}}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:json_parse_error, reason}}
    end
  end

  defp parse_yaml(content) do
    case YamlElixir.read_from_string(content) do
      {:ok, config} -> {:ok, config}
      {:error, reason} -> {:error, {:yaml_parse_error, reason}}
    end
  end

  defp normalize_config(config) when is_map(config) do
    normalized =
      config
      |> atomize_keys()
      |> normalize_values()

    {:ok, normalized}
  end

  defp normalize_config(_), do: {:error, :invalid_config_format}

  defp atomize_keys(map) when is_map(map) do
    map
    |> Enum.flat_map(fn {key, value} ->
      case atomize_key(key) do
        nil -> []
        atom_key -> [{atom_key, atomize_keys(value)}]
      end
    end)
    |> Map.new()
  end

  defp atomize_keys(list) when is_list(list),
    do: Enum.map(list, &atomize_keys/1)

  defp atomize_keys(value), do: value

  defp atomize_key(key) when is_binary(key) do
    case safe_to_existing_atom(key) do
      nil ->
        Log.debug("[Loader] Skipping unknown config key: #{inspect(key)}")
        nil

      atom ->
        atom
    end
  end

  defp atomize_key(key), do: key

  defp normalize_values(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {key, normalize_values(value)}
    end)
  end

  defp normalize_values(list) when is_list(list),
    do: Enum.map(list, &normalize_values/1)

  defp normalize_values(value) when is_binary(value),
    do: normalize_string_value(value)

  defp normalize_values(value), do: value

  defp normalize_string_value(value) do
    case value do
      # Boolean strings
      "true" ->
        true

      "false" ->
        false

      # Environment variable references
      "${" <> rest ->
        case String.ends_with?(rest, "}") do
          true ->
            var_name = String.slice(rest, 0..-2//1)
            System.get_env(var_name, value)

          false ->
            value
        end

      # File paths
      "~/" <> _rest ->
        Path.expand(value)

      # Numeric strings - check patterns
      _ ->
        parse_numeric_string(value)
    end
  end

  defp parse_numeric_string(value) do
    cond do
      Regex.match?(~r/^\d+$/, value) ->
        String.to_integer(value)

      Regex.match?(~r/^\d+\.\d+$/, value) ->
        String.to_float(value)

      true ->
        value
    end
  end

  defp parse_env_key(key, prefix) do
    atoms =
      key
      |> String.replace_prefix(prefix, "")
      |> String.downcase()
      |> String.split("__")
      |> Enum.map(&safe_to_existing_atom/1)

    if Enum.any?(atoms, &is_nil/1) do
      Log.debug(
        "[Loader] Skipping env var with unknown schema key: #{inspect(key)}"
      )

      nil
    else
      atoms
    end
  end

  # Returns the matching atom or nil. Forces the Schema modules to load
  # first so every literal atom in the schema source is interned in the
  # global atom table before `to_existing_atom` checks against it.
  defp safe_to_existing_atom(key) when is_binary(key) do
    ensure_schema_atoms_loaded()
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp ensure_schema_atoms_loaded do
    _ = Code.ensure_loaded?(Raxol.Config.Schema)
    _ = Code.ensure_loaded?(Raxol.Config.Schema.Definitions)
    :ok
  end

  defp parse_env_value(value) do
    normalize_string_value(value)
  end

  defp build_nested_config(key_value_pairs) do
    Enum.reduce(key_value_pairs, %{}, fn {keys, value}, acc ->
      put_nested(acc, keys, value)
    end)
  end

  defp put_nested(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_nested(map, [key | rest], value) do
    sub_map = Map.get(map, key, %{})
    Map.put(map, key, put_nested(sub_map, rest, value))
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp find_config_files(directory) do
    find_files_in_directory(File.dir?(directory), directory)
  end

  defp detect_format(path) do
    case String.downcase(Path.extname(path)) do
      ".toml" -> :toml
      ".json" -> :json
      ".yaml" -> :yaml
      ".yml" -> :yaml
      _ -> :unknown
    end
  end

  defp encode_config(config, format, pretty) do
    case format do
      :json -> encode_json(config, pretty)
      :toml -> encode_toml(config)
      :yaml -> encode_yaml(config)
      _ -> {:error, {:unsupported_export_format, format}}
    end
  end

  defp encode_json(config, pretty) do
    stringified = Raxol.Utils.MapUtils.stringify_keys(config)
    Jason.encode(stringified, pretty: pretty)
  end

  defp encode_toml(config) do
    # Would need a TOML encoder - using simplified version
    stringified = Raxol.Utils.MapUtils.stringify_keys(config)
    {:ok, inspect(stringified)}
  end

  defp encode_yaml(config) do
    # Would need a YAML encoder
    stringified = Raxol.Utils.MapUtils.stringify_keys(config)
    {:ok, inspect(stringified)}
  end

  defp ensure_directory(path) do
    path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp watch_loop(paths, callback, processed_events) do
    receive do
      {:file_event, _watcher, {file_path, events}} ->
        # Debounce events to avoid multiple calls for the same file
        event_key = {file_path, events}

        process_file_event(
          not MapSet.member?(processed_events, event_key),
          event_key,
          file_path,
          paths,
          callback,
          processed_events
        )

      {:remove_event, event_key} ->
        new_processed = MapSet.delete(processed_events, event_key)
        watch_loop(paths, callback, new_processed)

      _ ->
        watch_loop(paths, callback, processed_events)
    end
  end
end
