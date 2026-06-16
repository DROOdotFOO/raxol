defmodule Raxol.Agent.Harness.StreamJson do
  @moduledoc """
  Parser for the `--output-format stream-json` NDJSON protocol shared by Claude
  Code and Cursor's `cursor-agent`.

  Each stdout line is a standalone JSON object tagged with a `type`:

  - `system` (init/config) -- ignored.
  - `assistant` -- a model message; its `content` blocks become `:text`,
    `:reasoning` (thinking), or `:tool_call` events.
  - `user` -- tool results echoed back; ignored (the MCP server owns execution).
  - `result` -- the terminal event; `success` yields `{:done, ...}` with the
    final text + usage, an error subtype yields `{:error, ...}`.

  Non-JSON lines (banners, warnings) parse to `[]` so stray output never breaks a
  run. Returns `Raxol.Agent.NativeHarness` event tuples.
  """

  alias Raxol.Agent.NativeHarness

  @doc "Parse one NDJSON line into normalized harness events."
  @spec parse_line(String.t()) :: [NativeHarness.event()]
  def parse_line(line) do
    case Jason.decode(String.trim(line)) do
      {:ok, %{} = obj} -> parse_object(obj)
      _ -> []
    end
  end

  defp parse_object(%{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    Enum.flat_map(content, &parse_block/1)
  end

  defp parse_object(%{"type" => "result", "subtype" => "success"} = obj) do
    [{:done, %{content: result_text(obj), usage: usage(obj)}}]
  end

  defp parse_object(%{"type" => "result", "subtype" => subtype} = obj) do
    [{:error, {:result_error, subtype, result_text(obj)}}]
  end

  defp parse_object(_other), do: []

  defp parse_block(%{"type" => "text", "text" => text}) when is_binary(text),
    do: [{:text, text}]

  defp parse_block(%{"type" => "thinking", "thinking" => text}) when is_binary(text),
    do: [{:reasoning, text}]

  defp parse_block(%{"type" => "tool_use", "name" => name} = block) do
    [{:tool_call, %{name: name, input: Map.get(block, "input", %{}), id: Map.get(block, "id")}}]
  end

  defp parse_block(_other), do: []

  defp result_text(obj) do
    case Map.get(obj, "result") do
      text when is_binary(text) -> text
      _ -> ""
    end
  end

  defp usage(obj) do
    case Map.get(obj, "usage") do
      %{} = usage -> usage
      _ -> %{}
    end
  end
end
