defmodule Raxol.Agent.Harness.Cursor do
  @moduledoc """
  Native harness driver for the Cursor agent CLI (`cursor-agent`).

  `cursor-agent` mirrors Claude Code's non-interactive interface: `cursor-agent
  -p <prompt> --output-format stream-json`, emitting the same `stream-json` NDJSON
  protocol (parsed via `Raxol.Agent.Harness.StreamJson`). Tools are injected with
  `--mcp-config <path>`.

  The CLI owns its agent loop and tool dispatch, so a backend built on this driver
  reports `handles_tools_internally? == true`.
  """

  @behaviour Raxol.Agent.NativeHarness

  alias Raxol.Agent.Harness.StreamJson

  @impl true
  def executable, do: "cursor-agent"

  @impl true
  def name, do: "Cursor"

  @impl true
  def args(config) do
    prompt = Map.get(config, :prompt, "")

    ["-p", prompt, "--output-format", "stream-json"]
    |> append_model(Map.get(config, :model))
    |> append_mcp_config(Map.get(config, :mcp_config_path))
    |> Kernel.++(Map.get(config, :extra_args, []))
  end

  @impl true
  defdelegate parse_line(line), to: StreamJson

  defp append_model(args, nil), do: args
  defp append_model(args, model), do: args ++ ["--model", model]

  defp append_mcp_config(args, nil), do: args
  defp append_mcp_config(args, path), do: args ++ ["--mcp-config", path]
end
