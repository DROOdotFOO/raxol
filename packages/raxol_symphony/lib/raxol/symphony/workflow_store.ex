defmodule Raxol.Symphony.WorkflowStore do
  @moduledoc """
  Owns the parsed + validated `Raxol.Symphony.Config` and (optionally) hot-
  reloads it when `WORKFLOW.md` changes on disk.

  ## Responsibilities (SPEC s5.6 + s6.3)

  - Hold the current valid `Config.t()`. Callers (notably `Orchestrator`)
    fetch it with `get/1` on every dispatch tick.
  - Watch the workflow file via `:file_system` (optional dep) and reload on
    change. Multiple rapid events are coalesced into one reload via a 200ms
    debounce -- editors that write atomically (rename/replace) can fire
    several events per save.
  - Fall back to **last-known-good**: if the new file fails to parse or
    validate, the store keeps serving the previously-loaded `Config` and
    records the failure in `last_error/1`. The orchestrator never sees a
    bad config mid-run.
  - Notify subscribers on successful reload via
    `{:workflow_store, :reloaded, Config.t()}`.

  ## Modes

  - **Watcher mode** (default when `:path` is given and `:file_system` is
    loaded): live reloads on disk change.
  - **Load-once mode**: when `:file_system` is not loaded or `watch?: false`
    is passed, the store loads once at init and never reloads on its own;
    `reload/1` still works for manual refresh.
  - **Static mode**: when `:config` is passed and no `:path`, the store
    just holds the given config -- useful for tests and embedded use.

  ## Options

      WorkflowStore.start_link(
        path: "/repo/WORKFLOW.md",  # required unless :config is given
        config: %Config{...},        # static config (skips load)
        watch?: true,                # default true
        debounce_ms: 200,            # default 200
        name: __MODULE__             # default __MODULE__
      )
  """

  use GenServer
  require Logger

  alias Raxol.Symphony.Config

  @default_debounce_ms 200

  defstruct [
    :path,
    :config,
    :last_error,
    :last_reloaded_at,
    :watcher_pid,
    :debounce_ref,
    debounce_ms: @default_debounce_ms,
    listeners: MapSet.new(),
    watcher_enabled: false
  ]

  @type t :: %__MODULE__{
          path: Path.t() | nil,
          config: Config.t() | nil,
          last_error: term() | nil,
          last_reloaded_at: integer() | nil,
          watcher_pid: pid() | nil,
          debounce_ref: reference() | nil,
          debounce_ms: pos_integer(),
          listeners: MapSet.t(pid()),
          watcher_enabled: boolean()
        }

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Returns the currently-cached `Config.t()` (last-known-good)."
  @spec get(GenServer.server()) :: Config.t() | nil
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  end

  @doc """
  Forces a synchronous re-read + re-validate of the workflow file.

  Returns `{:ok, config}` or `{:error, reason}`. On error, the cached config
  is unchanged.
  """
  @spec reload(GenServer.server()) :: {:ok, Config.t()} | {:error, term()}
  def reload(server \\ __MODULE__) do
    GenServer.call(server, :reload)
  end

  @doc "Subscribe the calling process to reload events."
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Returns the most recent reload error, or `nil` if last reload succeeded."
  @spec last_error(GenServer.server()) :: term() | nil
  def last_error(server \\ __MODULE__) do
    GenServer.call(server, :last_error)
  end

  @doc "Returns true when a file-system watcher is active for the workflow path."
  @spec watching?(GenServer.server()) :: boolean()
  def watching?(server \\ __MODULE__) do
    GenServer.call(server, :watching?)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
    state = %__MODULE__{
      path: Keyword.get(opts, :path),
      config: Keyword.get(opts, :config),
      debounce_ms: Keyword.get(opts, :debounce_ms, @default_debounce_ms)
    }

    state = maybe_initial_load(state)
    state = maybe_start_watcher(state, Keyword.get(opts, :watch?, true))

    {:ok, state}
  end

  @impl true
  def handle_call(:get, _from, %__MODULE__{} = state) do
    {:reply, state.config, state}
  end

  def handle_call(:reload, _from, %__MODULE__{} = state) do
    case do_reload(state) do
      {:ok, new_state} -> {:reply, {:ok, new_state.config}, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
  end

  def handle_call({:subscribe, pid}, _from, %__MODULE__{} = state) do
    Process.monitor(pid)
    {:reply, :ok, %__MODULE__{state | listeners: MapSet.put(state.listeners, pid)}}
  end

  def handle_call(:last_error, _from, %__MODULE__{} = state) do
    {:reply, state.last_error, state}
  end

  def handle_call(:watching?, _from, %__MODULE__{} = state) do
    {:reply, state.watcher_enabled, state}
  end

  @impl true
  def handle_info({:file_event, _watcher, {changed_path, _events}}, %__MODULE__{} = state) do
    if matches_workflow?(state.path, changed_path) do
      ref = make_ref()
      Process.send_after(self(), {:debounced_reload, ref}, state.debounce_ms)
      {:noreply, %__MODULE__{state | debounce_ref: ref}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, :stop}, %__MODULE__{} = state) do
    Logger.warning("symphony.workflow_store.watcher_stopped path=#{inspect(state.path)}")
    {:noreply, %__MODULE__{state | watcher_pid: nil, watcher_enabled: false}}
  end

  def handle_info({:debounced_reload, ref}, %__MODULE__{debounce_ref: ref} = state) do
    case do_reload(state) do
      {:ok, new_state} ->
        notify_listeners(new_state)
        {:noreply, %__MODULE__{new_state | debounce_ref: nil}}

      {:error, _reason, new_state} ->
        {:noreply, %__MODULE__{new_state | debounce_ref: nil}}
    end
  end

  # Stale debounce -- a newer one superseded it.
  def handle_info({:debounced_reload, _stale_ref}, %__MODULE__{} = state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %__MODULE__{} = state) do
    {:noreply, %__MODULE__{state | listeners: MapSet.delete(state.listeners, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Internals --------------------------------------------------------------

  defp maybe_initial_load(%__MODULE__{config: %Config{}} = state), do: state

  defp maybe_initial_load(%__MODULE__{path: nil} = state) do
    %__MODULE__{state | last_error: :no_path_or_config}
  end

  defp maybe_initial_load(%__MODULE__{path: path} = state) when is_binary(path) do
    case Config.load_and_validate(path) do
      {:ok, config} ->
        %__MODULE__{
          state
          | config: config,
            last_error: nil,
            last_reloaded_at: System.system_time(:millisecond)
        }

      {:error, reason} ->
        Logger.error(
          "symphony.workflow_store.initial_load_failed path=#{path} reason=#{inspect(reason)}"
        )

        %__MODULE__{state | last_error: reason}
    end
  end

  defp maybe_start_watcher(%__MODULE__{path: nil} = state, _watch?), do: state
  defp maybe_start_watcher(%__MODULE__{} = state, false), do: state

  defp maybe_start_watcher(%__MODULE__{path: path} = state, true) do
    if Code.ensure_loaded?(FileSystem) do
      start_watcher(state, path)
    else
      Logger.info(
        "symphony.workflow_store.no_file_system_dep workflow_path=#{path} -- " <>
          "running in load-once mode (add :file_system to deps for hot-reload)"
      )

      state
    end
  end

  defp start_watcher(%__MODULE__{} = state, path) do
    dir = Path.dirname(Path.expand(path))

    case FileSystem.start_link(dirs: [dir]) do
      {:ok, pid} ->
        FileSystem.subscribe(pid)
        %__MODULE__{state | watcher_pid: pid, watcher_enabled: true}

      {:error, reason} ->
        Logger.warning(
          "symphony.workflow_store.watcher_start_failed dir=#{dir} reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp matches_workflow?(nil, _changed), do: false

  defp matches_workflow?(workflow_path, changed_path) do
    Path.expand(workflow_path) == Path.expand(changed_path)
  end

  defp do_reload(%__MODULE__{path: nil} = state), do: {:error, :no_path, state}

  defp do_reload(%__MODULE__{path: path} = state) do
    case Config.load_and_validate(path) do
      {:ok, config} ->
        Logger.info("symphony.workflow_store.reload_ok path=#{path}")

        new_state = %__MODULE__{
          state
          | config: config,
            last_error: nil,
            last_reloaded_at: System.system_time(:millisecond)
        }

        {:ok, new_state}

      {:error, reason} ->
        Logger.warning(
          "symphony.workflow_store.reload_failed path=#{path} reason=#{inspect(reason)} " <>
            "kept_last_known_good=#{not is_nil(state.config)}"
        )

        {:error, reason, %__MODULE__{state | last_error: reason}}
    end
  end

  defp notify_listeners(%__MODULE__{config: nil}), do: :ok

  defp notify_listeners(%__MODULE__{} = state) do
    for pid <- state.listeners do
      send(pid, {:workflow_store, :reloaded, state.config})
    end

    :ok
  end
end
