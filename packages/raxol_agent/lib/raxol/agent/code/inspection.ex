defmodule Raxol.Agent.Code.Inspection do
  @moduledoc """
  One snapshot of every config source the coding agent will use in a
  directory: provider resolution (and why), the `.raxol/config.json` repo
  pin, `.raxol/hooks.json` rules, `.mcp.json` servers, skills roots, and the
  session store.

  `gather/2` assembles the snapshot as a plain JSON-encodable map; `render/1`
  formats it for humans. Both `mix raxol.inspect` and the TUI's `/inspect`
  read the same snapshot, so the two surfaces cannot disagree.

  Security: `.mcp.json` server `env` blocks may carry tokens, so the snapshot
  records env *names* only, never values.
  """

  alias Raxol.Agent.Backend.Resolver
  alias Raxol.Agent.Code.Hooks
  alias Raxol.Agent.Code.McpConfig
  alias Raxol.Agent.Code.ProjectConfig
  alias Raxol.Agent.Code.Store
  alias Raxol.Agent.Skills

  @type snapshot :: map()

  @doc """
  Assemble the snapshot for `cwd`.

  Options: `:sessions_dir` overrides the session-store directory (the TUI
  passes its own). Provider probing may shell out to `op` for stored
  references, so treat the result as a point-in-time snapshot.
  """
  @spec gather(String.t(), keyword()) :: snapshot()
  def gather(cwd, opts \\ []) do
    %{
      cwd: cwd,
      provider: provider_section(),
      project: ProjectConfig.load(cwd),
      hooks: hooks_section(cwd),
      mcp_servers: mcp_section(cwd),
      lsp: lsp_section(cwd),
      skills: skills_section(),
      sessions: sessions_section(Keyword.get(opts, :sessions_dir) || Store.default_dir())
    }
  end

  @doc "Format a snapshot for humans (the mix task and `/inspect`)."
  @spec render(snapshot()) :: String.t()
  def render(snapshot) do
    [
      "inspecting: #{snapshot.cwd}",
      "",
      render_providers(snapshot.provider),
      render_project(snapshot.project),
      render_hooks(snapshot.hooks),
      render_mcp(snapshot.mcp_servers),
      render_lsp(snapshot.lsp),
      render_skills(snapshot.skills),
      render_sessions(snapshot.sessions)
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  # -- gather sections --------------------------------------------------------

  defp provider_section do
    diag = Resolver.diagnostics()

    %{
      op: diag.op,
      providers:
        Enum.map(diag.providers, fn p ->
          %{
            harness: p.harness,
            label: p.label,
            keyless: p.keyless?,
            available: p.available?,
            source: p.source,
            note: p.note
          }
        end)
    }
  end

  defp hooks_section(cwd) do
    case Hooks.load(cwd) do
      :none ->
        %{status: :none, pre: [], post: [], stop: []}

      {:ok, config} ->
        %{status: :ok, pre: config.pre, post: config.post, stop: config.stop}

      {:error, reason} ->
        %{status: :error, error: inspect(reason), pre: [], post: [], stop: []}
    end
  end

  defp mcp_section(cwd) do
    case McpConfig.load(cwd) do
      :none ->
        %{status: :none, servers: []}

      {:ok, servers} ->
        %{status: :ok, servers: Enum.map(servers, &redact_server/1)}

      {:error, reason} ->
        %{status: :error, error: inspect(reason), servers: []}
    end
  end

  # Env NAMES only: `.mcp.json` env values may hold tokens.
  defp redact_server(server) do
    %{
      name: server.name,
      command: server.command,
      args: server.args,
      env_keys: server |> Map.get(:env, %{}) |> Map.keys() |> Enum.sort()
    }
  end

  # Which servers WOULD serve this directory, and whether their command is
  # installed. Nothing is started to find out.
  defp lsp_section(cwd) do
    cwd
    |> Raxol.Agent.Lsp.Config.load()
    |> Enum.map(fn server ->
      %{
        name: server.name,
        command: server.command,
        extensions: server.extensions,
        installed: Raxol.Agent.Lsp.Config.available?(server)
      }
    end)
  end

  defp skills_section do
    provider = Skills.default_provider()
    root = expand(config(:skills_root) || "~/.raxol/skills")
    external = Enum.map(config(:skills_external_dirs) || ["~/.agents/skills"], &expand/1)

    %{
      provider: provider && inspect(provider),
      root: skill_root_entry(root),
      external: Enum.map(external, &skill_root_entry/1)
    }
  end

  defp skill_root_entry(dir) do
    %{
      dir: dir,
      exists: File.dir?(dir),
      skills: length(Path.wildcard(Path.join(dir, "*/SKILL.md")))
    }
  end

  defp sessions_section(dir) do
    sessions = Store.list(dir)

    %{
      dir: dir,
      count: length(sessions),
      latest: Store.latest(dir)
    }
  end

  defp config(key), do: Application.get_env(:raxol_agent, key)

  defp expand(path), do: Path.expand(path)

  # -- render sections --------------------------------------------------------

  defp render_providers(%{op: op, providers: providers}) do
    rows =
      Enum.map(providers, fn p ->
        mark = if p.available, do: "●", else: "○"
        via = if p.source, do: "  via #{p.source}", else: ""
        note = if p.note, do: "  (#{p.note})", else: ""
        "  #{mark} #{pad(to_string(p.harness), 12)} #{p.label}#{via}#{note}"
      end)

    ["providers (op CLI: #{op}):" | rows]
  end

  defp render_project(project) when map_size(project) == 0,
    do: "project pin (.raxol/config.json): none"

  defp render_project(project) do
    pin =
      [:provider, :model, :base_url]
      |> Enum.flat_map(fn key ->
        case Map.get(project, key) do
          nil -> []
          value -> ["#{key}=#{value}"]
        end
      end)
      |> Enum.join(" ")

    "project pin (.raxol/config.json): #{pin}"
  end

  defp render_lsp([]), do: "lsp (.raxol/lsp.json): none configured"

  defp render_lsp(servers) do
    lines =
      Enum.map(servers, fn server ->
        mark = if server.installed, do: "installed", else: "NOT installed"

        "  #{server.name}  #{server.command} (#{mark})  " <>
          Enum.join(server.extensions, " ")
      end)

    installed = Enum.count(servers, & &1.installed)
    ["lsp: #{installed}/#{length(servers)} servers installed" | lines]
  end

  defp render_hooks(%{status: :none}), do: "hooks (.raxol/hooks.json): none"

  defp render_hooks(%{status: :error, error: error}),
    do: "hooks (.raxol/hooks.json): ERROR #{error}"

  defp render_hooks(%{pre: pre, post: post, stop: stop}) do
    rules =
      Enum.map(pre, &"  pre   #{&1.match} → #{&1.command}") ++
        Enum.map(post, &"  post  #{&1.match} → #{&1.command}") ++
        Enum.map(stop, &"  stop  #{&1}")

    ["hooks (.raxol/hooks.json):" | rules]
  end

  defp render_mcp(%{status: :none}), do: "mcp servers (.mcp.json): none"

  defp render_mcp(%{status: :error, error: error}),
    do: "mcp servers (.mcp.json): ERROR #{error}"

  defp render_mcp(%{servers: []}), do: "mcp servers (.mcp.json): none declared"

  defp render_mcp(%{servers: servers}) do
    rows =
      Enum.map(servers, fn s ->
        env =
          case s.env_keys do
            [] -> ""
            keys -> "  (env: #{Enum.join(keys, ", ")})"
          end

        "  #{s.name} → #{Enum.join([s.command | s.args], " ")}#{env}"
      end)

    ["mcp servers (.mcp.json):" | rows]
  end

  defp render_skills(%{provider: nil}),
    do: "skills: disabled (no :skills_provider configured)"

  defp render_skills(%{provider: provider, root: root, external: external}) do
    rows =
      [
        "  managed  #{skill_root_text(root)}"
        | Enum.map(external, &"  external #{skill_root_text(&1)} (read-only)")
      ]

    ["skills: provider=#{provider}" | rows]
  end

  defp skill_root_text(%{dir: dir, exists: false}), do: "#{dir} (missing)"

  defp skill_root_text(%{dir: dir, skills: n}),
    do: "#{dir} (#{n} #{plural(n, "skill")})"

  defp render_sessions(%{dir: dir, count: 0}), do: "sessions: #{dir} (none saved)"

  defp render_sessions(%{dir: dir, count: count, latest: latest}) do
    "sessions: #{dir} (#{count} saved, latest #{latest})"
  end

  defp pad(string, width), do: String.pad_trailing(string, width)

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
