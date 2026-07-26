defmodule Raxol.ACP.Console.Bench.Local do
  @moduledoc """
  Runs bench checks by executing an operator-configured wrapper around the
  open-source runtime, once per check, over a `Port`:

      config :raxol_acp, :console_bench,
        hermes: [cmd: {"/opt/raxol/bench/hermes.sh", []}],
        openclaw: [cmd: {"/opt/raxol/bench/openclaw.sh", []}],
        timeout_ms: 120_000,
        prompt: "Introduce yourself in one sentence and state your purpose."

  Wrapper contract (kept runtime-agnostic on purpose — the runtimes are moving
  targets and the glue is a few lines of shell): the wrapper is invoked with
  env `RAXOL_BENCH_CHECK` (`boot` | `prompt` | `task_dry_run`),
  `RAXOL_BENCH_PKG_DIR` (the materialized package), `RAXOL_BENCH_PROMPT`
  (prompt check), and `RAXOL_BENCH_TASK` (a task name, dry-run check). It must
  boot the runtime against the package, perform the check, print the agent's
  observable output to stdout, and exit 0 on success / non-zero on failure.
  Like the signer sidecar, the wrapper must treat stdin close as shutdown —
  that is how a timed-out or crashed BEAM reaps it.

  Failure surfaces as `{:error, {:bench_failed, check, exit_status, tail}}` or
  `{:error, {:bench_timeout, check}}`; either blocks delivery. Transcripts are
  concatenated across checks and capped at 64 KiB.
  """

  @behaviour Raxol.ACP.Console.Bench

  @cap 64 * 1024

  @impl true
  def run(pkg_dir, spec) do
    cfg = Application.get_env(:raxol_acp, :console_bench, [])
    runtime = package_runtime(pkg_dir)

    case get_in(cfg, [runtime, :cmd]) do
      {exe, args} when is_binary(exe) ->
        checks =
          [:boot, :prompt] ++
            if(spec.scheduled_tasks == [], do: [], else: [:task_dry_run])

        run_checks(checks, exe, args, pkg_dir, cfg, [], "")

      _ ->
        {:error, {:bench_unconfigured, runtime}}
    end
  end

  # The manifest is the single source of truth for which runtime the generator
  # targeted (`:either` resolution happens there); bench that runtime.
  defp package_runtime(pkg_dir) do
    with {:ok, raw} <- File.read(Path.join(pkg_dir, "manifest.json")),
         {:ok, %{"runtime" => "openclaw"}} <- Jason.decode(raw) do
      :openclaw
    else
      _ -> :hermes
    end
  end

  defp run_checks([], _exe, _args, _dir, _cfg, done, transcript),
    do: {:ok, %{checks: Enum.reverse(done), transcript: transcript}}

  defp run_checks([check | rest], exe, args, pkg_dir, cfg, done, transcript) do
    env = [
      {~c"RAXOL_BENCH_CHECK", to_charlist(check)},
      {~c"RAXOL_BENCH_PKG_DIR", to_charlist(pkg_dir)},
      {~c"RAXOL_BENCH_PROMPT",
       to_charlist(Keyword.get(cfg, :prompt, "Introduce yourself in one sentence."))},
      {~c"RAXOL_BENCH_TASK", to_charlist(first_task(pkg_dir))}
    ]

    case open_port(exe, args, env) do
      {:error, reason} ->
        # A missing/non-executable wrapper is an operator misconfig; fail the
        # bench with a typed error rather than crashing the job session.
        {:error, {:bench_spawn_failed, check, reason}}

      {:ok, port} ->
        timeout = Keyword.get(cfg, :timeout_ms, 120_000)

        case collect(port, "", timeout) do
          {:ok, 0, out} ->
            entry = "== #{check} ==\n#{out}\n"

            run_checks(
              rest,
              exe,
              args,
              pkg_dir,
              cfg,
              [{check, :ok} | done],
              cap(transcript <> entry)
            )

          {:ok, status, out} ->
            {:error, {:bench_failed, check, status, String.slice(out, -500..-1//1)}}

          :timeout ->
            Port.close(port)
            {:error, {:bench_timeout, check}}
        end
    end
  end

  # Port.open/2 raises (e.g. :enoent) when the wrapper is missing or not
  # executable; contain that so the pipeline sees a normal error.
  defp open_port(exe, args, env) do
    port =
      Port.open({:spawn_executable, exe}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: env
      ])

    {:ok, port}
  rescue
    # `rescue` catches the `:error`-class raise from open_port (e.g. :enoent for
    # a missing wrapper) as an ErlangError, so no separate `catch` is needed.
    e -> {:error, Exception.message(e)}
  end

  defp collect(port, acc, timeout) do
    receive do
      {^port, {:data, data}} -> collect(port, cap(acc <> data), timeout)
      {^port, {:exit_status, status}} -> {:ok, status, acc}
    after
      timeout -> :timeout
    end
  end

  defp cap(bin) when byte_size(bin) > @cap,
    do: binary_part(bin, byte_size(bin) - @cap, @cap)

  defp cap(bin), do: bin

  defp first_task(pkg_dir) do
    with {:ok, raw} <- File.read(Path.join(pkg_dir, "tasks.json")),
         {:ok, %{"tasks" => [%{"name" => name} | _]}} <- Jason.decode(raw) do
      name
    else
      _ -> ""
    end
  end
end
