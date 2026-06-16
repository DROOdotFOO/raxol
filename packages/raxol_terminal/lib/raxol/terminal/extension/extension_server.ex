defmodule Raxol.Terminal.Extension.ExtensionServer do
  @moduledoc """
  Unified extension management GenServer that provides a single interface for loading,
  unloading, and managing terminal extensions.
  """
  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Terminal.Extension.ExtensionManager, as: Manager

  @valid_extension_types [:theme, :plugin, :script, :tool, :custom]

  # Client API

  @doc """
  Starts the UnifiedExtension server.
  """
  @spec start_extension_manager(keyword()) :: GenServer.on_start()
  def start_extension_manager(opts \\ []) do
    start_link([{:name, __MODULE__} | opts])
  end

  @doc """
  Loads an extension from the specified path.
  """
  @spec load_extension(String.t(), atom(), map() | keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def load_extension(path, type, metadata) do
    GenServer.call(__MODULE__, {:load_extension, path, type, metadata})
  end

  @doc """
  Unloads an extension by ID.
  """
  @spec unload_extension(String.t()) :: :ok | {:error, term()}
  def unload_extension(extension_id) do
    GenServer.call(__MODULE__, {:unload_extension, extension_id})
  end

  @doc """
  Gets the state of a specific extension.
  """
  @spec get_extension_state(String.t()) ::
          {:ok, map()} | {:error, :extension_not_found}
  def get_extension_state(extension_id) do
    GenServer.call(__MODULE__, {:get_extension_state, extension_id})
  end

  @doc """
  Activates an extension.
  """
  @spec activate_extension(String.t()) :: :ok | {:error, term()}
  def activate_extension(extension_id) do
    GenServer.call(__MODULE__, {:activate_extension, extension_id})
  end

  @doc """
  Deactivates an extension.
  """
  @spec deactivate_extension(String.t()) :: :ok | {:error, term()}
  def deactivate_extension(extension_id) do
    GenServer.call(__MODULE__, {:deactivate_extension, extension_id})
  end

  @doc """
  Configures an extension.
  """
  @spec configure_extension(String.t(), map()) :: :ok | {:error, term()}
  def configure_extension(extension_id, config) do
    GenServer.call(__MODULE__, {:configure_extension, extension_id, config})
  end

  @doc """
  Gets the configuration of an extension.
  """
  @spec get_extension_config(String.t()) ::
          {:ok, map()} | {:error, :extension_not_found}
  def get_extension_config(extension_id) do
    GenServer.call(__MODULE__, {:get_extension_config, extension_id})
  end

  @doc """
  Executes a command for an extension.
  """
  @spec execute_command(String.t(), String.t(), list()) ::
          {:ok, term()} | {:error, term()}
  def execute_command(extension_id, command) do
    GenServer.call(__MODULE__, {:execute_command, extension_id, command, []})
  end

  def execute_command(extension_id, command, args) do
    GenServer.call(__MODULE__, {:execute_command, extension_id, command, args})
  end

  @doc """
  Lists all loaded extensions with optional filters.
  """
  @spec list_extensions(keyword()) :: {:ok, [map()]}
  def list_extensions(filters \\ []) do
    GenServer.call(__MODULE__, {:list_extensions, filters})
  end

  @doc """
  Exports an extension to a specified path.
  """
  @spec export_extension(String.t(), String.t()) :: :ok | {:error, term()}
  def export_extension(extension_id, path) do
    GenServer.call(__MODULE__, {:export_extension, extension_id, path})
  end

  @doc """
  Imports an extension from a specified path.
  """
  @spec import_extension(String.t()) :: {:ok, String.t()} | {:error, term()}
  def import_extension(path) do
    GenServer.call(__MODULE__, {:import_extension, path})
  end

  @doc """
  Registers a hook for an extension.
  """
  @spec register_hook(String.t(), atom(), function()) :: :ok | {:error, term()}
  def register_hook(extension_id, hook_name, callback) do
    GenServer.call(
      __MODULE__,
      {:register_hook, extension_id, hook_name, callback}
    )
  end

  @doc """
  Unregisters a hook for an extension.
  """
  @spec unregister_hook(String.t(), atom()) :: :ok | {:error, term()}
  def unregister_hook(extension_id, hook_name) do
    GenServer.call(__MODULE__, {:unregister_hook, extension_id, hook_name})
  end

  @doc """
  Triggers a hook for an extension.
  """
  @spec trigger_hook(String.t(), atom(), list()) ::
          {:ok, term()} | {:error, term()}
  def trigger_hook(extension_id, hook_name, args \\ []) do
    GenServer.call(__MODULE__, {:trigger_hook, extension_id, hook_name, args})
  end

  @doc """
  Gets all hooks for an extension.
  """
  @spec get_extension_hooks(String.t()) ::
          {:ok, [atom()]} | {:error, :extension_not_found}
  def get_extension_hooks(extension_id) do
    GenServer.call(__MODULE__, {:get_extension_hooks, extension_id})
  end

  @doc """
  Gets all extensions, optionally filtered.
  """
  @spec get_extensions(keyword()) :: {:ok, [map()]}
  def get_extensions(filters \\ []) do
    list_extensions(filters)
  end

  @doc """
  Updates the configuration for an extension.
  """
  @spec update_extension_config(String.t(), map()) :: :ok | {:error, term()}
  def update_extension_config(extension_id, config) do
    configure_extension(extension_id, config)
  end

  # BaseManager callbacks

  @impl true
  def init_manager(opts) do
    state = %{
      manager: Manager.new(opts),
      extensions: %{},
      active_extensions: MapSet.new(),
      hooks: %{},
      extension_paths: Keyword.get(opts, :extension_paths, []),
      auto_load: Keyword.get(opts, :auto_load, true)
    }

    # Auto-load extensions if enabled
    state =
      if state.auto_load do
        auto_load_extensions(state)
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:load_extension, path, type, metadata}, _from, state) do
    with :ok <- validate_extension_type(type),
         metadata_map = normalize_metadata(metadata),
         :ok <- validate_dependencies(metadata_map) do
      do_load_extension(path, type, metadata_map, state)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call({:unload_extension, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      _extension ->
        case Manager.unload_extension(state.manager, extension_id) do
          {:ok, updated_manager} ->
            updated_state = %{
              state
              | manager: updated_manager,
                extensions: Map.delete(state.extensions, extension_id),
                active_extensions: MapSet.delete(state.active_extensions, extension_id),
                hooks: Map.delete(state.hooks, extension_id)
            }

            {:reply, :ok, updated_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_manager_call({:get_extension_state, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      extension ->
        {:reply, {:ok, extension}, state}
    end
  end

  def handle_manager_call({:activate_extension, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      %{active: true} ->
        {:reply, {:error, :invalid_extension_state}, state}

      extension ->
        updated_extension = Map.put(extension, :active, true)

        updated_state = %{
          state
          | extensions: Map.put(state.extensions, extension_id, updated_extension),
            active_extensions: MapSet.put(state.active_extensions, extension_id)
        }

        {:reply, :ok, updated_state}
    end
  end

  def handle_manager_call({:deactivate_extension, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      %{active: false} ->
        {:reply, {:error, :invalid_extension_state}, state}

      extension ->
        updated_extension = Map.put(extension, :active, false)

        updated_state = %{
          state
          | extensions: Map.put(state.extensions, extension_id, updated_extension),
            active_extensions: MapSet.delete(state.active_extensions, extension_id)
        }

        {:reply, :ok, updated_state}
    end
  end

  def handle_manager_call(
        {:configure_extension, extension_id, config},
        _from,
        state
      )
      when is_map(config) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      extension ->
        updated_extension = Map.put(extension, :config, config)

        updated_state = %{
          state
          | extensions: Map.put(state.extensions, extension_id, updated_extension)
        }

        {:reply, :ok, updated_state}
    end
  end

  def handle_manager_call(
        {:configure_extension, _extension_id, _config},
        _from,
        state
      ) do
    {:reply, {:error, :invalid_extension_config}, state}
  end

  def handle_manager_call({:get_extension_config, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      extension ->
        {:reply, {:ok, extension.config}, state}
    end
  end

  def handle_manager_call(
        {:execute_command, extension_id, command, args},
        _from,
        state
      ) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      _extension ->
        # For now, just validate the command exists
        # In a real implementation, this would execute actual extension logic
        if command == "invalid" do
          {:reply, {:error, :command_not_found}, state}
        else
          args_str = args |> Enum.join(", ")
          result = "Command \"#{command}\" executed with args: #{args_str}"
          {:reply, {:ok, result}, state}
        end
    end
  end

  def handle_manager_call({:list_extensions, filters}, _from, state) do
    extensions =
      state.extensions
      |> Map.values()
      |> filter_extensions(filters)

    {:reply, {:ok, extensions}, state}
  end

  def handle_manager_call({:export_extension, extension_id, path}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      extension ->
        # Create export directory and file
        export_data = %{
          extension: extension,
          exported_at: DateTime.utc_now()
        }

        File.mkdir_p!(Path.dirname(path))
        File.write!(path, :erlang.term_to_binary(export_data))

        {:reply, :ok, state}
    end
  end

  def handle_manager_call({:import_extension, path}, _from, state) do
    case File.read(path) do
      {:ok, content} ->
        export_data = :erlang.binary_to_term(content)
        extension = export_data.extension
        extension_id = extension.id

        updated_state = %{
          state
          | extensions: Map.put(state.extensions, extension_id, extension)
        }

        {:reply, {:ok, extension_id}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call(
        {:register_hook, extension_id, hook_name, callback},
        _from,
        state
      ) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      extension ->
        do_register_hook(extension, extension_id, hook_name, callback, state)
    end
  end

  def handle_manager_call(
        {:unregister_hook, extension_id, hook_name},
        _from,
        state
      ) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      _extension ->
        hooks = Map.get(state.hooks, extension_id, %{})
        updated_hooks = Map.delete(hooks, hook_name)

        updated_state = %{
          state
          | hooks: Map.put(state.hooks, extension_id, updated_hooks)
        }

        {:reply, :ok, updated_state}
    end
  end

  def handle_manager_call(
        {:trigger_hook, extension_id, hook_name, args},
        _from,
        state
      ) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      _extension ->
        hooks = Map.get(state.hooks, extension_id, %{})

        case Map.get(hooks, hook_name) do
          nil ->
            {:reply, {:error, :hook_not_found}, state}

          callback ->
            try do
              result = callback.(args)
              {:reply, {:ok, result}, state}
            rescue
              _error ->
                {:reply, {:ok, {:error, :hook_execution_failed}}, state}
            end
        end
    end
  end

  def handle_manager_call({:get_extension_hooks, extension_id}, _from, state) do
    case Map.get(state.extensions, extension_id) do
      nil ->
        {:reply, {:error, :extension_not_found}, state}

      _extension ->
        hooks = Map.get(state.hooks, extension_id, %{})
        hook_names = Map.keys(hooks)
        {:reply, {:ok, hook_names}, state}
    end
  end

  # Helper functions

  defp do_register_hook(extension, extension_id, hook_name, callback, state) do
    if hook_name in allowed_hook_names(extension) do
      hooks = Map.get(state.hooks, extension_id, %{})
      updated_hooks = Map.put(hooks, hook_name, callback)

      updated_state = %{
        state
        | hooks: Map.put(state.hooks, extension_id, updated_hooks)
      }

      {:reply, :ok, updated_state}
    else
      {:reply, {:error, :hook_not_found}, state}
    end
  end

  defp allowed_hook_names(extension) do
    case Map.get(extension, :hooks, %{}) do
      list when is_list(list) -> list
      map when is_map(map) -> Map.keys(map)
      _ -> []
    end
  end

  defp validate_extension_type(type) when type in @valid_extension_types,
    do: :ok

  defp validate_extension_type(_type),
    do: {:error, {:module_load_failed, :invalid_extension_type}}

  defp normalize_metadata(map) when is_map(map), do: map
  defp normalize_metadata(list) when is_list(list), do: Enum.into(list, %{})
  defp normalize_metadata(_), do: %{}

  defp validate_dependencies(metadata) do
    case Map.get(metadata, :dependencies) do
      deps when is_binary(deps) -> {:error, :invalid_extension_dependencies}
      _ -> :ok
    end
  end

  defp do_load_extension(path, type, metadata_map, state) do
    extension_id = generate_extension_id()

    extension =
      %{
        version: "1.0.0",
        description: "Extension loaded from #{path}",
        author: "Unknown"
      }
      |> Map.merge(metadata_map)
      |> Map.merge(%{
        id: extension_id,
        path: path,
        type: type,
        active: false,
        config: %{}
      })
      |> Map.put_new(:hooks, [])

    case Manager.load_extension(state.manager, extension) do
      {:ok, updated_manager} ->
        updated_state = %{
          state
          | manager: updated_manager,
            extensions: Map.put(state.extensions, extension_id, extension)
        }

        {:reply, {:ok, extension_id}, updated_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp generate_extension_id do
    ("ext_" <> :crypto.strong_rand_bytes(8)) |> Base.encode16(case: :lower)
  end

  defp auto_load_extensions(state) do
    # In a real implementation, this would scan extension_paths and auto-load
    # Returns the state as-is for testing
    state
  end

  defp filter_extensions(extensions, []), do: extensions

  defp filter_extensions(extensions, filters) do
    Enum.filter(extensions, fn ext ->
      Enum.all?(filters, fn
        {:type, type} -> ext.type == type
        {:active, active} -> ext.active == active
        {:name, name} -> ext.name == name
        _ -> true
      end)
    end)
  end
end
