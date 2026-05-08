defmodule Raxol.Symphony.Surfaces.Watch.Formatter do
  @moduledoc """
  Pure functions that map Symphony orchestrator events into watch-sized
  notification payloads.

  Notifications follow the shape used by `Raxol.Watch.Formatter`:

      %{
        title: String.t(),
        body: String.t(),
        category: String.t(),
        actions: [%{id: String.t(), label: String.t()}],
        priority: :high | :normal | :silent,
        badge: non_neg_integer()
      }

  Bodies are truncated to 160 chars (the `Raxol.Watch.Formatter` budget for
  watch screens). Priority maps to push behaviour:

  - `:high` -- bypasses notifier debounce (preflight failures, blockers)
  - `:normal` -- standard delivery (failures, manual stops)
  - `:silent` -- no vibration (clean completions)

  ## Action callback ids

  Action ids use the `sym:` namespace so a single action handler can
  dispatch:

  - `sym:approve:<issue_id>` -- "tap-to-approve" for blocked runs
  - `sym:stop:<issue_id>` -- terminate a run
  - `sym:refresh` -- request orchestrator tick
  - `sym:dismiss` -- dismiss the notification (no orchestrator side effects)
  """

  @max_body_length 160

  @type notification :: %{
          title: String.t(),
          body: String.t(),
          category: String.t(),
          actions: [%{id: String.t(), label: String.t()}],
          priority: :high | :normal | :silent,
          badge: non_neg_integer()
        }

  @doc """
  Maps a Symphony orchestrator event into a watch notification, or
  `:skip` for events the watch should ignore (`:tick_completed`, etc.).
  """
  @spec event_notification(term(), map()) :: notification() | :skip
  def event_notification(:tick_completed, _snapshot), do: :skip

  def event_notification(:worker_exit_normal, snapshot) do
    %{
      title: "Symphony",
      body: truncate("Run completed. running #{counts(snapshot).running}, retrying #{counts(snapshot).retrying}"),
      category: "symphony_completed",
      actions: [refresh_action(), dismiss_action()],
      priority: :silent,
      badge: 0
    }
  end

  def event_notification(:worker_exit_abnormal, snapshot) do
    %{
      title: "Symphony",
      body: truncate("Run failed -- queued for retry. retrying #{counts(snapshot).retrying}"),
      category: "symphony_failure",
      actions: [refresh_action(), dismiss_action()],
      priority: :normal,
      badge: counts(snapshot).retrying
    }
  end

  def event_notification(:worker_stopped, _snapshot) do
    %{
      title: "Symphony",
      body: truncate("Run stopped by operator."),
      category: "symphony_stopped",
      actions: [refresh_action(), dismiss_action()],
      priority: :silent,
      badge: 0
    }
  end

  def event_notification({:preflight_failed, reason}, _snapshot) do
    %{
      title: "Symphony BLOCKED",
      body: truncate("Workflow validation failed: #{inspect(reason)}. Dispatch paused."),
      category: "symphony_blocker",
      actions: [
        %{id: "sym:approve", label: "Approve"},
        refresh_action(),
        dismiss_action()
      ],
      priority: :high,
      badge: 1
    }
  end

  def event_notification(_other, _snapshot), do: :skip

  @doc """
  Builds a per-run notification with a tap-to-stop action. Useful for the
  Human Review pattern: a run reaches a state requiring operator input and
  the watch surfaces it.
  """
  @spec run_notification(map()) :: notification()
  def run_notification(run) when is_map(run) do
    %{
      title: "Symphony: #{run.issue_identifier}",
      body: truncate("State: #{run.state} -- turn #{run.turn_count}"),
      category: "symphony_run",
      actions: [
        %{id: "sym:stop:#{run.issue_id}", label: "Stop"},
        %{id: "sym:approve:#{run.issue_id}", label: "Approve"},
        dismiss_action()
      ],
      priority: :normal,
      badge: 1
    }
  end

  @doc "Builds a snapshot summary suitable for an on-demand `/status` push."
  @spec snapshot_notification(map()) :: notification()
  def snapshot_notification(snapshot) do
    c = counts(snapshot)

    %{
      title: "Symphony",
      body: truncate("running #{c.running}, retrying #{c.retrying}"),
      category: "symphony_status",
      actions: [refresh_action(), dismiss_action()],
      priority: :silent,
      badge: 0
    }
  end

  @doc "Returns the max body length used by the formatter."
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  # -- Helpers ----------------------------------------------------------------

  defp counts(%{counts: c}), do: c
  defp counts(_), do: %{running: 0, retrying: 0}

  defp refresh_action, do: %{id: "sym:refresh", label: "Refresh"}
  defp dismiss_action, do: %{id: "sym:dismiss", label: "Dismiss"}

  defp truncate(text) when is_binary(text) do
    if String.length(text) <= @max_body_length do
      text
    else
      String.slice(text, 0, @max_body_length - 3) <> "..."
    end
  end
end
