defmodule Raxol.Telegram.Guardian.MCPTools do
  @moduledoc """
  Optional MCP tool exports for `Raxol.Telegram.Guardian`.

  Symmetric with ADR-0012 (MCP as rendering target): treats Guardian's
  decision boundary as a first-class MCP surface so external agents can
  observe and override join-request screening without protocol glue.

  Four tools, registered with `Raxol.MCP.Registry` only when `raxol_mcp`
  is loaded at runtime (no compile-time dep):

    * `telegram_guardian_approve`: admits an applicant
    * `telegram_guardian_decline`: rejects an applicant
    * `telegram_guardian_screen`: runs `Guardian.decide/2` on a synthetic
      applicant without Bot API side effects (useful for testing screeners)
    * `telegram_guardian_list_pending`: returns `[]` in v1; persistence
      lands in v2 per ADR-0014

  ## Wiring

  Call `register/0` once at app start after `Raxol.MCP.Registry` is up:

      Raxol.Telegram.Guardian.MCPTools.register()

  Without `raxol_mcp` in your deps, `register/0` returns
  `{:error, :raxol_mcp_not_available}` and the package keeps working
  without MCP exports.
  """

  @compile {:no_warn_undefined, [Raxol.MCP.Registry]}

  alias Raxol.Telegram.Guardian

  @doc """
  Registers all four Guardian tools with the given MCP registry.

  Returns `:ok` on success, `{:error, :raxol_mcp_not_available}` when
  `raxol_mcp` is not loaded.
  """
  @spec register(GenServer.server() | nil) :: :ok | {:error, :raxol_mcp_not_available}
  def register(registry \\ nil) do
    if Code.ensure_loaded?(Raxol.MCP.Registry) do
      target = registry || Raxol.MCP.Registry
      Raxol.MCP.Registry.register_tools(target, tools())
    else
      {:error, :raxol_mcp_not_available}
    end
  end

  @doc """
  Returns the four tool definitions without registering them.

  `apply_opts` are forwarded to `Guardian.apply_decision/3` for the approve
  and decline tools. Lets tests inject `post_fn`, `bot_token`, etc., without
  smuggling them through the MCP `args` map. Production callers use the
  default (`[]`).
  """
  @spec tools(keyword()) :: [map()]
  def tools(apply_opts \\ []) do
    [
      tool_approve(apply_opts),
      tool_decline(apply_opts),
      tool_screen(),
      tool_list_pending()
    ]
  end

  # --- Tool defs ---

  defp tool_approve(apply_opts) do
    %{
      name: "telegram_guardian_approve",
      description:
        "Approve a pending Telegram chat-join applicant. " <>
          "Uses answerChatJoinRequestQuery (Bot API 10.1) when query_id is present, " <>
          "falls back to approveChatJoinRequest otherwise.",
      inputSchema: %{
        type: "object",
        required: ["chat_id", "user_id"],
        properties: %{
          chat_id: %{type: "integer", description: "Group chat ID"},
          user_id: %{type: "integer", description: "Applicant user ID"},
          query_id: %{type: "string", description: "ChatJoinRequest query_id (10.1+)"},
          reason: %{type: "string", description: "Free-form reason logged in telemetry"}
        }
      },
      callback: fn args ->
        applicant = applicant_from_args(args)
        reason = get_arg(args, "reason")

        result =
          Guardian.apply_decision(applicant, {:approve, reason}, [{:source, :mcp} | apply_opts])

        mcp_response("approve", result)
      end
    }
  end

  defp tool_decline(apply_opts) do
    %{
      name: "telegram_guardian_decline",
      description:
        "Decline a pending Telegram chat-join applicant. " <>
          "Uses answerChatJoinRequestQuery (10.1) when query_id is present, " <>
          "falls back to declineChatJoinRequest otherwise.",
      inputSchema: %{
        type: "object",
        required: ["chat_id", "user_id"],
        properties: %{
          chat_id: %{type: "integer"},
          user_id: %{type: "integer"},
          query_id: %{type: "string"},
          reason: %{type: "string"}
        }
      },
      callback: fn args ->
        applicant = applicant_from_args(args)
        reason = get_arg(args, "reason")

        result =
          Guardian.apply_decision(applicant, {:decline, reason}, [{:source, :mcp} | apply_opts])

        mcp_response("decline", result)
      end
    }
  end

  defp tool_screen do
    %{
      name: "telegram_guardian_screen",
      description:
        "Runs the configured Guardian's screen/1 callback against a synthetic applicant " <>
          "without applying the decision. Returns the decision tuple as JSON. " <>
          "Useful for testing screener logic via an external agent.",
      inputSchema: %{
        type: "object",
        required: ["chat_id", "user_id"],
        properties: %{
          chat_id: %{type: "integer"},
          user_id: %{type: "integer"},
          query_id: %{type: "string"},
          username: %{type: "string"},
          first_name: %{type: "string"},
          last_name: %{type: "string"},
          bio: %{type: "string"},
          invite_link: %{type: "string"}
        }
      },
      callback: fn args ->
        applicant = applicant_from_args(args)
        decision = Guardian.decide(applicant)

        {:ok,
         [
           %{
             type: "text",
             text: Jason.encode!(%{decision: decision_to_json(decision)})
           }
         ]}
      end
    }
  end

  defp tool_list_pending do
    %{
      name: "telegram_guardian_list_pending",
      description:
        "Returns applicants currently mid-:ask_mini_app decision. " <>
          "v1 always returns [] (pending-applicants persistence deferred to v2 per ADR-0014).",
      inputSchema: %{
        type: "object",
        properties: %{
          chat_id: %{type: "integer", description: "Optional chat_id filter"}
        }
      },
      callback: fn _args ->
        {:ok, [%{type: "text", text: Jason.encode!([])}]}
      end
    }
  end

  # --- Helpers ---

  defp applicant_from_args(args) do
    base = %{
      chat_id: get_arg(args, "chat_id"),
      user_id: get_arg(args, "user_id"),
      query_id: get_arg(args, "query_id")
    }

    Enum.reduce(
      [:username, :first_name, :last_name, :bio, :invite_link],
      base,
      fn key, acc ->
        case get_arg(args, Atom.to_string(key)) do
          nil -> acc
          value -> Map.put(acc, key, value)
        end
      end
    )
  end

  defp get_arg(args, key) when is_binary(key) do
    Map.get(args, key) || Map.get(args, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(args, key)
  end

  defp mcp_response(action, {:ok, _result}) do
    {:ok, [%{type: "text", text: "#{action}: ok"}]}
  end

  defp mcp_response(action, {:error, reason}) do
    {:ok, [%{type: "text", text: "#{action}: error #{inspect(reason)}"}]}
  end

  defp decision_to_json({:approve, reason}), do: %{action: "approve", reason: reason}
  defp decision_to_json({:decline, reason}), do: %{action: "decline", reason: reason}

  defp decision_to_json({:ask_mini_app, url, button_text}),
    do: %{action: "ask_mini_app", url: url, button_text: button_text}
end
