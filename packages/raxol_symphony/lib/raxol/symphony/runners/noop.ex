defmodule Raxol.Symphony.Runners.Noop do
  @moduledoc """
  Test-only runner with directable behaviour.

  Behaviour is configured via a process-registered `Agent` named
  `Raxol.Symphony.Runners.Noop.Director`. Tests start the director and
  register per-issue actions:

      Director.set("MT-1", {:succeed_after, 50})
      Director.set("MT-2", {:fail_after, 50, :boom})
      Director.set("MT-3", :stall)

  When no directive is set for an issue, the default action is
  `{:succeed_after, 0}`.

  Supported actions:

  - `{:succeed_after, ms}` -- sleep `ms`, return `:ok`.
  - `{:fail_after, ms, reason}` -- sleep `ms`, return `{:error, reason}`.
  - `:stall` -- never returns; useful for stall-detection tests.
  - `{:emit, [event_map | _], next}` -- send events to parent, then run
    `next` action.
  - `{:pause, interrupt_reason, token}` -- return `{:pause, ...}` so the
    orchestrator parks the run. On resume, the runner uses the next action
    registered for the same issue identifier (default `{:succeed_after, 0}`).
  - `{:pause_then, interrupt_reason, token, next}` -- same as `:pause` but
    queues `next` as the action used on resume.
  """

  @behaviour Raxol.Symphony.Runner

  alias Raxol.Symphony.{Config, Issue}

  @impl true
  def run(%Issue{identifier: identifier} = issue, %Config{} = _config, opts) do
    parent = Keyword.fetch!(opts, :parent)

    if Keyword.has_key?(opts, :resume_value) do
      resume_action = __MODULE__.Director.fetch_resume(identifier)
      send(parent, {:run_event, issue.id, %{event: :resumed}})
      do_run(resume_action, issue, parent)
    else
      action = __MODULE__.Director.fetch(identifier)
      do_run(action, issue, parent)
    end
  end

  defp do_run({:succeed_after, ms}, _issue, _parent) do
    Process.sleep(ms)
    :ok
  end

  defp do_run({:fail_after, ms, reason}, _issue, _parent) do
    Process.sleep(ms)
    {:error, reason}
  end

  defp do_run(:stall, _issue, _parent) do
    Process.sleep(:infinity)
  end

  defp do_run({:emit, events, next}, issue, parent) when is_list(events) do
    for event <- events do
      send(parent, {:run_event, issue.id, event})
    end

    do_run(next, issue, parent)
  end

  defp do_run({:pause, interrupt_reason, token}, _issue, _parent) do
    {:pause, interrupt_reason, token}
  end

  defp do_run(
         {:pause_then, interrupt_reason, token, next},
         %Issue{identifier: identifier},
         _parent
       ) do
    __MODULE__.Director.set_resume(identifier, next)
    {:pause, interrupt_reason, token}
  end

  defmodule Director do
    @moduledoc "Per-test directive store for the Noop runner."

    @doc false
    def child_spec(_opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, []}, restart: :transient}
    end

    @spec start_link() :: Agent.on_start()
    def start_link do
      Agent.start_link(fn -> %{actions: %{}, resume: %{}} end, name: __MODULE__)
    end

    @spec set(binary(), term()) :: :ok
    def set(identifier, action) do
      Agent.update(__MODULE__, fn state ->
        %{state | actions: Map.put(state.actions, identifier, action)}
      end)
    end

    @spec fetch(binary()) :: term()
    def fetch(identifier) do
      Agent.get(__MODULE__, fn state ->
        Map.get(state.actions, identifier, {:succeed_after, 0})
      end)
    end

    @spec set_resume(binary(), term()) :: :ok
    def set_resume(identifier, action) do
      Agent.update(__MODULE__, fn state ->
        %{state | resume: Map.put(state.resume, identifier, action)}
      end)
    end

    @spec fetch_resume(binary()) :: term()
    def fetch_resume(identifier) do
      Agent.get_and_update(__MODULE__, fn state ->
        action = Map.get(state.resume, identifier, {:succeed_after, 0})
        {action, %{state | resume: Map.delete(state.resume, identifier)}}
      end)
    end

    @spec clear() :: :ok
    def clear do
      Agent.update(__MODULE__, fn _ -> %{actions: %{}, resume: %{}} end)
    end
  end
end
