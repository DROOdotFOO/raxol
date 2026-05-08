defmodule Raxol.Symphony.Runners.Codex.Protocol do
  @moduledoc """
  Pure helpers for the Codex app-server JSON-RPC 2.0 protocol.

  Builds outbound payloads for the three-step handshake (`initialize` ->
  `initialized` -> `thread/start`) plus per-turn `turn/start`, and classifies
  inbound notifications into Symphony event maps consumable by the
  Orchestrator.

  Mirrors the schema used by the OpenAI Symphony Elixir reference impl
  (`SymphonyElixir.Codex.AppServer`), so workflows authored against upstream
  Codex behave identically.
  """

  @initialize_id 1
  @thread_start_id 2

  @client_name "raxol-symphony"
  @client_title "Raxol Symphony"
  @client_version "0.1.0"

  @type classification ::
          {:turn_completed, map()}
          | {:turn_failed, map(), term()}
          | {:tool_call, term(), binary() | nil, term(), map()}
          | {:approval, term(), binary(), map()}
          | {:input_required, map(), term()}
          | {:notification, map()}
          | {:response, map()}
          | :ignore

  # ---------------------------------------------------------------------------
  # Outbound payload builders
  # ---------------------------------------------------------------------------

  @doc "Numeric id used by the `initialize` request. Matched on response."
  @spec initialize_id() :: pos_integer()
  def initialize_id, do: @initialize_id

  @doc "Numeric id used by the `thread/start` request. Matched on response."
  @spec thread_start_id() :: pos_integer()
  def thread_start_id, do: @thread_start_id

  @doc "Builds the outbound `initialize` request payload."
  @spec initialize_request() :: map()
  def initialize_request do
    %{
      "method" => "initialize",
      "id" => @initialize_id,
      "params" => %{
        "capabilities" => %{"experimentalApi" => true},
        "clientInfo" => %{
          "name" => @client_name,
          "title" => @client_title,
          "version" => @client_version
        }
      }
    }
  end

  @doc "Builds the `initialized` notification (no id)."
  @spec initialized_notification() :: map()
  def initialized_notification, do: %{"method" => "initialized", "params" => %{}}

  @doc """
  Builds a `thread/start` request.

  `opts` accepts `:approval_policy`, `:thread_sandbox`, and `:dynamic_tools`.
  """
  @spec thread_start_request(Path.t(), keyword() | map()) :: map()
  def thread_start_request(workspace, opts) when is_binary(workspace) do
    opts = Map.new(opts)

    %{
      "method" => "thread/start",
      "id" => @thread_start_id,
      "params" => %{
        "approvalPolicy" => Map.get(opts, :approval_policy, "never"),
        "sandbox" => Map.get(opts, :thread_sandbox, "workspace-write"),
        "cwd" => workspace,
        "dynamicTools" => Map.get(opts, :dynamic_tools, [])
      }
    }
  end

  @doc """
  Builds a `turn/start` request with the given numeric id.

  `issue` is a map (or struct) carrying `:identifier` and `:title`.
  `opts` accepts `:approval_policy` and `:turn_sandbox_policy`.
  """
  @spec turn_start_request(pos_integer(), binary(), Path.t(), binary(), map(), keyword() | map()) ::
          map()
  def turn_start_request(id, thread_id, workspace, prompt, issue, opts)
      when is_integer(id) and id > 0 and is_binary(thread_id) and is_binary(workspace) and
             is_binary(prompt) do
    opts = Map.new(opts)
    identifier = Map.get(issue, :identifier) || Map.get(issue, "identifier") || ""
    title = Map.get(issue, :title) || Map.get(issue, "title") || ""

    %{
      "method" => "turn/start",
      "id" => id,
      "params" => %{
        "threadId" => thread_id,
        "input" => [%{"type" => "text", "text" => prompt}],
        "cwd" => workspace,
        "title" => "#{identifier}: #{title}",
        "approvalPolicy" => Map.get(opts, :approval_policy, "never"),
        "sandboxPolicy" => Map.get(opts, :turn_sandbox_policy, %{})
      }
    }
  end

  @doc "Builds a tool-call result reply for a Codex `item/tool/call` request."
  @spec tool_call_result(term(), map()) :: map()
  def tool_call_result(id, %{} = result), do: %{"id" => id, "result" => result}

  @doc "Builds an approval reply (`acceptForSession` or `approved_for_session`)."
  @spec approval_result(term(), binary()) :: map()
  def approval_result(id, decision) when is_binary(decision),
    do: %{"id" => id, "result" => %{"decision" => decision}}

  # ---------------------------------------------------------------------------
  # Inbound classification
  # ---------------------------------------------------------------------------

  @doc """
  Classifies an inbound JSON-RPC payload into a Symphony event tagged with
  a control instruction for the receive loop.
  """
  @spec classify(map() | term()) :: classification()
  def classify(%{"method" => "turn/completed"} = payload) do
    {:turn_completed, base_event(:turn_completed, payload, "turn complete")}
  end

  def classify(%{"method" => "turn/failed", "params" => params} = payload) do
    {:turn_failed, base_event(:turn_failed, payload, "turn failed"), {:turn_failed, params}}
  end

  def classify(%{"method" => "turn/cancelled", "params" => params} = payload) do
    {:turn_failed, base_event(:turn_failed, payload, "turn cancelled"), {:turn_cancelled, params}}
  end

  def classify(%{"method" => "item/tool/call", "id" => id, "params" => params} = payload) do
    name = tool_call_name(params)
    arguments = tool_call_arguments(params)
    message = "tool: #{name || "unknown"}"
    {:tool_call, id, name, arguments, base_event(:tool_use, payload, message)}
  end

  def classify(%{"method" => "item/commandExecution/requestApproval", "id" => id} = payload) do
    {:approval, id, "acceptForSession",
     base_event(:blocked, payload, "approval: command_execution")}
  end

  def classify(%{"method" => "item/fileChange/requestApproval", "id" => id} = payload) do
    {:approval, id, "acceptForSession", base_event(:blocked, payload, "approval: file_change")}
  end

  def classify(%{"method" => "execCommandApproval", "id" => id} = payload) do
    {:approval, id, "approved_for_session",
     base_event(:blocked, payload, "approval: exec_command")}
  end

  def classify(%{"method" => "applyPatchApproval", "id" => id} = payload) do
    {:approval, id, "approved_for_session",
     base_event(:blocked, payload, "approval: apply_patch")}
  end

  def classify(%{"method" => "item/tool/requestUserInput"} = payload) do
    {:input_required, base_event(:blocked, payload, "input required"), :tool_user_input}
  end

  def classify(%{"id" => _, "result" => _} = payload), do: {:response, payload}
  def classify(%{"id" => _, "error" => _} = payload), do: {:response, payload}

  def classify(%{"method" => method} = payload) when is_binary(method) do
    {:notification, notification_event(method, payload)}
  end

  def classify(_), do: :ignore

  # ---------------------------------------------------------------------------
  # Internals
  # ---------------------------------------------------------------------------

  defp notification_event(method, payload) do
    if agent_text_method?(method) do
      text = extract_text(payload) || ""
      base_event(:text_delta, payload, text)
    else
      base_event(:tool_use, payload, method)
    end
  end

  defp agent_text_method?(method) do
    String.contains?(method, "agentMessage") or
      String.contains?(method, "agentText") or
      String.ends_with?(method, "/delta")
  end

  defp base_event(event, payload, message) do
    base = %{
      event: event,
      message: message,
      timestamp: DateTime.utc_now(),
      payload: payload
    }

    case extract_usage(payload) do
      nil -> base
      usage -> Map.put(base, :usage, usage)
    end
  end

  defp extract_usage(%{"usage" => %{} = usage}), do: normalize_usage(usage)
  defp extract_usage(%{"params" => %{"usage" => %{} = usage}}), do: normalize_usage(usage)
  defp extract_usage(_), do: nil

  defp normalize_usage(usage) do
    %{
      input_tokens: int_lookup(usage, ["input_tokens", "inputTokens", "prompt_tokens"]),
      output_tokens: int_lookup(usage, ["output_tokens", "outputTokens", "completion_tokens"]),
      total_tokens: int_lookup(usage, ["total_tokens", "totalTokens"])
    }
  end

  defp int_lookup(map, keys) do
    Enum.find_value(keys, 0, fn k ->
      case Map.get(map, k) do
        n when is_integer(n) -> n
        _ -> nil
      end
    end)
  end

  defp extract_text(payload) do
    case Map.get(payload, "params") do
      %{"text" => text} when is_binary(text) -> text
      %{"delta" => %{"text" => text}} when is_binary(text) -> text
      %{"item" => %{"text" => text}} when is_binary(text) -> text
      _ -> nil
    end
  end

  defp tool_call_name(%{} = params) do
    case Map.get(params, "tool") || Map.get(params, "name") do
      name when is_binary(name) ->
        case String.trim(name) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp tool_call_name(_), do: nil

  defp tool_call_arguments(%{} = params), do: Map.get(params, "arguments", %{})
  defp tool_call_arguments(_), do: %{}
end
