defmodule Raxol.Agent.Harness.GrokBuild do
  @moduledoc """
  Native harness driver for xAI's Grok CLI (`grok`).

  Drives a single non-interactive run via `grok -p <prompt> --output-format
  streaming-json`. The CLI owns its agent loop and tool dispatch, so a backend
  built on this driver reports `handles_tools_internally? == true`.

  ## Wire format

  `streaming-json` is NDJSON derived from the agent's own ACP session updates —
  a different vocabulary from the `stream-json` protocol Claude Code and Cursor
  share, so it does not reuse `Raxol.Agent.Harness.StreamJson`. One
  `type`-tagged object per line:

      {"type":"thought","data":"Analyzing the directory structure..."}
      {"type":"tool_call","toolCallId":"call_1","toolName":"read_file",...}
      {"type":"tool_call_update","toolCallId":"call_1","status":"completed",...}
      {"type":"text","data":"Here's a summary"}
      {"type":"end","stopReason":"end_turn","usage":{...},"num_turns":7}

  `end` is always last and carries spend, not text: the answer arrives as
  `text` lines, and `Raxol.Agent.Backend.Native` substitutes its accumulated
  text for an empty `:done` content. xAI documents the type list as
  non-exhaustive (`plan`, `available_commands`, `max_turns_reached`,
  `auto_compact_*`, ...), so unknown types parse to `[]` rather than failing a
  run.

  ## No MCP tool injection

  `injects_mcp_tools?/0` is `false`: `grok` configures MCP servers through its
  settings files, with no per-run flag equivalent to Claude Code's
  `--mcp-config`, so there is nowhere to hand it a generated config. Raxol's
  Actions are NOT exposed to this CLI — it runs with its own built-in tools.
  `--tools` / `--disallowed-tools` can narrow those, via `:extra_args`.
  """

  @behaviour Raxol.Agent.NativeHarness

  alias Raxol.Agent.NativeHarness

  @impl true
  def executable, do: "grok"

  @impl true
  def name, do: "Grok Build"

  @impl true
  def injects_mcp_tools?, do: false

  @impl true
  def args(config) do
    prompt = Map.get(config, :prompt, "")

    ["-p", prompt, "--output-format", "streaming-json"]
    |> append_model(Map.get(config, :model))
    |> append_rules(Map.get(config, :system_prompt))
    |> Kernel.++(Map.get(config, :extra_args, []))
  end

  @impl true
  @spec parse_line(String.t()) :: [NativeHarness.event()]
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = obj} -> parse_object(obj)
      _not_json -> []
    end
  end

  defp parse_object(%{"type" => "text", "data" => data}) when is_binary(data),
    do: [{:text, data}]

  defp parse_object(%{"type" => "thought", "data" => data}) when is_binary(data),
    do: [{:reasoning, data}]

  # Observability only: the CLI serves the tool itself, so there is nothing for
  # the framework to dispatch. `toolName` is the internal id (`read_file`);
  # `title` is the display name, used when a build omits the id.
  defp parse_object(%{"type" => "tool_call", "toolCallId" => id} = obj) do
    [
      {:tool_call,
       %{
         name: Map.get(obj, "toolName") || Map.get(obj, "title"),
         input: Map.get(obj, "rawInput", %{}),
         id: id
       }}
    ]
  end

  defp parse_object(%{"type" => "end"} = obj),
    do: [{:done, %{content: "", usage: usage(obj)}}]

  defp parse_object(%{"type" => "error"} = obj),
    do: [{:error, {:grok_error, Map.get(obj, "message", "")}}]

  defp parse_object(_other), do: []

  # `total_cost_usd` is stamped for API-key traffic and omitted on the
  # subscription/OAuth path, so a free run reports tokens with no `:cost` and
  # the spend plumbing sees nothing to meter -- which is the honest answer.
  defp usage(obj) do
    usage = Map.get(obj, "usage") || %{}

    case Map.get(obj, "total_cost_usd") do
      cost when is_number(cost) -> Map.put(usage, "cost", cost)
      _absent -> usage
    end
  end

  defp append_model(args, nil), do: args
  defp append_model(args, model), do: args ++ ["-m", model]

  defp append_rules(args, nil), do: args
  defp append_rules(args, ""), do: args
  defp append_rules(args, rules), do: args ++ ["--rules", rules]
end
