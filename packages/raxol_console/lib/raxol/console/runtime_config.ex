defmodule Raxol.Console.RuntimeConfig do
  @moduledoc """
  Pure mapping from a parsed Console package (`Raxol.Earn.Console.Package`) plus
  deployment options into the config `Raxol.Console.Boot` starts a runtime from.

  The package carries persona + behavior (soul.md, AGENTS.md, tasks.json,
  skills); the deployment supplies credentials, channels, and inference (the
  Console injects these). This module merges them. It performs no I/O and starts
  nothing.

  Key mappings:

    * `soul.md` (+ `AGENTS.md` under an operating-rules heading) -> a single
      `:system_prompt` binary applied to every turn (both `Handler.Agent` and
      `Stream.run` take one binary), with an sha256 identity for a debug card.
    * each `tasks.json` task -> a `Raxol.Agent.Scheduler.create/2` attr map,
      keyed by task name (the stable job id, so reboots reconcile rather than
      duplicate).
    * `skills/` -> carried through for the skills store.
    * default MCP servers (`Raxol.Agent.McpBundle.default_servers/1`) -> specs
      the boot bundles as dynamic tools, unless disabled.
  """

  alias Raxol.Earn.Console.Package
  alias Raxol.Agent.McpBundle
  alias Raxol.Console.AppRegistry

  @type scheduler_job :: %{
          id: String.t(),
          prompt: String.t(),
          schedule: String.t(),
          skills: [String.t()],
          target: String.t() | nil,
          enabled: boolean()
        }

  @typedoc """
  Which gateway handler a chat turn runs.

    * `:chat` -- one `Raxol.Agent.Stream.run/2` per turn, persona applied
      automatically. The default, and what every current Console template needs.
    * `:app` -- a full TEA app per chat under `environment: :gateway`, so the
      model persists across turns.
  """
  @type handler_mode :: :chat | :app

  defstruct system_prompt: nil,
            persona_sha256: nil,
            scheduler_jobs: [],
            skills: [],
            agent_opts: [],
            channels: [],
            mcp_servers: [],
            handler_mode: :chat,
            app_module: nil

  @type t :: %__MODULE__{
          system_prompt: String.t(),
          persona_sha256: String.t(),
          scheduler_jobs: [scheduler_job()],
          skills: [%{name: String.t(), skill_md: String.t()}],
          agent_opts: keyword(),
          channels: [term()],
          mcp_servers: [McpBundle.server_spec()],
          handler_mode: handler_mode(),
          app_module: module() | nil
        }

  @doc """
  Build a `%RuntimeConfig{}` from a package and deployment options.

  Options:

    * `:agent_opts` -- forwarded to the agent turn (`:executor`/`:backend`/...).
    * `:channels` -- gateway channel specs (deployment-supplied).
    * `:default_target` -- default `"platform:chat_id"` scheduled tasks deliver to.
    * `:mcp_servers` -- override the bundled MCP server specs.
    * `:bundle_default_mcp` -- default `true`; bundle the standard server set.
    * `:workspace` -- scopes the bundled filesystem server (default `"."`).
    * `:handler_mode` -- `:chat` (default) or `:app`; see `t:handler_mode/0`.
    * `:app_template` -- required in `:app` mode; a name resolved against
      `Raxol.Console.AppRegistry`.

  `:handler_mode` and `:app_template` are read from the DEPLOYMENT options, never
  from the package. The package is untrusted input, and choosing which module
  runs per chat is not a decision it gets to make.
  """
  @spec build(Package.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(package, opts \\ [])

  def build(%Package{} = pkg, opts) do
    with {:ok, persona} <- persona(pkg),
         {:ok, mode, app_module} <- handler(opts) do
      {:ok,
       %__MODULE__{
         system_prompt: persona,
         persona_sha256: sha256(persona),
         scheduler_jobs: scheduler_jobs(pkg, opts),
         skills: pkg.skills,
         agent_opts: Keyword.get(opts, :agent_opts, []),
         channels: Keyword.get(opts, :channels, []),
         mcp_servers: mcp_servers(opts),
         handler_mode: mode,
         app_module: app_module
       }}
    end
  end

  def build(other, _opts), do: {:error, {:not_a_package, other}}

  @doc """
  The `Raxol.Gateway` handler spec this runtime boots.

  `:chat` runs the stateless agent loop with the resolved persona applied per
  turn. `:app` runs a per-chat TEA app, and threads the persona through
  `:lifecycle_opts` -- `Raxol.Gateway.Handler.Lifecycle` appends those to
  `Raxol.Core.Runtime.Lifecycle.start_link/2`, which hands them to the app as
  `init(%{options: opts})`. That is the only seam a TEA app has for the persona:
  unlike the chat loop it weaves the system prompt into its own model and backend
  calls rather than getting it applied for free.
  """
  @spec handler_spec(t(), keyword()) :: {module(), keyword()}
  def handler_spec(%__MODULE__{handler_mode: :app} = rc, _agent_opts) do
    {Raxol.Gateway.Handler.Lifecycle,
     [app_module: rc.app_module, lifecycle_opts: [system_prompt: rc.system_prompt]]}
  end

  def handler_spec(%__MODULE__{} = rc, agent_opts) do
    {Raxol.Gateway.Handler.Agent, [system_prompt: rc.system_prompt, agent_opts: agent_opts]}
  end

  # -- handler mode ----------------------------------------------------------

  defp handler(opts) do
    case Keyword.get(opts, :handler_mode, :chat) do
      :chat -> {:ok, :chat, nil}
      :app -> resolve_app(Keyword.get(opts, :app_template))
      other -> {:error, {:unknown_handler_mode, other}}
    end
  end

  defp resolve_app(nil), do: {:error, :missing_app_template}

  defp resolve_app(name) do
    with {:ok, module} <- AppRegistry.fetch(name), do: {:ok, :app, module}
  end

  # -- persona ---------------------------------------------------------------

  defp persona(%Package{soul_md: soul} = pkg) when is_binary(soul) and soul != "" do
    base = String.trim_trailing(soul)

    text =
      case pkg.agents_md do
        agents when is_binary(agents) and agents != "" ->
          base <> "\n\n## Operating rules\n\n" <> String.trim(agents)

        _ ->
          base
      end

    {:ok, text}
  end

  defp persona(_pkg), do: {:error, :missing_soul}

  # -- scheduler jobs --------------------------------------------------------

  defp scheduler_jobs(%Package{tasks: tasks}, opts) do
    target = Keyword.get(opts, :default_target)

    Enum.map(tasks, fn task ->
      %{
        id: task.name,
        prompt: task.prompt,
        schedule: task.cron,
        skills: [],
        target: target,
        enabled: true
      }
    end)
  end

  # -- mcp servers -----------------------------------------------------------

  defp mcp_servers(opts) do
    cond do
      servers = Keyword.get(opts, :mcp_servers) ->
        servers

      Keyword.get(opts, :bundle_default_mcp, true) ->
        McpBundle.default_servers(workspace: Keyword.get(opts, :workspace, "."))

      true ->
        []
    end
  end

  defp sha256(text), do: :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
end
