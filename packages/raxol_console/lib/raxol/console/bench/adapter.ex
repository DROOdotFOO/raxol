defmodule Raxol.Console.Bench.Adapter do
  @moduledoc """
  Native Console bench: validate a generated package by booting the real Raxol
  runtime in-process and running the boot / prompt / task-dry-run checks against
  it. This is the `:raxol` counterpart to `Raxol.ACP.Console.Bench.Local`.

  Where `Bench.Local` shells out to an operator wrapper over a `Port` (the
  incumbent runtimes are moving targets, so their glue stays runtime-agnostic),
  Raxol *is* the runtime: the adapter loads the package, builds a headless
  `RuntimeConfig` (no channels, no external MCP servers), boots
  `Raxol.Console.Supervisor`, and exercises the same per-fire turn primitive
  (`Raxol.Agent.Scheduler.Fire.runner/1`) that a scheduled task runs -- so the
  checks observe the real inference path with only the LLM faked at the boundary
  by the deployment's configured backend. No dashboard auth, no per-job hosting.

  Wired into `raxol_acp` by config from the package above it (which avoids a
  compile cycle: `raxol_acp` only knows the `Raxol.ACP.Console.Bench` behaviour):

      config :raxol_acp, :console_bench_module, Raxol.Console.Bench.Adapter

  Inference and check tuning come from `config :raxol_console, :bench`:

      config :raxol_console, :bench,
        agent_opts: [backend: MyBackend, backend_opts: [...]],
        prompt: "Introduce yourself in one sentence and state your purpose.",
        timeout_ms: 120_000

  `:agent_opts` is the executor every turn runs under; an unconfigured
  environment falls back to the agent's own backend resolution (Mock without
  credentials), which boots but makes the prompt check non-meaningful, so a real
  `bench_validated` deployment configures a real backend.

  Evidence shape matches the behaviour:
  `%{checks: [{:boot | :prompt | :task_dry_run, :ok}], transcript: binary()}`.
  Any failure -- a bad package, a boot crash, a turn error, or a timeout --
  returns a typed `{:error, _}` that blocks delivery.
  """

  @behaviour Raxol.ACP.Console.Bench

  alias Raxol.ACP.Console.Package
  alias Raxol.Agent.Scheduler.Fire
  alias Raxol.Console.{Boot, RuntimeConfig}

  @default_prompt "Introduce yourself in one sentence and state your purpose."
  @default_timeout 120_000
  @cap 64 * 1024

  @impl true
  def run(pkg_dir, _spec) do
    cfg = Application.get_env(:raxol_console, :bench, [])

    with {:ok, pkg} <- load(pkg_dir),
         {:ok, rc} <- build_config(pkg, cfg),
         {:ok, sup, boot_entry} <- boot(rc) do
      try do
        checks(rc, cfg, boot_entry)
      after
        stop(sup)
      end
    end
  end

  # -- stages ----------------------------------------------------------------

  defp load(pkg_dir) do
    case Package.load(pkg_dir) do
      {:ok, pkg} -> {:ok, pkg}
      {:error, reason} -> {:error, {:bench_load_failed, reason}}
    end
  end

  # Headless: no channels (scheduler-only) and no bundled MCP servers, so the
  # bench never opens a socket or spawns an npx/uvx child. The executor is the
  # deployment's configured backend.
  defp build_config(pkg, cfg) do
    opts = [
      bundle_default_mcp: false,
      channels: [],
      agent_opts: Keyword.get(cfg, :agent_opts, [])
    ]

    case RuntimeConfig.build(pkg, opts) do
      {:ok, rc} -> {:ok, rc}
      {:error, reason} -> {:error, {:bench_config_failed, reason}}
    end
  end

  # Boot proves the supervised tree (persona-wired scheduler + reconciler
  # converging the package's tasks) stands up. Unique names let benches run
  # concurrently (see `Raxol.ACP.Console.BenchSlots`).
  defp boot(rc) do
    suffix = System.unique_integer([:positive])

    names = [
      name: :"Raxol.Console.Bench.#{suffix}",
      scheduler_name: :"Raxol.Console.Bench.Scheduler.#{suffix}",
      reconciler_name: :"Raxol.Console.Bench.Reconciler.#{suffix}"
    ]

    case Boot.start(rc, names) do
      {:ok, report} -> {:ok, report.supervisor, boot_section(report)}
      {:error, reason} -> {:error, {:bench_failed, :boot, reason}}
    end
  end

  defp checks(rc, cfg, boot_entry) do
    runner = Fire.runner(system_prompt: rc.system_prompt, agent_opts: rc.agent_opts)
    prompt = Keyword.get(cfg, :prompt, @default_prompt)
    timeout = Keyword.get(cfg, :timeout_ms, @default_timeout)

    with {:ok, prompt_entry} <- turn(runner, %{prompt: prompt, skills: []}, :prompt, timeout),
         {:ok, task_entries, task_checks} <- task_dry_run(runner, rc, timeout) do
      checks = [{:boot, :ok}, {:prompt, :ok}] ++ task_checks
      transcript = cap(Enum.join([boot_entry, prompt_entry | task_entries]))
      {:ok, %{checks: checks, transcript: transcript}}
    end
  end

  # The task-dry-run check fires the first scheduled task's real prompt through
  # the same runner, proving a scheduled task fires under the persona. Skipped
  # for a package with no tasks (there is nothing to dry-run).
  defp task_dry_run(_runner, %{scheduler_jobs: []}, _timeout), do: {:ok, [], []}

  defp task_dry_run(runner, %{scheduler_jobs: [job | _]}, timeout) do
    case turn(runner, %{prompt: job.prompt, skills: job.skills}, :task_dry_run, timeout) do
      {:ok, entry} -> {:ok, [entry], [{:task_dry_run, :ok}]}
      {:error, _} = err -> err
    end
  end

  # -- turn -------------------------------------------------------------------

  # Run one fresh, history-free fire under a timeout. `Fire.run/2` returns
  # `{:ok, content}` or `{:error, reason}`; a crash or timeout is its own typed
  # failure so a runaway turn cannot hang the bench (and thus the job session).
  defp turn(runner, job, check, timeout) do
    task = Task.async(fn -> runner.(job) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, output}} -> {:ok, section(check, output)}
      {:ok, {:error, reason}} -> {:error, {:bench_failed, check, reason}}
      {:exit, reason} -> {:error, {:bench_failed, check, {:crashed, reason}}}
      nil -> {:error, {:bench_timeout, check}}
    end
  end

  # -- transcript -------------------------------------------------------------

  defp boot_section(report) do
    jobs = report.jobs

    "== boot ==\n" <>
      "jobs: created=#{inspect(jobs.created)} updated=#{inspect(jobs.updated)} " <>
      "removed=#{inspect(jobs.removed)}\n" <>
      "mcp tools: #{report.mcp.tools}, channels: #{inspect(report.channels)}\n"
  end

  defp section(check, output), do: "== #{check} ==\n#{output}\n"

  defp cap(bin) when byte_size(bin) > @cap,
    do: binary_part(bin, byte_size(bin) - @cap, @cap)

  defp cap(bin), do: bin

  # -- teardown ---------------------------------------------------------------

  defp stop(sup) do
    Supervisor.stop(sup)
  catch
    :exit, _ -> :ok
  end
end
