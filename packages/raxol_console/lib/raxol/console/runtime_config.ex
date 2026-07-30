defmodule Raxol.Console.RuntimeConfig do
  @moduledoc """
  Pure mapping from a parsed Console package (`Raxol.ACP.Console.Package`) plus
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

  alias Raxol.ACP.Console.Package
  alias Raxol.Agent.McpBundle

  @type scheduler_job :: %{
          id: String.t(),
          prompt: String.t(),
          schedule: String.t(),
          skills: [String.t()],
          target: String.t() | nil,
          enabled: boolean()
        }

  defstruct system_prompt: nil,
            persona_sha256: nil,
            scheduler_jobs: [],
            skills: [],
            agent_opts: [],
            channels: [],
            mcp_servers: []

  @type t :: %__MODULE__{
          system_prompt: String.t(),
          persona_sha256: String.t(),
          scheduler_jobs: [scheduler_job()],
          skills: [%{name: String.t(), skill_md: String.t()}],
          agent_opts: keyword(),
          channels: [term()],
          mcp_servers: [McpBundle.server_spec()]
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
  """
  @spec build(Package.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(%Package{} = pkg, opts \\ []) do
    with {:ok, persona} <- persona(pkg) do
      {:ok,
       %__MODULE__{
         system_prompt: persona,
         persona_sha256: sha256(persona),
         scheduler_jobs: scheduler_jobs(pkg, opts),
         skills: pkg.skills,
         agent_opts: Keyword.get(opts, :agent_opts, []),
         channels: Keyword.get(opts, :channels, []),
         mcp_servers: mcp_servers(opts)
       }}
    end
  end

  def build(other, _opts), do: {:error, {:not_a_package, other}}

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
