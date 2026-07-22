defmodule Mix.Tasks.Raxol.Docs.Llms do
  @shortdoc "Generate llms.txt and llms-full.txt from the docs tree"

  @moduledoc """
  Regenerate the agent-facing documentation surface so it cannot drift from
  the source.

      cd web
      mix raxol.docs.llms

  Two files are written to `web/priv/static/`, both served at raxol.io:

    * `llms.txt` (the [llmstxt.org](https://llmstxt.org) convention): a curated
      index derived entirely from `RaxolPlayground.Capabilities` (the single
      source of truth for surfaces, packages, backends, and endpoints) plus an
      index of the `docs/` tree.
    * `llms-full.txt`: every curated doc concatenated into one file, the
      "single-file expanded context" an agent can ingest in one fetch.

  The task is deterministic: run it twice and the output is byte-identical, so a
  CI check can assert it is up to date.
  """

  use Mix.Task

  alias RaxolPlayground.Capabilities

  # Curated concatenation order for llms-full.txt. Each entry is a path (a file
  # or a directory) relative to the repo `docs/` root. Directories expand to
  # their `*.md` files sorted by name; a README inside a directory sorts first.
  @full_order [
    "getting-started/QUICKSTART.md",
    "getting-started/CORE_CONCEPTS.md",
    "PHILOSOPHY.md",
    "PACKAGES.md",
    "features",
    "reference",
    "core",
    "cookbook",
    "adr/README.md"
  ]

  @impl true
  def run(_args) do
    Application.load(:raxol)
    docs_root = docs_root()
    out_dir = Path.join(:code.priv_dir(:raxol_playground), "static")

    llms = build_llms(docs_root)
    llms_full = build_llms_full(docs_root)

    File.write!(Path.join(out_dir, "llms.txt"), llms)
    File.write!(Path.join(out_dir, "llms-full.txt"), llms_full)

    Mix.shell().info([
      :green,
      "wrote ",
      :reset,
      "llms.txt (#{byte_size(llms)} bytes) and llms-full.txt (#{byte_size(llms_full)} bytes) to web/priv/static/"
    ])
  end

  # --- llms.txt -------------------------------------------------------------

  defp build_llms(docs_root) do
    [
      "# Raxol\n",
      "> Multi-surface runtime for Elixir on OTP. One TEA module renders to a terminal, a browser (LiveView), an SSH session, MCP, Telegram, a watch, and speech. Agents get memory, self-improvement, tools, and agentic commerce.\n",
      quick_start(),
      capability_summary(),
      surfaces_section(),
      packages_section(),
      documentation_section(docs_root),
      mcp_section(),
      endpoints_section()
    ]
    |> Enum.join("\n")
    |> squeeze_blank_lines()
  end

  defp quick_start do
    dep = Capabilities.dep("raxol") || "{:raxol, \"~> 2.6\"}"

    """
    ## Quick start

        ssh -p 2222 playground@raxol.io    # zero install
        #{dep}                 # add to mix.exs
    """
  end

  defp capability_summary do
    agent = Capabilities.agent()
    backends = Enum.join(agent.backends, ", ")
    strategies = Enum.map_join(agent.strategies, ", ", &String.replace(&1, "Strategy.", ""))
    surfaces = Enum.map_join(Capabilities.surfaces(), ", ", & &1.name)

    """
    ## Capability summary

    Raxol is an Elixir framework built on OTP. It uses The Elm Architecture (TEA): init/1, update/2, view/1. The same module renders to these surfaces without modification: #{surfaces}.

    Agent framework: TEA agents (message-driven) and Process agents (tick-driven), teams with coordinator/worker supervision, reasoning strategies (#{strategies}), a Turn driver that wires memory and skills and self-improvement, and a native multi-vendor harness (Claude Code, Cursor) that serves Raxol tools over MCP. Backends: #{backends}.

    Agent learning: a provider-stack memory layer, full-text session recall, a dialectic user model, an after-turn self-improvement loop, and agent-authored skills in the agentskills.io SKILL.md format.

    Agent commerce: autonomous payments (x402, MPP, Xochi cross-chain), spending limits, stealth and shielded settlement, and ZKSAR trust attestations. No other agent runtime ships this.

    Governance: an ALLOW/ASK/DENY authorization engine gates every tool call, and a durable conversation item-log records what the agent did.
    """
  end

  defp surfaces_section do
    rows =
      Enum.map_join(Capabilities.surfaces(), "\n", fn s ->
        "- #{s.name} (#{s.transport}, #{s.dep})"
      end)

    "## Surfaces\n\n" <> rows <> "\n"
  end

  defp packages_section do
    rows =
      Enum.map_join(Capabilities.package_specs(), "\n", fn p ->
        "- #{p.name} `#{p.dep}`: #{p.purpose}"
      end)

    "## Packages\n\n" <> rows <> "\n"
  end

  defp documentation_section(docs_root) do
    github = Capabilities.links().github
    blob = github <> "/blob/master/docs"

    features =
      docs_root
      |> Path.join("features")
      |> list_md()
      |> Enum.reject(&(Path.basename(&1) == "README.md"))
      |> Enum.map_join("\n", fn path ->
        rel = Path.relative_to(path, docs_root)
        "- #{doc_title(path)}: #{blob}/#{rel}"
      end)

    """
    ## Documentation

    Full text of every doc, concatenated for single-fetch ingestion: https://raxol.io/llms-full.txt

    Feature docs:

    #{features}

    Tool/action catalog (every LLM-callable tool, with its parameters and authorization tier): #{blob}/reference/TOOL_CATALOG.md

    API reference (per package): https://hexdocs.pm/raxol
    """
  end

  defp mcp_section do
    mcp = Capabilities.mcp()
    args = Enum.map_join(mcp.args, ", ", &"\"#{&1}\"")

    """
    ## MCP integration

        {
          "mcpServers": {
            "raxol": {
              "command": "#{mcp.command}",
              "args": [#{args}],
              "cwd": "/path/to/your/raxol/app"
            }
          }
        }

    Built-in headless tools: #{Enum.join(mcp.tools, ", ")}.
    """
  end

  defp endpoints_section do
    links = Capabilities.links()

    rows =
      [
        {"Documentation (full text)", "https://raxol.io/llms-full.txt"},
        {"Skill file", links.skill},
        {"Capability manifest", "https://raxol.io/.well-known/raxol.json"},
        {"Capabilities API", links.capabilities},
        {"API docs", links.docs},
        {"GitHub", links.github},
        {"Hex", links.hex}
      ]
      |> Enum.map_join("\n", fn {label, url} -> "- #{label}: #{url}" end)

    "## Structured endpoints\n\n" <> rows <> "\n"
  end

  # --- llms-full.txt --------------------------------------------------------

  defp build_llms_full(docs_root) do
    header = """
    # Raxol: Full Documentation

    This file concatenates the Raxol documentation for single-fetch ingestion by
    an agent. The curated, linked index is at https://raxol.io/llms.txt. Sources
    live at https://github.com/DROOdotFOO/raxol/tree/master/docs.

    """

    body =
      @full_order
      |> Enum.flat_map(&expand_entry(docs_root, &1))
      |> Enum.uniq()
      |> Enum.map_join("\n\n", fn path ->
        rel = Path.relative_to(path, docs_root)
        "<!-- docs/#{rel} -->\n\n" <> String.trim_trailing(File.read!(path)) <> "\n"
      end)

    header <> body <> "\n"
  end

  defp expand_entry(docs_root, entry) do
    path = Path.join(docs_root, entry)

    cond do
      File.dir?(path) -> list_md(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  # --- helpers --------------------------------------------------------------

  # `*.md` files in a directory, README first, then the rest sorted by name.
  defp list_md(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort_by(fn path ->
      base = Path.basename(path)
      {if(base == "README.md", do: 0, else: 1), base}
    end)
  end

  defp doc_title(path) do
    path
    |> File.stream!()
    |> Enum.find_value(fn line ->
      case String.trim(line) do
        "# " <> title -> title
        _ -> nil
      end
    end)
    |> case do
      nil -> path |> Path.basename() |> Path.rootname()
      title -> title
    end
  end

  defp docs_root do
    candidate = Path.expand(Path.join([File.cwd!(), "..", "docs"]))

    if File.dir?(candidate) do
      candidate
    else
      Mix.raise(
        "docs/ not found at #{candidate}. Run this task from the web/ directory " <>
          "of a full raxol checkout (mix raxol.docs.llms)."
      )
    end
  end

  defp squeeze_blank_lines(text) do
    text
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end
end
