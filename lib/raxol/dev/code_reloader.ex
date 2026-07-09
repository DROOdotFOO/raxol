defmodule Raxol.Dev.CodeReloader do
  @moduledoc """
  Watches `lib/` for file changes and triggers recompilation + re-render.

  Only starts in `:dev` environment. Uses the `file_system` library to
  watch for `*.ex` changes, debounces rapid edits, then calls
  `IEx.Helpers.recompile/0` and sends `:render_needed` to the Lifecycle.
  """

  use GenServer

  @debounce_ms Raxol.Core.Defaults.sync_interval_ms()

  defstruct [:watcher_pid, :timer_ref, :lifecycle_pid]

  def start_link(lifecycle_pid) do
    GenServer.start_link(__MODULE__, lifecycle_pid, name: __MODULE__)
  end

  @impl true
  def init(lifecycle_pid) do
    case FileSystem.start_link(
           dirs: [Path.expand("lib")],
           name: :code_reloader_watcher
         ) do
      {:ok, watcher_pid} ->
        FileSystem.subscribe(:code_reloader_watcher)

        Raxol.Core.Runtime.Log.info("[CodeReloader] Watching lib/ for changes")

        {:ok,
         %__MODULE__{
           watcher_pid: watcher_pid,
           timer_ref: nil,
           lifecycle_pid: lifecycle_pid
         }}

      :ignore ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[CodeReloader] File watcher not available (no filesystem backend)",
          %{}
        )

        {:ok,
         %__MODULE__{
           watcher_pid: nil,
           timer_ref: nil,
           lifecycle_pid: lifecycle_pid
         }}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[CodeReloader] Failed to start file watcher: #{inspect(reason)}",
          %{}
        )

        {:ok,
         %__MODULE__{
           watcher_pid: nil,
           timer_ref: nil,
           lifecycle_pid: lifecycle_pid
         }}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, {path, _events}}, state) do
    if String.ends_with?(path, ".ex") do
      state = cancel_pending_timer(state)
      timer_ref = Process.send_after(self(), :recompile, @debounce_ms)
      {:noreply, %{state | timer_ref: timer_ref}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:file_event, _watcher_pid, :stop}, state) do
    Raxol.Core.Runtime.Log.info("[CodeReloader] File watcher stopped")
    {:noreply, state}
  end

  @impl true
  def handle_info(:recompile, state) do
    Raxol.Core.Runtime.Log.info("[CodeReloader] Recompiling...")

    result = IEx.Helpers.recompile()

    case result do
      :ok ->
        Raxol.Core.Runtime.Log.info("[CodeReloader] Recompilation succeeded")

      :noop ->
        Raxol.Core.Runtime.Log.debug("[CodeReloader] Nothing to recompile")

      :error ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[CodeReloader] Recompilation failed",
          %{}
        )
    end

    if result in [:ok, :noop] && state.lifecycle_pid &&
         Process.alive?(state.lifecycle_pid) do
      send(state.lifecycle_pid, :render_needed)
    end

    {:noreply, %{state | timer_ref: nil}}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cancel_pending_timer(state)
    :ok
  end

  defp cancel_pending_timer(%{timer_ref: nil} = state), do: state

  defp cancel_pending_timer(%{timer_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
