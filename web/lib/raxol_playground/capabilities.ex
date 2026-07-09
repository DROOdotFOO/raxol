defmodule RaxolPlayground.Capabilities do
  @moduledoc """
  Single source of truth for raxol.io's machine-readable agent surface.

  Surfaces, published packages, agent backends, and MCP tools live here once.
  The capability endpoints (`/.well-known/raxol.json`, `/api/capabilities`,
  `/llms.txt`) and the landing page stats all derive from this module, so the
  same facts are never restated in two places.

  Backends are kept in sync with `Raxol.Agent.Backend.Selector` by hand: the web
  app depends only on `raxol` (which does not depend on `raxol_agent`), so the
  harness table cannot be imported here.
  """

  @surfaces [
    %{name: "terminal", transport: "termbox2 NIF", dep: "raxol_terminal"},
    %{name: "liveview", transport: "Phoenix PubSub", dep: "raxol_liveview"},
    %{name: "ssh", transport: "Erlang :ssh", dep: "raxol (built-in)"},
    %{name: "mcp", transport: "stdio JSON-RPC", dep: "raxol_mcp"},
    %{name: "telegram", transport: "Telegex HTTP", dep: "raxol_telegram"},
    %{name: "watch", transport: "APNS/FCM push", dep: "raxol_watch"},
    %{name: "speech", transport: "TTS/STT (say/Whisper)", dep: "raxol_speech"}
  ]

  @packages [
    %{name: "raxol", version: "~> 2.5", purpose: "Full framework"},
    %{name: "raxol_agent", version: "~> 2.5", purpose: "AI agents"},
    %{name: "raxol_mcp", version: "~> 2.5", purpose: "MCP server"},
    %{name: "raxol_payments", version: "~> 0.1", purpose: "Agent commerce"},
    %{name: "raxol_liveview", version: "~> 2.5", purpose: "LiveView bridge"},
    %{name: "raxol_sensor", version: "~> 2.5", purpose: "Sensor fusion"},
    %{name: "raxol_terminal", version: "~> 2.5", purpose: "Terminal emulation"},
    %{name: "raxol_core", version: "~> 2.5", purpose: "Behaviours, events"},
    %{name: "raxol_plugin", version: "~> 2.5", purpose: "Plugin SDK"},
    %{name: "raxol_speech", version: "~> 0.2", purpose: "TTS/STT"},
    %{name: "raxol_telegram", version: "~> 0.2", purpose: "Telegram bot"},
    %{name: "raxol_watch", version: "~> 0.2", purpose: "Push notifications"}
  ]

  # Named LLM harnesses plus Groq (reached via the OpenAI-compatible base URL).
  @backends [
    "Anthropic",
    "OpenAI",
    "Ollama",
    "Kimi",
    "Groq",
    "LLM7",
    "OpenRouter",
    "Lumo",
    "Mock"
  ]

  @mcp_tools ~w(
    raxol_start raxol_screenshot raxol_send_key
    raxol_get_model raxol_stop raxol_list
  )

  @doc "Runtime `raxol` version, falling back to the build-time version."
  @spec version() :: String.t()
  def version do
    case :application.get_key(:raxol, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "2.5.0"
    end
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
  Packages with a ready-to-paste `mix.exs` dep tuple attached, e.g.
  `{:raxol, "~> 2.5"}`. Used by the manifest and capabilities endpoints.
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

  @doc "Agent LLM backends (display names)."
  @spec backends() :: [String.t()]
  def backends, do: @backends

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

  @doc "Canonical outbound links for the manifest."
  @spec links() :: map()
  def links do
    %{
      homepage: "https://raxol.io",
      skill: "https://raxol.io/skill.md",
      llms_txt: "https://raxol.io/llms.txt",
      capabilities: "https://raxol.io/api/capabilities",
      playground: "https://raxol.io/playground",
      ssh: "ssh -p 2222 playground@raxol.io",
      docs: "https://hexdocs.pm/raxol",
      github: "https://github.com/DROOdotFOO/raxol",
      hex: "https://hex.pm/packages/raxol"
    }
  end
end
