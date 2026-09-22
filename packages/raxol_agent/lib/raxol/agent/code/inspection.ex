defmodule Raxol.Agent.Code.Inspection do
  @moduledoc """
  One snapshot of every config source the coding agent will use in a
  directory: provider resolution (and why), the `.raxol/config.json` repo
  pin, the `AGENTS.md`/`CLAUDE.md` instruction files that reach the system
  prompt, `.raxol/hooks.json` rules, `.mcp.json` servers, skills roots, and
  the session store.

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
  alias Raxol.Agent.Code.ProjectContext
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
      instructions: instructions_section(cwd),
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
      render_instructions(snapshot.instructions),
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

  # Skipped entries (an `http`/`sse` entry naming no url, a broken entry) are
  # part of the snapshot: the file names them, so the inspection must too.
  defp mcp_section(cwd) do
    case McpConfig.load_all(cwd) do
      :none ->
        %{status: :none, servers: [], skipped: []}

      {:ok, servers, skipped} ->
        %{
          status: :ok,
          servers: Enum.map(servers, &redact_server/1),
          skipped:
            Enum.map(skipped, fn {name, reason} ->
              %{name: one_line(name), reason: reason}
            end)
        }

      {:error, reason} ->
        %{status: :error, error: inspect(reason), servers: [], skipped: []}
    end
  end

  # NAMES only, never values: `.mcp.json` env values and header values may
  # hold tokens, and this output is meant to be read and pasted.
  #
  # A url was the hole in that: it was copied out verbatim, and a url is the
  # commonest place an MCP credential lives -- `https://user:token@host/mcp`
  # and `?api_key=sk-...` are both ordinary MCP configuration. It is now cut
  # down to what identifies the server, by `endpoint/1`.
  #
  # The name is workspace content too, and nothing has checked its charset at
  # this point (the loader's check applies to servers it ADMITS, which is a
  # later and narrower set). A `\n` in it forged a whole extra row in the
  # rendered snapshot, so newlines become spaces here.
  defp redact_server(server) do
    %{
      name: one_line(server.name),
      source: Map.get(server, :source, :workspace),
      command: Map.get(server, :command),
      args: Map.get(server, :args, []),
      env_keys: server |> Map.get(:env, %{}) |> Map.keys() |> Enum.sort(),
      url: endpoint(Map.get(server, :url)),
      header_names: server |> Map.get(:headers, []) |> Enum.map(&elem(&1, 0)),
      metered: Map.get(server, :metered, false)
    }
  end

  defp one_line(name) when is_binary(name), do: String.replace(name, ~r/[\r\n]+/, " ")
  defp one_line(name), do: name

  # Scheme, host, port and path: enough for an operator to recognize which
  # server this is, with userinfo and the query string dropped rather than
  # masked, so there is nothing left to un-mask.
  defp endpoint(nil), do: nil

  defp endpoint(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: uri.port, path: uri.path})

      _unusable ->
        "(unparseable url)"
    end
  end

  defp endpoint(_other), do: nil

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

  # Content is deliberately dropped: the snapshot names which files reach
  # the system prompt and how big they are, not what they say.
  defp instructions_section(cwd) do
    %{files: files, bytes: bytes} = ProjectContext.load(cwd)

    %{
      files: Enum.map(files, &Map.take(&1, [:path, :bytes, :truncated?])),
      bytes: bytes
    }
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

  defp render_instructions(%{files: []}),
    do: "instructions (#{Enum.join(ProjectContext.filenames(), ", ")}): none"

  defp render_instructions(%{files: files, bytes: bytes}) do
    lines =
      Enum.map(files, fn file ->
        mark = if file.truncated?, do: " (truncated)", else: ""
        "  #{file.path}  #{file.bytes}B#{mark}"
      end)

    ["instructions: #{length(files)} file(s), #{bytes}B" | lines]
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

  defp render_mcp(%{servers: [], skipped: []}),
    do: "mcp servers (.mcp.json): none declared"

  defp render_mcp(%{servers: servers, skipped: skipped}) do
    rows =
      Enum.map(servers, fn s ->
        env =
          case s.env_keys do
            [] -> ""
            keys -> "  (env: #{Enum.join(keys, ", ")})"
          end

        "  #{s.name} → #{server_target(s)}#{env}"
      end)

    skipped_rows =
      Enum.map(skipped, fn s -> "  #{s.name} → skipped (#{skip_reason_text(s.reason)})" end)

    ["mcp servers (.mcp.json):" | rows ++ skipped_rows]
  end

  # A remote server carries no command, so joining `[s.command | s.args]`
  # raised on it. Naming what the entry declares is what makes this snapshot
  # usable for "why did that server not start".
  defp server_target(%{command: command} = server) when is_binary(command),
    do: Enum.join([command | server.args], " ")

  defp server_target(%{url: url}) when is_binary(url), do: url
  defp server_target(_server), do: "(no command or url)"

  defp skip_reason_text(:unsupported_transport), do: "type is http/sse but no url"
  defp skip_reason_text(:no_command), do: "neither a command nor a url"
  defp skip_reason_text(:command_not_string), do: "command not a string"
  defp skip_reason_text(:not_an_object), do: "not an object"

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

  # No home directory and no override: `Store.default_dir/0` refuses to guess
  # a world-writable one, and an operator reading /inspect should see why
  # rather than an empty path.
  defp render_sessions(%{dir: nil}),
    do: "sessions: none (no home directory; set $RAXOL_CODE_SESSIONS)"

  defp render_sessions(%{dir: dir, count: 0}), do: "sessions: #{dir} (none saved)"

  defp render_sessions(%{dir: dir, count: count, latest: latest}) do
    "sessions: #{dir} (#{count} saved, latest #{latest})"
  end

  defp pad(string, width), do: String.pad_trailing(string, width)

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
