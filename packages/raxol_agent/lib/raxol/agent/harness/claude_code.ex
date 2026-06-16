defmodule Raxol.Agent.Harness.ClaudeCode do
  @moduledoc """
  Native harness driver for the Claude Code CLI (`claude`).

  Drives a single non-interactive run via `claude -p <prompt> --output-format
  stream-json --verbose`, injecting Raxol's tools with `--mcp-config <path>`.
  Parses the `stream-json` NDJSON protocol via `Raxol.Agent.Harness.StreamJson`.

  The CLI owns its agent loop and tool dispatch, so a backend built on this driver
  reports `handles_tools_internally? == true`.
  """

  @behaviour Raxol.Agent.NativeHarness

  alias Raxol.Agent.Harness.StreamJson

  @impl true
  def executable, do: "claude"

  @impl true
  def name, do: "Claude Code"

  @impl true
  def args(config) do
    prompt = Map.get(config, :prompt, "")

    ["-p", prompt, "--output-format", "stream-json", "--verbose"]
    |> append_model(Map.get(config, :model))
    |> append_system_prompt(Map.get(config, :system_prompt))
    |> append_mcp_config(Map.get(config, :mcp_config_path))
    |> Kernel.++(Map.get(config, :extra_args, []))
  end

  @impl true
  defdelegate parse_line(line), to: StreamJson

  defp append_model(args, nil), do: args
  defp append_model(args, model), do: args ++ ["--model", model]

  defp append_system_prompt(args, nil), do: args
  defp append_system_prompt(args, ""), do: args
  defp append_system_prompt(args, prompt), do: args ++ ["--append-system-prompt", prompt]

  defp append_mcp_config(args, nil), do: args
  defp append_mcp_config(args, path), do: args ++ ["--mcp-config", path]
end
