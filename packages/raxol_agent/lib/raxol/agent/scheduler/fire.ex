defmodule Raxol.Agent.Scheduler.Fire do
  @moduledoc """
  Runs one scheduled job as a fresh, history-free agent turn.

  Each fire builds a single-message conversation from the job's `prompt`,
  injects the bodies of the job's attached skills (read from `Skills.Store`) as a
  system prompt, and runs it through `Raxol.Agent.Stream`. No conversation
  history is carried between fires, so a daily job does not accumulate context;
  the injected skills supply the procedures it needs. Returns `{:ok, rendered}`
  for the scheduler to deliver, or `{:error, reason}`.

  This is the `Scheduler`'s default `:runner`. `runner/1` builds the
  `(job -> result)` closure with options captured.

  ## Options

    * `:agent_opts` -- forwarded to `Raxol.Agent.Stream` (`:backend`,
      `:backend_opts`, `:executor`, `:provider`, `:model`, ...). When neither
      `:backend` nor `:executor` is pinned, `auto_provider: true` is added so the
      executor resolves from the environment (Mock on failure), mirroring the
      gateway agent handler.
    * `:actions` -- action modules the fire may call. When non-empty the fire
      runs the ReAct loop with `context[:in_cron]` set (so a scheduled agent
      cannot schedule more cron work); when empty the fire is one completion.
    * `:skills` -- the `Skills.Store` server to read skill bodies from
      (default `Raxol.Agent.Skills.Store`).
    * `:system_prompt` -- a base system prompt the injected-skills block is
      appended to.
  """

  alias Raxol.Agent.Actions.Cronjob
  alias Raxol.Agent.Skills
  alias Raxol.Agent.Stream

  @spec runner(keyword()) :: (map() -> {:ok, String.t()} | {:error, term()})
  def runner(opts \\ []), do: fn job -> run(job, opts) end

  @spec run(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def run(job, opts \\ []) do
    run_opts =
      opts
      |> Keyword.get(:agent_opts, [])
      |> maybe_default_provider()
      |> put_system_prompt(compose_system_prompt(job, opts))

    job.prompt
    |> run_stream(run_opts, Keyword.get(opts, :actions, []))
    |> Stream.collect()
    |> normalize()
  end

  # -- turn -------------------------------------------------------------------

  # No tools: a single completion. The prompt string becomes a lone user turn --
  # no prior history is threaded in, which is what keeps fires independent.
  defp run_stream(prompt, run_opts, []) do
    Stream.run(prompt, run_opts)
  end

  # With tools: the ReAct loop, with `in_cron` marked in the context so the
  # cronjob action's recursion guard fires if this agent tries to schedule work.
  defp run_stream(prompt, run_opts, actions) do
    context = run_opts |> Keyword.get(:context, %{}) |> Map.put(:in_cron, true)

    react_opts =
      run_opts
      |> Keyword.put(:actions, guard_cronjob_action(actions, run_opts))
      |> Keyword.put(:context, context)

    Stream.react(prompt, react_opts)
  end

  # The cronjob action's recursion guard lives in its `run/2` and reads
  # `context[:in_cron]`. A native (vendor-owns-loop) backend runs its own tool
  # loop and executes tools out-of-process over MCP, where that context never
  # arrives -- so the guard would silently not fire and a scheduled agent could
  # schedule, trigger, or re-arm more cron work. There is nothing to thread the
  # guard onto on that path, so fail closed: withhold the cronjob action entirely
  # rather than expose unpoliced schedule-more-work capability to a fresh fire.
  # The framework path enforces the guard in-process and keeps the action, which
  # is why this only strips when the resolved backend is native. This guards ONE
  # action by name; a second context-guarded action (e.g. #726's authorizer /
  # hooks / owner enforcement over the native MCP path) needs its own clause here,
  # it is not covered by adding this action to some list. `native_tool_loop?/1`
  # re-resolves the backend (a second resolve if the turn also auto-provisions),
  # but only after the cheap `Cronjob in actions` membership test, so the common
  # no-cronjob fire never resolves twice and pays nothing.
  defp guard_cronjob_action(actions, run_opts) do
    if Cronjob in actions and Stream.native_tool_loop?(run_opts) do
      Enum.reject(actions, &(&1 == Cronjob))
    else
      actions
    end
  end

  defp normalize({:ok, %{content: content}}) when is_binary(content), do: {:ok, content}
  defp normalize({:ok, other}), do: {:error, {:unexpected_turn_result, other}}
  defp normalize({:error, reason}), do: {:error, reason}

  # -- system prompt + skills -------------------------------------------------

  defp compose_system_prompt(job, opts) do
    [Keyword.get(opts, :system_prompt), skills_block(job, opts)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
    |> nilify_empty()
  end

  defp skills_block(%{skills: []}, _opts), do: nil

  defp skills_block(%{skills: names}, opts) when is_list(names) do
    server = Keyword.get(opts, :skills, Skills.Store)

    case Enum.flat_map(names, &render_skill(server, &1)) do
      [] -> nil
      blocks -> "You have the following skills available:\n\n" <> Enum.join(blocks, "\n\n")
    end
  end

  defp skills_block(_job, _opts), do: nil

  defp render_skill(server, name) do
    case fetch_skill(server, name) do
      {:ok, body} -> ["## Skill: #{name}\n\n#{body}"]
      :error -> []
    end
  end

  # A missing or unreachable skills store degrades to "no skills", never a crash:
  # a fire should still run its prompt when a skill cannot be loaded.
  defp fetch_skill(server, name) do
    case safe(fn -> Skills.Store.get(name, server: server) end) do
      {:ok, {:ok, %{body: body}}} when is_binary(body) -> {:ok, body}
      _other -> :error
    end
  end

  defp safe(fun) do
    {:ok, fun.()}
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # -- opts helpers -----------------------------------------------------------

  # auto_provider only when nothing is pinned: a resolved environment executor
  # wins over :backend, so defaulting it unconditionally could hijack an
  # explicitly pinned backend.
  defp maybe_default_provider(opts) do
    if Keyword.has_key?(opts, :backend) or Keyword.has_key?(opts, :executor),
      do: opts,
      else: Keyword.put_new(opts, :auto_provider, true)
  end

  defp put_system_prompt(opts, nil), do: opts
  defp put_system_prompt(opts, prompt), do: Keyword.put(opts, :system_prompt, prompt)

  defp nilify_empty(""), do: nil
  defp nilify_empty(str), do: str
end
