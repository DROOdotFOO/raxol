defmodule Raxol.Core.Runtime.Plugins.PluginValidator do
  @moduledoc """
  Comprehensive validation system for plugins before loading.

  Validates security, compatibility, performance, and structural
  correctness to ensure plugins are safe and properly implemented.
  """

  alias Raxol.Core.Runtime.Plugins.Loader
  alias Raxol.Core.Runtime.Plugins.Security.BeamAnalyzer

  @type validation_result :: :ok | {:error, term()}
  @type plugin_metadata :: %{
          name: String.t(),
          version: String.t(),
          author: String.t(),
          description: String.t(),
          dependencies: [String.t()],
          api_version: String.t()
        }

  @required_callbacks [:init, :handle_event, :cleanup]
  # 10MB limit
  @max_plugin_size 10_000_000
  @supported_api_versions ["1.0", "1.1", "2.0"]

  @doc """
  Validates that a plugin is not already loaded.
  """
  @spec validate_not_loaded(String.t(), map()) ::
          :ok | {:error, :already_loaded}
  def validate_not_loaded(plugin_id, plugins) do
    if Map.has_key?(plugins, plugin_id),
      do: {:error, :already_loaded},
      else: :ok
  end

  @doc """
  Validates that a plugin module implements the required behaviour.
  """
  @spec validate_behaviour(module()) ::
          :ok
          | {:error,
             :module_not_found
             | :invalid_plugin_behaviour
             | {:missing_callbacks, [atom()]}}
  def validate_behaviour(plugin_module) do
    with :ok <- check_module_loaded(plugin_module),
         :ok <- check_plugin_behaviour(plugin_module) do
      check_required_callbacks(plugin_module)
    end
  end

  @doc """
  Validates plugin metadata and configuration.
  """
  @spec validate_metadata(module()) ::
          :ok
          | {:error,
             :missing_metadata
             | :invalid_metadata
             | {:missing_metadata_fields, [atom()]}
             | :invalid_version_format
             | {:unsupported_api_version, String.t()}
             | :invalid_plugin_name}
  def validate_metadata(plugin_module) do
    case get_plugin_metadata(plugin_module) do
      {:ok, metadata} ->
        with :ok <- validate_required_fields(metadata),
             :ok <- validate_version_format(metadata.version),
             :ok <- validate_api_version(metadata.api_version) do
          validate_name_format(metadata.name)
        end

      {:error, :no_metadata} ->
        {:error, :missing_metadata}

      error ->
        error
    end
  end

  @doc """
  Validates plugin security aspects.
  """
  @spec validate_security(module(), map()) :: :ok | {:error, term()}
  def validate_security(plugin_module, options \\ %{}) do
    with :ok <- validate_file_access(plugin_module, options),
         :ok <- validate_network_access(plugin_module, options) do
      validate_code_injection(plugin_module)
    end
  end

  @doc """
  Validates plugin compatibility with the current system.
  """
  @spec validate_compatibility(module()) ::
          :ok
          | {:error,
             {:elixir_version_too_old, String.t(), String.t()}
             | {:otp_version_too_old, String.t(), String.t()}}
  def validate_compatibility(_plugin_module) do
    with :ok <- validate_elixir_version() do
      validate_otp_version()
    end
  end

  @doc """
  Validates plugin performance characteristics.
  """
  @spec validate_performance(module()) ::
          :ok
          | {:error,
             {:initialization_failed, term()}
             | {:initialization_too_slow, non_neg_integer()}
             | {:plugin_too_large, non_neg_integer(), non_neg_integer()}
             | {:size_check_failed, term()}}
  def validate_performance(plugin_module) do
    with :ok <- validate_initialization_time(plugin_module) do
      validate_plugin_size(plugin_module)
    end
  end

  @doc """
  Validates plugin dependencies.
  """
  @spec validate_dependencies(module(), map()) :: validation_result()
  def validate_dependencies(plugin_module, loaded_plugins) do
    case get_dependencies(plugin_module) do
      :none -> :ok
      {:ok, deps} -> check_missing_deps(deps, loaded_plugins)
      {:error, _} -> {:error, :invalid_dependencies}
    end
  end

  defp get_dependencies(plugin_module) do
    if function_exported?(plugin_module, :dependencies, 0) do
      case safe_call_plugin(fn -> plugin_module.dependencies() end, 1000) do
        {:ok, deps} when is_list(deps) -> {:ok, deps}
        _ -> {:error, :invalid_dependencies}
      end
    else
      :none
    end
  end

  defp check_missing_deps(deps, loaded_plugins) do
    missing = Enum.reject(deps, &Map.has_key?(loaded_plugins, &1))
    if missing == [], do: :ok, else: {:error, {:missing_dependencies, missing}}
  end

  @doc """
  Resolves plugin identity from string or module.
  """
  @spec resolve_plugin_identity(String.t() | module()) ::
          {:ok, {String.t(), module()}} | {:error, term()}
  def resolve_plugin_identity(id) when is_binary(id) do
    case Loader.load_code(id) do
      {:ok, module} -> {:ok, {id, module}}
      {:error, reason} -> {:error, reason}
    end
  end

  def resolve_plugin_identity(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      id = module |> Atom.to_string() |> String.replace("Elixir.", "")
      {:ok, {id, module}}
    else
      {:error, :module_not_found}
    end
  end

  # --- Private ---

  defp check_module_loaded(plugin_module) do
    if Code.ensure_loaded?(plugin_module),
      do: :ok,
      else: {:error, :module_not_found}
  end

  defp check_plugin_behaviour(plugin_module) do
    if Loader.behaviour_implemented?(
         plugin_module,
         Raxol.Core.Runtime.Plugins.Plugin
       ),
       do: :ok,
       else: {:error, :invalid_plugin_behaviour}
  end

  defp check_required_callbacks(plugin_module) do
    available = plugin_module.__info__(:functions)

    missing =
      Enum.reject(@required_callbacks, fn callback ->
        Enum.any?(available, fn {name, _arity} -> name == callback end)
      end)

    if missing == [], do: :ok, else: {:error, {:missing_callbacks, missing}}
  end

  defp get_plugin_metadata(plugin_module) do
    if function_exported?(plugin_module, :metadata, 0) do
      case safe_call_plugin(fn -> plugin_module.metadata() end, 1000) do
        {:ok, metadata} when is_map(metadata) -> {:ok, metadata}
        {:ok, _} -> {:error, :invalid_metadata}
        {:error, _reason} -> {:error, :invalid_metadata}
      end
    else
      {:error, :no_metadata}
    end
  end

  defp validate_required_fields(metadata) do
    required = [:name, :version, :author, :api_version]
    missing = Enum.reject(required, &Map.has_key?(metadata, &1))

    if missing == [],
      do: :ok,
      else: {:error, {:missing_metadata_fields, missing}}
  end

  defp validate_version_format(version) do
    if Regex.match?(~r/^\d+\.\d+(\.\d+)?(-\w+)?$/, version),
      do: :ok,
      else: {:error, :invalid_version_format}
  end

  defp validate_api_version(api_version) do
    if api_version in @supported_api_versions,
      do: :ok,
      else: {:error, {:unsupported_api_version, api_version}}
  end

  defp validate_name_format(name) do
    if Regex.match?(~r/^[a-zA-Z][a-zA-Z0-9_]*$/, name),
      do: :ok,
      else: {:error, :invalid_plugin_name}
  end

  defp validate_file_access(plugin_module, %{restrict_file_access: true}) do
    if BeamAnalyzer.has_file_access?(plugin_module),
      do: {:error, :file_access_detected},
      else: :ok
  end

  defp validate_file_access(_plugin_module, _options), do: :ok

  defp validate_network_access(plugin_module, %{restrict_network_access: true}) do
    if BeamAnalyzer.has_network_access?(plugin_module),
      do: {:error, :network_access_detected},
      else: :ok
  end

  defp validate_network_access(_plugin_module, _options), do: :ok

  defp validate_code_injection(plugin_module) do
    if BeamAnalyzer.has_code_injection_risk?(plugin_module),
      do: {:error, :code_injection_risk_detected},
      else: :ok
  end

  defp validate_elixir_version do
    current = System.version()
    min = "1.12.0"

    if Version.compare(current, min) in [:eq, :gt],
      do: :ok,
      else: {:error, {:elixir_version_too_old, current, min}}
  end

  defp validate_otp_version do
    current = System.otp_release()
    min = "24"

    if String.to_integer(current) >= String.to_integer(min),
      do: :ok,
      else: {:error, {:otp_version_too_old, current, min}}
  end

  defp validate_initialization_time(plugin_module) do
    max_init_time = 5_000_000

    case safe_call_plugin(
           fn -> :timer.tc(fn -> plugin_module.init(%{}) end) end,
           6000
         ) do
      {:ok, {time, _result}} when time > max_init_time ->
        {:error, {:initialization_too_slow, time}}

      {:ok, {_time, _result}} ->
        :ok

      {:error, reason} ->
        {:error, {:initialization_failed, reason}}
    end
  end

  defp validate_plugin_size(plugin_module) do
    with {:ok, path} <- get_module_path(plugin_module),
         {:ok, stat} <- File.stat(path) do
      if stat.size > @max_plugin_size,
        do: {:error, {:plugin_too_large, stat.size, @max_plugin_size}},
        else: :ok
    else
      {:error, reason} -> {:error, {:size_check_failed, reason}}
    end
  end

  defp get_module_path(plugin_module) do
    case :code.which(plugin_module) do
      path when is_list(path) -> {:ok, path}
      _ -> {:error, :module_path_not_found}
    end
  end

  defp safe_call_plugin(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> {:ok, result}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:crashed, reason}}
    end
  end
end
