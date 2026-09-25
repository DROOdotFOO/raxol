defmodule Raxol.Security.UserContext.ContextServer do
  @moduledoc """
  GenServer implementation for Security User Context management.

  This server manages user context state for security-related operations,
  eliminating Process dictionary usage in encryption and security modules.

  ## Features
  - Current user tracking
  - Session management
  - Security context storage
  - Audit trail support
  """

  use Raxol.Core.Behaviours.BaseManager
  alias Raxol.Core.Runtime.Log
  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Returns a child specification for this server.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # Public API

  @doc """
  Sets the current user for the calling process.
  """
  def set_current_user(user_id) do
    GenServer.call(__MODULE__, {:set_user, self(), user_id})
  end

  @doc """
  Gets the current user for the calling process.
  Returns "system" if no user is set.
  """
  def get_current_user do
    GenServer.call(__MODULE__, {:get_user, self()})
  end

  @doc """
  Clears the current user for the calling process.
  """
  def clear_current_user do
    GenServer.call(__MODULE__, {:clear_user, self()})
  end

  @doc """
  Sets additional security context for the calling process.
  """
  def set_context(key, value) do
    GenServer.call(__MODULE__, {:set_context, self(), key, value})
  end

  @doc """
  Gets security context for the calling process.
  """
  def get_context(key, default \\ nil) do
    GenServer.call(__MODULE__, {:get_context, self(), key, default})
  end

  @doc """
  Gets all context for the calling process.
  """
  def get_all_context do
    GenServer.call(__MODULE__, {:get_all_context, self()})
  end

  @doc """
  Clears all context for the calling process.
  """
  def clear_context do
    GenServer.call(__MODULE__, {:clear_context, self()})
  end

  @doc """
  Records an audit event for the current user.
  """
  def audit_log(action, details \\ %{}) do
    GenServer.cast(__MODULE__, {:audit_log, self(), action, details})
  end

  # Server Callbacks

  @impl true
  def init_manager(opts) do
    # Ensure :pg is started (handle case where it's already running)
    case :pg.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    state = %{
      # Map of pid -> user context
      contexts: %{},
      # Map of pid -> monitor ref
      monitors: %{},
      # Audit log (limited size)
      audit_log: [],
      # Configuration
      default_user: Keyword.get(opts, :default_user, "system"),
      max_audit_entries: Keyword.get(opts, :max_audit_entries, 1000)
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_call({:set_user, pid, user_id}, _from, state) do
    # Monitor the process if not already monitored
    state = ensure_monitored(pid, state)

    # Update context
    contexts =
      Map.update(
        state.contexts,
        pid,
        %{user: user_id, context: %{}},
        fn ctx -> %{ctx | user: user_id} end
      )

    {:reply, :ok, %{state | contexts: contexts}}
  end

  @impl true
  def handle_manager_call({:get_user, pid}, _from, state) do
    user =
      case Map.get(state.contexts, pid) do
        nil -> state.default_user
        %{user: user} -> user
      end

    {:reply, user, state}
  end

  @impl true
  def handle_manager_call({:clear_user, pid}, _from, state) do
    contexts =
      Map.update(
        state.contexts,
        pid,
        %{user: state.default_user, context: %{}},
        fn ctx -> %{ctx | user: state.default_user} end
      )

    {:reply, :ok, %{state | contexts: contexts}}
  end

  @impl true
  def handle_manager_call({:set_context, pid, key, value}, _from, state) do
    # Monitor the process if not already monitored
    state = ensure_monitored(pid, state)

    contexts =
      Map.update(
        state.contexts,
        pid,
        %{user: state.default_user, context: %{key => value}},
        fn ctx ->
          %{ctx | context: Map.put(ctx.context, key, value)}
        end
      )

    {:reply, :ok, %{state | contexts: contexts}}
  end

  @impl true
  def handle_manager_call({:get_context, pid, key, default}, _from, state) do
    value =
      case Map.get(state.contexts, pid) do
        nil -> default
        %{context: context} -> Map.get(context, key, default)
      end

    {:reply, value, state}
  end

  @impl true
  def handle_manager_call({:get_all_context, pid}, _from, state) do
    context =
      case Map.get(state.contexts, pid) do
        nil -> %{user: state.default_user, context: %{}}
        ctx -> ctx
      end

    {:reply, context, state}
  end

  @impl true
  def handle_manager_call({:clear_context, pid}, _from, state) do
    contexts =
      case Map.has_key?(state.contexts, pid) do
        true ->
          Map.delete(state.contexts, pid)

        false ->
          state.contexts
      end

    # Stop monitoring if context is cleared
    state =
      case Map.has_key?(state.monitors, pid) do
        true ->
          ref = Map.get(state.monitors, pid)
          Process.demonitor(ref)
          %{state | monitors: Map.delete(state.monitors, pid)}

        false ->
          state
      end

    {:reply, :ok, %{state | contexts: contexts}}
  end

  @impl true
  def handle_manager_cast({:audit_log, pid, action, details}, state) do
    user =
      case Map.get(state.contexts, pid) do
        nil -> state.default_user
        %{user: user} -> user
      end

    entry = %{
      timestamp: DateTime.utc_now(),
      user: user,
      action: action,
      details: details,
      pid: inspect(pid)
    }

    # Add to audit log (with size limit)
    audit_log = [entry | state.audit_log] |> Enum.take(state.max_audit_entries)

    # Log for external systems if needed
    Log.info("Security audit: User #{user} performed #{action}", entry)

    {:noreply, %{state | audit_log: audit_log}}
  end

  @impl true
  def handle_manager_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Clean up context for dead process; monitors are keyed by pid
    contexts = Map.delete(state.contexts, pid)
    monitors = Map.delete(state.monitors, pid)

    {:noreply, %{state | contexts: contexts, monitors: monitors}}
  end

  # Private helpers

  defp ensure_monitored(pid, state) do
    case Map.has_key?(state.monitors, pid) do
      true ->
        state

      false ->
        ref = Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, pid, ref)}
    end
  end
end
