defmodule Raxol.Console.Application do
  @moduledoc """
  Container entrypoint for a Raxol Console runtime.

  Started as the OTP application callback (`mod:`) outside `:test`. It reads the
  materialized agent package plus the deployment environment, builds a
  `Raxol.Console.RuntimeConfig`, and boots the runtime via `Raxol.Console.Boot`.
  When nothing is configured (a dev shell, or a container that has not yet been
  handed a package) it starts an empty supervisor and stays up as a no-op, so
  pulling `raxol_console` in as a dependency never self-boots a runtime.

  ## Configuration

  The package is a directory of the generator's output (`soul.md`, `AGENTS.md`,
  `tasks.json`, `skills/`, `manifest.json`), located by `:package_dir` or the
  `RAXOL_CONSOLE_PACKAGE` env var (the value a container most likely injects):

      config :raxol_console,
        package_dir: "/srv/agent",
        channels: [%{platform: :telegram, adapter: MyAdapter, config: %{...}}],
        agent_opts: [backend: MyBackend, backend_opts: [...]],
        default_target: "telegram:home",
        workspace: "/srv/agent/workspace",
        bundle_default_mcp: true

  A chat turn runs the stateless agent loop by default. To run a full TEA app per
  chat instead, name a template registered in `Raxol.Console.AppRegistry`:

      config :raxol_console, :app_templates, %{"dashboard" => MyConsole.Dashboard}

      config :raxol_console,
        handler_mode: :app,
        app_template: "dashboard",
        idle_timeout: :timer.hours(6),
        max_sessions: 200

  A per-chat app holds its model in memory, and the session's idle timeout
  discards it; `:idle_timeout` is how long a deployment's app is worth keeping
  warm. A running app is several processes rather than a message list, so a long
  idle timeout wants a `:max_sessions` chosen for it -- see
  `Raxol.Console.RuntimeConfig.build/2` for how the two multiply. All of these
  keys are deployment-owned; the package never selects the module that runs per
  chat.

  The package carries persona + behavior; the deployment supplies the rest. The
  three deployment-owned inputs the Console injects -- credentials (agent wallet,
  email, card, channel bot tokens), messaging channels, and inference -- arrive
  through `:agent_opts`, the `:channels` adapter configs, and the payments
  config, not through this module directly. Their exact injection contract
  (env var names, mount points, ports, health/log conventions) is the one
  undocumented Console-integration seam (ADR-0031, open); confirming it maps to
  setting these keys, not to a rewrite here. Health-endpoint and port wiring is
  deferred with it (`raxol_console` bundles no web server).

  A configured-but-invalid package fails the boot loudly (`{:error, reason}`),
  which is the correct container behavior: the orchestrator restarts and surfaces
  it rather than running a half-booted agent.
  """

  use Application
  require Logger

  alias Raxol.Earn.Console.Package
  alias Raxol.Console.{Boot, RuntimeConfig}

  # Every deployment option `RuntimeConfig.build/2` understands. Both takes below
  # filter through this list, so a key missing here is silently dropped on the
  # way in and its feature is unreachable from application config.
  @rc_keys [
    :channels,
    :agent_opts,
    :default_target,
    :workspace,
    :bundle_default_mcp,
    :handler_mode,
    :app_template,
    :idle_timeout,
    :max_sessions,
    :pairing
  ]

  @impl true
  def start(_type, _args) do
    case plan(Application.get_all_env(:raxol_console)) do
      :none ->
        empty_supervisor()

      {:ok, dir, opts} ->
        dir |> boot(opts) |> to_app_result()
    end
  end

  @doc false
  # Pure: decide whether a runtime is configured and assemble its boot options.
  # `:none` when no package is located; `{:ok, dir, opts}` otherwise.
  @spec plan(keyword()) :: :none | {:ok, Path.t(), keyword()}
  def plan(config) do
    case package_dir(config) do
      nil -> :none
      dir -> {:ok, dir, boot_opts(config)}
    end
  end

  @doc false
  # Load the package, build its runtime config, and boot the tree. Returns the
  # boot report so the caller can log it (and the supervisor pid to own).
  @spec boot(Path.t(), keyword()) :: {:ok, Boot.report()} | {:error, term()}
  def boot(dir, opts) do
    with {:ok, pkg} <- load(dir),
         {:ok, rc} <- build(pkg, opts) do
      boot_opts =
        opts
        |> Keyword.take([:actions])
        |> Keyword.put(:skills_dir, Path.join(dir, "skills"))

      Boot.start(rc, boot_opts)
    end
  end

  # -- planning ---------------------------------------------------------------

  defp package_dir(config) do
    case Keyword.get(config, :package_dir) do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> System.get_env("RAXOL_CONSOLE_PACKAGE")
    end
  end

  defp boot_opts(config) do
    config
    |> Keyword.take([:actions | @rc_keys])
    |> Keyword.put_new(:channels, [])
    |> Keyword.put_new(:agent_opts, [])
  end

  # -- boot stages ------------------------------------------------------------

  defp load(dir) do
    case Package.load(dir) do
      {:ok, pkg} -> {:ok, pkg}
      {:error, reason} -> {:error, {:package_load_failed, reason}}
    end
  end

  defp build(pkg, opts) do
    case RuntimeConfig.build(pkg, Keyword.take(opts, @rc_keys)) do
      {:ok, rc} -> {:ok, rc}
      {:error, reason} -> {:error, {:runtime_config_failed, reason}}
    end
  end

  # -- results ----------------------------------------------------------------

  defp to_app_result({:ok, report}) do
    Logger.info(
      "[Raxol.Console] booted: " <>
        "jobs created=#{length(report.jobs.created)} updated=#{length(report.jobs.updated)} " <>
        "removed=#{length(report.jobs.removed)} failed=#{length(report.jobs.failed)}, " <>
        "mcp tools=#{report.mcp.tools}, skills=#{report.skills.count}, " <>
        "channels=#{inspect(report.channels)}"
    )

    {:ok, report.supervisor}
  end

  defp to_app_result({:error, reason} = error) do
    Logger.error("[Raxol.Console] boot failed: #{inspect(reason)}")
    error
  end

  defp empty_supervisor do
    Supervisor.start_link([],
      strategy: :one_for_one,
      name: Raxol.Console.Application.RootSupervisor
    )
  end
end
