defmodule RaxolPlayground.Capabilities do
  @moduledoc """
  Single source of truth for raxol.io's machine-readable agent surface.

  Surfaces, published packages, agent backends, and MCP tools live here once.
  The capability endpoints (`/.well-known/raxol.json`, `/api/capabilities`,
  `/llms.txt`) and the landing page stats all derive from this module, so the
  same facts are never restated in two places.

  Backends are read from the agent's own provider registry rather than restated:
  `web/mix.exs` takes `raxol_agent` as a path dep, so `Backend.Resolver` is on
  the code path here and the list cannot drift from what the agent resolves.
  """

  alias Raxol.Agent.Backend.Resolver

  @surfaces [
    %{name: "terminal", transport: "termbox2 NIF", dep: "raxol_terminal"},
    %{name: "liveview", transport: "Phoenix PubSub", dep: "raxol_liveview"},
    %{name: "ssh", transport: "Erlang :ssh", dep: "raxol (built-in)"},
    %{name: "mcp", transport: "stdio JSON-RPC", dep: "raxol_mcp"},
    %{name: "telegram", transport: "Telegex HTTP", dep: "raxol_telegram"},
    %{name: "watch", transport: "APNS/FCM push", dep: "raxol_watch"},
    %{name: "speech", transport: "TTS/STT (say/Whisper)", dep: "raxol_speech"}
  ]

  # ---------------------------------------------------------------------------
  # Versions and package counts are READ, never typed.
  #
  # They used to be written out here by hand, and had drifted: raxol_speech,
  # raxol_telegram and raxol_watch were all published at 0.2 while this list
  # still said 0.1, and `version/0`'s fallback said 2.6.0 against a repo on
  # 2.6.1. A number a reader can check against the repo has to come from the
  # repo.
  #
  # Compile time, not runtime: every mix.exs is an @external_resource, so a
  # version bump recompiles this module, and a deployed release never touches
  # the filesystem or the network to answer.
  # ---------------------------------------------------------------------------

  @repo_root Path.expand("../../..", __DIR__)
  @packages_dir Path.join(@repo_root, "packages")
  @root_mix Path.join(@repo_root, "mix.exs")

  # A directory with a mix.exs is a package; anything else in there is not.
  @repo_packages @packages_dir
                 |> File.ls!()
                 |> Enum.sort()
                 |> Enum.map(&{&1, Path.join([@packages_dir, &1, "mix.exs"])})
                 |> Enum.filter(fn {_name, mix} -> File.exists?(mix) end)
                 |> Enum.map(fn {name, mix} ->
                   case Regex.run(~r/@version\s+"([^"]+)"/, File.read!(mix)) do
                     [_, version] -> %{name: name, version: version}
                     nil -> raise "#{mix} has no @version for Capabilities to read"
                   end
                 end)

  for %{name: name} <- @repo_packages do
    @external_resource Path.join([@packages_dir, name, "mix.exs"])
  end

  @external_resource @root_mix

  @source_version (case Regex.run(~r/@version\s+"([^"]+)"/, File.read!(@root_mix)) do
                     [_, version] -> version
                     nil -> raise "#{@root_mix} has no @version for Capabilities to read"
                   end)

  # `raxol` is the root project rather than one of `packages/`, so it joins the
  # lookup from there.
  @versions @repo_packages
            |> Map.new(&{&1.name, &1.version})
            |> Map.put("raxol", @source_version)

  # Which packages are ON HEX, and what each is for. This part IS a judgment
  # call and stays written down: `packages/` also holds pre-alpha work nobody
  # can `mix deps.get` yet, and the capability endpoints exist to tell an agent
  # what it can actually depend on. Only the versions are derived.
  @published [
    {"raxol", "Full framework"},
    {"raxol_agent", "AI agents"},
    {"raxol_mcp", "MCP server"},
    {"raxol_payments", "Agent commerce"},
    {"raxol_liveview", "LiveView bridge"},
    {"raxol_sensor", "Sensor fusion"},
    {"raxol_terminal", "Terminal emulation"},
    {"raxol_core", "Behaviours, events"},
    {"raxol_plugin", "Plugin SDK"},
    {"raxol_speech", "TTS/STT"},
    {"raxol_telegram", "Telegram bot"},
    {"raxol_watch", "Push notifications"}
  ]

  @packages Enum.map(@published, fn {name, purpose} ->
              version =
                Map.get_lazy(@versions, name, fn ->
                  raise "#{name} is listed as published but has no mix.exs in the repo"
                end)

              minor = version |> String.split(".") |> Enum.take(2) |> Enum.join(".")

              %{name: name, version: "~> " <> minor, purpose: purpose}
            end)

  # The provider registry the agent actually resolves against, in its own
  # resolution order. `Resolver.providers/0` is pure and reads no env, so it is
  # safe at compile time -- unlike `status/0` and `diagnostics/0`, which shell
  # out to `op` and can stall for seconds against a locked vault.
  #
  # Labels carry a parenthetical qualifier ("Anthropic (Claude)", "Ollama
  # (local)") that a display list does not want, so the head is taken once here.
  # Inlined rather than factored into a function because a module attribute
  # cannot call a function of the module being defined.
  @providers Enum.map(Resolver.providers(), fn %{harness: harness, label: label} ->
               %{
                 harness: harness,
                 name: label |> String.split(" (") |> hd(),
                 label: label
               }
             end)

  @backends Enum.map(@providers, & &1.name)

  # Mock answers canned text offline. It belongs in the manifest an agent
  # reads, and not in a list of providers a reader could connect to.
  @connectable Enum.reject(@providers, &(&1.harness == :mock))
  @connectable_backends Enum.map(@connectable, & &1.name)
  @connectable_providers Enum.map(@connectable, &Map.take(&1, [:name, :label]))

  # ACP-speaking editors, from the registry raxol is itself listed on:
  # https://agentclientprotocol.com/get-started/clients (checked 2026-08-30).
  # These are third-party clients, so the list cannot be derived from this repo
  # -- `acp_available?/0` is the part that is, and it decides whether any of
  # them is named at all.
  @acp_editors ["Zed", "JetBrains", "neovim", "Emacs", "VS Code"]

  @mcp_tools ~w(
    raxol_start raxol_screenshot raxol_send_key
    raxol_get_model raxol_stop raxol_list
  )

  @doc """
  The `raxol` version this site is running, falling back to the one it was
  built from.

  Both ends are derived: the loaded application's version first, the repo's own
  `mix.exs` when raxol is not started (rendering a component in a test, say).
  The fallback used to be the string "2.6.0", which was already a minor behind
  the repo.

  This tracks the version the site was BUILT from, which is the released one in
  a deploy-on-release setup, and costs no network call per render. It does not
  poll hex.pm: a page that asks an external service what version it is can be
  wrong in a way this cannot, and would be wrong on every render rather than
  until the next deploy.
  """
  @spec version() :: String.t()
  def version do
    case :application.get_key(:raxol, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> @source_version
    end
  end

  @doc "Major.minor of `version/0`, the form the landing page displays."
  @spec version_minor() :: String.t()
  def version_minor do
    version() |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  @doc "Rendering surfaces the same TEA module targets."
  @spec surfaces() :: [map()]
  def surfaces, do: @surfaces

  @spec surface_names() :: [String.t()]
  def surface_names, do: Enum.map(@surfaces, & &1.name)

  @spec surface_count() :: non_neg_integer()
  def surface_count, do: length(@surfaces)

  @doc "Published Hex packages with current version constraints."
  @spec packages() :: [map()]
  def packages, do: @packages

  @spec package_count() :: non_neg_integer()
  def package_count, do: length(@packages)

  @doc """
  Every package in the repo's `packages/` directory, with its real version.

  Wider than `packages/0`, which is the published-to-Hex subset. This is what
  the footer counts, because the footer links to that directory and a count
  that disagreed with what a reader finds on the other side of the link is
  worse than no count.
  """
  @spec repo_packages() :: [%{name: String.t(), version: String.t()}]
  def repo_packages, do: @repo_packages

  @spec repo_package_count() :: non_neg_integer()
  def repo_package_count, do: length(@repo_packages)

  @doc """
  Packages with a ready-to-paste `mix.exs` dep tuple attached, e.g.
  `{:raxol, "~> 2.6"}`. Used by the manifest and capabilities endpoints.
  """
  @spec package_specs() :: [map()]
  def package_specs do
    Enum.map(@packages, &Map.put(&1, :dep, format_dep(&1)))
  end

  @doc """
  The `mix.exs` dep tuple string for one package by name, or `nil` if unknown.
  Lets the landing page cards show a version without restating it.
  """
  @spec dep(String.t()) :: String.t() | nil
  def dep(name) when is_binary(name) do
    Enum.find_value(@packages, fn pkg ->
      pkg.name == name && format_dep(pkg)
    end) || nil
  end

  defp format_dep(%{name: name, version: version}) do
    "{:#{name}, \"#{version}\"}"
  end

  @doc "Agent LLM backends (display names), in the agent's resolution order."
  @spec backends() :: [String.t()]
  def backends, do: @backends

  @doc """
  Backends a reader can actually connect to: `backends/0` without the offline
  Mock harness. This is what the landing page names.
  """
  @spec connectable_backends() :: [String.t()]
  def connectable_backends, do: @connectable_backends

  @doc """
  `connectable_backends/0` with each name paired to the registry's own label.

  The name is the label's head, which is what a dense row can show, but the
  head is also the one part that does not say which of two entries is which:
  `:claude_native` and `:anthropic` both reach Claude and shorten to "Claude"
  and "Anthropic", telling a reader nothing about subscription versus API key.
  Callers that have room, like a hover reveal, should show `:label`.
  """
  @spec connectable_providers() :: [%{name: String.t(), label: String.t()}]
  def connectable_providers, do: @connectable_providers

  @doc """
  Whether raxol's own ACP surface is compiled into this build.

  `Raxol.Agent.ClientProtocol.StdioAgent` is compile-gated on the ACP package
  being present, so a Hex install of `raxol_agent` has no ACP surface at all.
  Same shape as `ssh_available?/0`: a channel is named only while it exists.
  """
  @spec acp_available?() :: boolean()
  def acp_available?,
    do: Code.ensure_loaded?(Raxol.Agent.ClientProtocol.StdioAgent)

  @doc "ACP-speaking editors, or `[]` when this build serves no ACP surface."
  @spec acp_editors() :: [String.t()]
  def acp_editors, do: if(acp_available?(), do: @acp_editors, else: [])

  @doc "Agent framework capabilities exposed to discovery clients."
  @spec agent() :: map()
  def agent do
    %{
      models: ["TEA (message-driven)", "Process (tick-driven)"],
      commands: ["shell", "async", "send_agent"],
      strategies: ["Strategy.Direct", "Strategy.ReAct"],
      payments: ["x402", "MPP", "Xochi"],
      backends: @backends
    }
  end

  @doc "MCP server invocation and its built-in headless tools."
  @spec mcp() :: map()
  def mcp, do: %{command: "mix", args: ["mcp.server"], tools: @mcp_tools}

  @ssh_command "ssh -p 2222 playground@raxol.io"

  @doc """
  The hosted SSH playground command, or `nil` when that surface is not serving.

  Gated on the same `RAXOL_SSH_PLAYGROUND` env var the runtime itself reads
  (`Raxol.Application.maybe_add_ssh_playground/0`, and the `/health` SSH probe),
  so the site cannot advertise a port nothing is listening on. The surface was
  suspended 2026-08-26; re-enabling it in `fly.toml` restores every mention with
  no code change, which is why these render conditionally instead of being
  deleted.
  """
  @spec ssh_command() :: String.t() | nil
  def ssh_command, do: if(ssh_available?(), do: @ssh_command)

  @doc "Whether the hosted SSH playground is configured to serve."
  @spec ssh_available?() :: boolean()
  def ssh_available?, do: System.get_env("RAXOL_SSH_PLAYGROUND") == "true"

  @doc """
  Canonical outbound links for the manifest.

  `:ssh` is present only while that surface is serving -- a manifest is read by
  agents, so a dead entry there is worse than a missing one.
  """
  @spec links() :: map()
  def links do
    base = %{
      homepage: "https://raxol.io",
      skill: "https://raxol.io/skill.md",
      llms_txt: "https://raxol.io/llms.txt",
      capabilities: "https://raxol.io/api/capabilities",
      playground: "https://raxol.io/playground",
      docs: "https://hexdocs.pm/raxol",
      github: "https://github.com/DROOdotFOO/raxol",
      hex: "https://hex.pm/packages/raxol"
    }

    case ssh_command() do
      nil -> base
      cmd -> Map.put(base, :ssh, cmd)
    end
  end
end
