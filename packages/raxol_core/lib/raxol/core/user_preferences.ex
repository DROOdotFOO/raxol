defmodule Raxol.Core.UserPreferences do
  @moduledoc """
  Manages user preferences for the terminal emulator.

  Acts as a GenServer holding the preferences state and handles persistence.

  Uses `Raxol.Core.Utils.Debounce` for debounced save operations, avoiding
  redundant disk writes when multiple preference changes occur in quick succession.
  """

  alias Raxol.Core.Runtime.Log
  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Preferences.Persistence
  alias Raxol.Core.Utils.Debounce

  @save_delay_ms 1000

  defmodule State do
    @moduledoc "Internal state for the UserPreferences GenServer."
    defstruct preferences: %{},
              debounce: nil
  end

  @impl true
  def init_manager(opts) do
    preferences = initialize_preferences(Keyword.get(opts, :test_mode?, false))
    {:ok, %State{preferences: preferences, debounce: Debounce.new()}}
  end

  def get(key_or_path, pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, {:get, key_or_path})
  end

  def set(key_or_path, value, pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, {:set, key_or_path, value})
  end

  def save!(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :save_now)
  end

  def get_all(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_all)
  end

  def set_preferences(preferences, pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, {:set_preferences, preferences})
  end

  def reset_to_defaults_for_test!(pid_or_name \\ __MODULE__) do
    case Process.whereis(pid_or_name) do
      nil ->
        # Process is not alive, just return ok
        :ok

      _pid ->
        # Process is alive, call the reset function
        GenServer.call(pid_or_name, :reset_to_defaults)
    end
  end

  @impl true
  def handle_manager_call({:get, key_or_path}, _from, state) do
    path = normalize_path(key_or_path)
    value = get_in(state.preferences, path)
    {:reply, value, state}
  end

  @impl true
  def handle_manager_call({:set, key_or_path, value}, from, state) do
    path = normalize_path(key_or_path)
    current_value = get_in(state.preferences, path)

    handle_preference_change(
      current_value == value,
      current_value,
      value,
      path,
      state,
      from
    )
  end

  @impl true
  def handle_manager_call(:get_all, _from, state) do
    {:reply, state.preferences, state}
  end

  @impl true
  def handle_manager_call({:set_preferences, preferences}, from, state) do
    new_preferences = deep_merge(state.preferences, preferences)

    Raxol.Core.Runtime.Log.debug("All preferences updated: #{inspect(preferences)}")

    new_state = %{state | preferences: new_preferences}

    {caller_pid, _} = from

    send(
      caller_pid,
      {:preferences_applied, Process.info(self(), :registered_name) |> elem(1) || self()}
    )

    {:reply, :ok, schedule_save(new_state)}
  end

  @impl true
  def handle_manager_call(:save_now, _from, state) do
    state = cancel_pending_save(state)

    case Persistence.save(state.preferences) do
      :ok ->
        Raxol.Core.Runtime.Log.debug("User preferences saved immediately.")
        {:reply, :ok, state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error("Failed to save preferences immediately: #{inspect(reason)}")

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_manager_call(:reset_to_defaults, _from, state) do
    Raxol.Core.Runtime.Log.info("UserPreferences resetting to defaults for test.")

    new_preferences = default_preferences()
    state = cancel_pending_save(state)

    new_state = %{state | preferences: new_preferences}

    {:reply, :ok, new_state}
  end

  defp schedule_save(%State{debounce: debounce} = state) do
    {new_debounce, _ref} = Debounce.schedule(debounce, :save, @save_delay_ms)
    %{state | debounce: new_debounce}
  end

  defp cancel_pending_save(%State{debounce: debounce} = state) do
    %{state | debounce: Debounce.cancel(debounce, :save)}
  end

  @impl true
  def handle_manager_info({:debounce, :save, debounce_id}, state) do
    if Debounce.valid?(state.debounce, :save, debounce_id) do
      case Persistence.save(state.preferences) do
        :ok ->
          Raxol.Core.Runtime.Log.debug("User preferences saved after debounce delay.")

        {:error, reason} ->
          Raxol.Core.Runtime.Log.error(
            "Failed to save preferences after delay: #{inspect(reason)}"
          )
      end

      new_debounce = Debounce.clear(state.debounce, :save)
      {:noreply, %{state | debounce: new_debounce}}
    else
      # Stale debounce message, ignore
      {:noreply, state}
    end
  end

  @impl true
  def handle_manager_info(msg, state) do
    case msg do
      {:preferences_applied, _pid} ->
        {:noreply, state}

      # Legacy message format - ignore
      {:perform_delayed_save, _timer_id} ->
        {:noreply, state}

      _ ->
        Raxol.Core.Runtime.Log.warning_with_context(inspect(msg), %{})
        {:noreply, state}
    end
  end

  defp deep_merge(map1, map2) do
    Map.merge(map1, map2, fn _key, val1, val2 ->
      merge_values(is_map(val1) and is_map(val2), val1, val2)
    end)
  end

  defp normalize_path(path) when is_atom(path), do: [path]
  defp normalize_path(path) when is_list(path), do: path

  defp normalize_path(path) when is_binary(path) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           String.split(path, ".")
           |> Enum.map(&String.to_existing_atom/1)
         end) do
      {:ok, result} ->
        result

      # safe_call/1 returns {:error, exception}, not {:error, {exception, stacktrace}}
      {:error, %ArgumentError{}} ->
        Raxol.Core.Runtime.Log.error(
          "Invalid preference path string: #{inspect(path)} - cannot convert segments to atoms."
        )

        []

      {:error, _} ->
        []
    end
  end

  # Helper functions for if-statement elimination
  defp initialize_preferences(true) do
    Raxol.Core.Runtime.Log.info("UserPreferences starting in test mode, using defaults only.")

    default_preferences()
  end

  defp initialize_preferences(false) do
    case Persistence.load() do
      {:ok, loaded_prefs} ->
        Raxol.Core.Runtime.Log.info("User preferences loaded successfully.")
        deep_merge(default_preferences(), loaded_prefs)

      {:error, :file_not_found} ->
        Raxol.Core.Runtime.Log.info("No preferences file found, using defaults.")

        default_preferences()

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning(
          "Failed to load preferences: #{inspect(reason)}, using defaults."
        )

        default_preferences()
    end
  end

  @spec handle_preference_change(any(), any(), any(), String.t(), map(), any()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_preference_change(
         true,
         _current_value,
         _value,
         _path,
         state,
         from
       ) do
    # Value unchanged - only send notification in test mode
    send_notification_if_test(from)
    {:reply, :ok, state}
  end

  @spec handle_preference_change(any(), any(), any(), String.t(), map(), any()) ::
          {:ok, any()}
          | {:error, any()}
          | {:reply, any(), any()}
          | {:noreply, any()}
  defp handle_preference_change(false, _current_value, value, path, state, from) do
    new_preferences = put_in(state.preferences, path, value)

    Raxol.Core.Runtime.Log.debug("Preference updated: #{inspect(path)} = #{inspect(value)}")

    new_state = %{state | preferences: new_preferences}

    {caller_pid, _} = from

    send(
      caller_pid,
      {:preferences_applied, Process.info(self(), :registered_name) |> elem(1) || self()}
    )

    {:reply, :ok, schedule_save(new_state)}
  end

  defp send_notification_if_test({caller_pid, _}) do
    is_test = Code.ensure_loaded?(Mix) and Mix.env() == :test
    execute_test_notification(is_test, caller_pid)
  end

  defp execute_test_notification(false, _caller_pid), do: :ok

  defp execute_test_notification(true, caller_pid) do
    send(
      caller_pid,
      {:preferences_applied, Process.info(self(), :registered_name) |> elem(1) || self()}
    )
  end

  defp merge_values(true, val1, val2), do: deep_merge(val1, val2)
  defp merge_values(false, _val1, val2), do: val2

  @doc """
  Returns the current theme id as an atom, defaulting to :default if not set or invalid.
  """
  def get_theme_id(pid_or_name \\ __MODULE__) do
    theme = get([:theme, :active_id], pid_or_name) || get(:theme, pid_or_name)
    normalize_theme_id(theme)
  end

  defp normalize_theme_id(theme) when is_atom(theme) do
    theme
  end

  defp normalize_theme_id(theme) when is_binary(theme) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           String.to_existing_atom(theme)
         end) do
      {:ok, result} -> result
      # safe_call/1 returns {:error, exception}, not {:error, {exception, stacktrace}}
      {:error, %ArgumentError{}} -> :default
      {:error, _} -> :default
    end
  end

  defp normalize_theme_id(_theme) do
    :default
  end

  @doc """
  Returns the default preferences map: theme, terminal, accessibility and
  keybindings sections.

  raxol_core does not depend on raxol_terminal, so the `:terminal` section is
  read from application config, first match wins:

    1. `config :raxol_core, :default_terminal_preferences, value`, for a
       consumer that wants its own defaults;
    2. `:default_terminal_preferences` in the `:raxol_terminal` application
       env, which raxol_terminal ships in its `.app` file as
       `{Raxol.Terminal.Config.Defaults, :generate_default_config, []}`;
    3. otherwise `%{}` (raxol_core on its own).

  `value` is a map or an `{module, function, args}` whose call returns a map.
  Anything else, including an MFA whose function is not exported, logs a
  warning and yields `%{}`.
  """
  def default_preferences do
    %{
      theme: %{
        active_id: :default
      },
      terminal: default_terminal_preferences(),
      accessibility: %{
        enabled: true,
        screen_reader: true,
        high_contrast: false,
        reduced_motion: false,
        keyboard_focus: true,
        large_text: false,
        silence_announcements: false
      },
      keybindings:
        %{
          # Add default keybindings here
        }
    }
  end

  defp default_terminal_preferences do
    with :error <- Application.fetch_env(:raxol_core, :default_terminal_preferences),
         :error <- Application.fetch_env(:raxol_terminal, :default_terminal_preferences) do
      %{}
    else
      {:ok, value} -> resolve_terminal_preferences(value)
    end
  end

  defp resolve_terminal_preferences(%{} = defaults), do: defaults

  defp resolve_terminal_preferences({mod, fun, args} = mfa)
       when is_atom(mod) and is_atom(fun) and is_list(args) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, length(args)) do
      case apply(mod, fun, args) do
        %{} = defaults -> defaults
        other -> invalid_terminal_preferences(mfa, "returned #{inspect(other)}")
      end
    else
      invalid_terminal_preferences(mfa, "is not an exported function")
    end
  end

  defp resolve_terminal_preferences(other),
    do: invalid_terminal_preferences(other, "is neither a map nor an {m, f, a}")

  defp invalid_terminal_preferences(value, reason) do
    Raxol.Core.Runtime.Log.warning(
      "Ignoring :default_terminal_preferences #{inspect(value)}: #{reason}; " <>
        "terminal defaults are %{}"
    )

    %{}
  end
end
