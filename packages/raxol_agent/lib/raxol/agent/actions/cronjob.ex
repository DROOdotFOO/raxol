defmodule Raxol.Agent.Actions.Cronjob do
  @moduledoc """
  LLM-callable scheduled-task action over `Raxol.Agent.Scheduler`.

  One action with an `action` field
  (`create`/`list`/`update`/`pause`/`resume`/`run`/`remove`), reaching the
  scheduler via `context[:scheduler]` the same way `Raxol.Agent.Actions.Skills`
  reaches its store via `context[:skills]`. A job carries a `prompt`, a
  `schedule`, the `skills` to inject on each fire, a delivery `target`, and an
  `enabled` flag.

  Schedules are parsed once, at creation: pass a crontab (`"0 9 * * 1-5"`), an
  interval (`"every 2h"`), a relative delay (`"30m"`), or an ISO 8601 timestamp.
  Convert any natural-language schedule to one of those forms yourself before
  calling; the scheduler never runs an LLM per tick.

  ## Owner scoping

  Jobs are stamped with `context[:owner]` on `create`, `list` is filtered to the
  caller's own jobs, and every id-based action (`update`/`pause`/`resume`/`run`/
  `remove`) confirms the job's owner matches `context[:owner]` before acting; a
  cross-owner id is reported as `:not_found`. When no `:owner` is in context
  (single-tenant) all jobs match.

  ## Recursion guard

  When the run context carries `in_cron: true` (a fire started by the scheduler
  itself), `create`/`run`/`update`/`resume` return `{:error, :cron_in_cron}` so a
  scheduled agent cannot schedule, trigger, or re-arm more scheduled work. The
  read and work-reducing actions (`list`/`pause`/`remove`) remain available.
  """

  use Raxol.Agent.Action,
    name: "cronjob",
    description:
      "Schedule recurring or one-shot agent tasks and deliver their output. " <>
        "action create: schedule a new job; list: show jobs; update: change one; " <>
        "pause/resume: toggle firing; run: fire now; remove: delete. " <>
        "Pass schedule as a crontab ('0 9 * * 1-5'), interval ('every 2h'), " <>
        "relative delay ('30m'), or ISO 8601 timestamp -- convert natural language yourself.",
    schema: [
      input: [
        action: [
          type: :string,
          required: true,
          enum: ["create", "list", "update", "pause", "resume", "run", "remove"],
          description: "What to do."
        ],
        id: [
          type: :string,
          description: "The job id (required for update/pause/resume/run/remove)."
        ],
        prompt: [
          type: :string,
          description: "The task prompt the fired agent runs (create/update)."
        ],
        schedule: [
          type: :string,
          description:
            "When to fire: crontab, \"every <duration>\", a relative delay, or an ISO 8601 timestamp."
        ],
        skills: [type: {:list, :string}, description: "Names of skills to inject on each fire."],
        target: [
          type: :string,
          description: "Gateway route to deliver to, e.g. \"telegram:-100123\"."
        ],
        enabled: [type: :boolean, description: "Whether the job fires (default true)."]
      ],
      output: []
    ]

  alias Raxol.Agent.Scheduler

  @impl true
  def run(%{action: action} = params, context) do
    case Map.fetch(context, :scheduler) do
      {:ok, server} -> dispatch(action, params, server, context)
      :error -> {:error, :scheduler_not_configured}
    end
  end

  # Recursion guard: inside a fire, block anything that creates or re-arms work
  # (create/run/update/resume). Reads and work-reducing lifecycle ops
  # (list/pause/remove) stay available.
  defp dispatch(action, _params, _server, %{in_cron: true})
       when action in ["create", "run", "update", "resume"] do
    {:error, :cron_in_cron}
  end

  defp dispatch("create", params, server, context) do
    attrs =
      %{
        prompt: Map.get(params, :prompt),
        schedule: Map.get(params, :schedule),
        skills: Map.get(params, :skills, []),
        target: Map.get(params, :target),
        owner: Map.get(context, :owner)
      }
      |> put_optional(:enabled, Map.get(params, :enabled))

    case Scheduler.create(server, attrs) do
      {:ok, job} -> {:ok, job_view(job)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("list", _params, server, context) do
    jobs = server |> Scheduler.list(owner: Map.get(context, :owner)) |> Enum.map(&job_view/1)
    {:ok, %{jobs: jobs, count: length(jobs)}}
  end

  defp dispatch("update", params, server, context) do
    with_owned_job(params, server, context, fn id ->
      case params |> Map.take([:prompt, :schedule, :skills, :target, :enabled]) |> reject_nil() do
        changes when map_size(changes) == 0 -> {:error, :empty_update}
        changes -> view_result(Scheduler.update(server, id, changes))
      end
    end)
  end

  defp dispatch("pause", params, server, context) do
    with_owned_job(params, server, context, fn id -> view_result(Scheduler.pause(server, id)) end)
  end

  defp dispatch("resume", params, server, context) do
    with_owned_job(params, server, context, fn id -> view_result(Scheduler.resume(server, id)) end)
  end

  defp dispatch("run", params, server, context) do
    with_owned_job(params, server, context, fn id ->
      case Scheduler.run(server, id) do
        :ok -> {:ok, %{ok: true, id: id}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp dispatch("remove", params, server, context) do
    with_owned_job(params, server, context, fn id ->
      :ok = Scheduler.remove(server, id)
      {:ok, %{ok: true, id: id}}
    end)
  end

  # -- helpers ----------------------------------------------------------------

  # Resolve the id, confirm the job belongs to the caller's owner, then run the
  # operation. A cross-owner id is reported as :not_found so the action never
  # confirms a job's existence to a different owner.
  defp with_owned_job(params, server, context, fun) do
    with {:ok, id} <- require_id(params),
         {:ok, job} <- Scheduler.get(server, id),
         :ok <- authorize(job, context) do
      fun.(id)
    end
  end

  defp authorize(job, context) do
    if job.owner == Map.get(context, :owner), do: :ok, else: {:error, :not_found}
  end

  defp view_result({:ok, job}), do: {:ok, job_view(job)}
  defp view_result({:error, reason}), do: {:error, reason}

  defp require_id(params) do
    case Map.get(params, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _other -> {:error, :missing_id}
    end
  end

  defp job_view(job) do
    %{
      id: job.id,
      prompt: job.prompt,
      schedule: job.schedule_spec,
      skills: job.skills,
      target: job.target,
      enabled: job.enabled,
      next_fire: format_time(job.next_fire),
      last_fired_at: format_time(job.last_fired_at),
      fire_count: job.fire_count
    }
  end

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp reject_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)
end
