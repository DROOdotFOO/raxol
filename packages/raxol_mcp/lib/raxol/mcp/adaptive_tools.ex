defmodule Raxol.MCP.AdaptiveTools do
  @moduledoc """
  MCP tool definitions for the adaptive UI subsystem.

  Exposes layout recommendations, behavior aggregates, and feedback
  loop controls as MCP tools for AI agent interaction.

  Tools are only registered when the adaptive modules are loaded.
  """

  @compile {:no_warn_undefined,
            [
              Raxol.Adaptive.BehaviorTracker,
              Raxol.Adaptive.LayoutRecommender,
              Raxol.Adaptive.FeedbackLoop
            ]}

  @doc "Returns adaptive MCP tool definitions, or empty list if adaptive modules unavailable."
  @spec tools() :: [Raxol.MCP.Registry.tool_def()]
  def tools do
    if available?() do
      [
        get_recommendation_tool(),
        accept_recommendation_tool(),
        reject_recommendation_tool(),
        get_behavior_summary_tool(),
        get_accuracy_tool()
      ]
    else
      []
    end
  end

  @doc "Returns true if the adaptive modules are loaded."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(Raxol.Adaptive.LayoutRecommender) and
      Code.ensure_loaded?(Raxol.Adaptive.BehaviorTracker) and
      Code.ensure_loaded?(Raxol.Adaptive.FeedbackLoop)
  end

  # -- Tool Definitions --

  defp get_recommendation_tool do
    %{
      name: "adaptive_get_recommendation",
      description: """
      Returns the most recent layout recommendation from the adaptive UI system.
      Includes layout changes (hide/show/expand/shrink), confidence score, and reasoning.
      Returns null if no recommendation has been generated yet.
      """,
      inputSchema: %{type: "object", properties: %{}},
      callback: &get_recommendation/1
    }
  end

  defp accept_recommendation_tool do
    %{
      name: "adaptive_accept_recommendation",
      description: """
      Accepts a pending layout recommendation by ID. This feeds positive signal
      into the feedback loop for model improvement.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          recommendation_id: %{
            type: "string",
            description: "The recommendation ID to accept"
          }
        },
        required: ["recommendation_id"]
      },
      callback: &accept_recommendation/1
    }
  end

  defp reject_recommendation_tool do
    %{
      name: "adaptive_reject_recommendation",
      description: """
      Rejects a pending layout recommendation by ID. This feeds negative signal
      into the feedback loop for model improvement.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          recommendation_id: %{
            type: "string",
            description: "The recommendation ID to reject"
          }
        },
        required: ["recommendation_id"]
      },
      callback: &reject_recommendation/1
    }
  end

  defp get_behavior_summary_tool do
    %{
      name: "adaptive_get_behavior_summary",
      description: """
      Returns recent behavior aggregates from the BehaviorTracker.
      Shows pane dwell times, command frequency, scroll metrics,
      alert response times, and takeover duration.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          window_count: %{
            type: "integer",
            description: "Number of recent aggregate windows to return (default: 3)"
          }
        }
      },
      callback: &get_behavior_summary/1
    }
  end

  defp get_accuracy_tool do
    %{
      name: "adaptive_get_accuracy",
      description: """
      Returns the feedback loop acceptance accuracy as a percentage.
      Tracks how often layout recommendations are accepted vs rejected.
      """,
      inputSchema: %{type: "object", properties: %{}},
      callback: &get_accuracy/1
    }
  end

  @doc "Registers adaptive tools with the MCP registry."
  @spec register(GenServer.server()) :: :ok
  def register(registry \\ Raxol.MCP.Registry) do
    if Code.ensure_loaded?(Raxol.MCP.Registry) do
      Raxol.MCP.Registry.register_tools(registry, tools())
    end

    :ok
  end

  # -- Callbacks --

  defp get_recommendation(_args) do
    rec = Raxol.Adaptive.LayoutRecommender.get_last_recommendation()

    if rec do
      changes =
        Enum.map(rec.layout_changes, fn c ->
          %{
            pane_id: to_string(c.pane_id),
            action: to_string(c.action),
            params: c.params
          }
        end)

      %{
        id: rec.id,
        confidence: rec.confidence,
        reasoning: rec.reasoning,
        layout_changes: changes,
        timestamp: rec.timestamp
      }
    else
      %{recommendation: nil, message: "No recommendation generated yet"}
    end
  end

  defp accept_recommendation(%{"recommendation_id" => rec_id}) do
    case Raxol.Adaptive.FeedbackLoop.accept(rec_id) do
      :ok ->
        %{status: "accepted", recommendation_id: rec_id}

      {:error, :not_found} ->
        %{status: "error", message: "Recommendation not found: #{rec_id}"}
    end
  end

  defp accept_recommendation(_),
    do: %{status: "error", message: "recommendation_id required"}

  defp reject_recommendation(%{"recommendation_id" => rec_id}) do
    case Raxol.Adaptive.FeedbackLoop.reject(rec_id) do
      :ok ->
        %{status: "rejected", recommendation_id: rec_id}

      {:error, :not_found} ->
        %{status: "error", message: "Recommendation not found: #{rec_id}"}
    end
  end

  defp reject_recommendation(_),
    do: %{status: "error", message: "recommendation_id required"}

  defp get_behavior_summary(args) do
    count = Map.get(args, "window_count", 3)
    aggregates = Raxol.Adaptive.BehaviorTracker.get_aggregates(count)

    Enum.map(aggregates, fn agg ->
      %{
        window_start: agg.window_start,
        pane_dwell_times: stringify_keys(agg.pane_dwell_times),
        command_frequency: agg.command_frequency,
        avg_alert_response_ms: agg.avg_alert_response_ms,
        most_used_panes: Enum.map(agg.most_used_panes, &to_string/1),
        least_used_panes: Enum.map(agg.least_used_panes, &to_string/1),
        scroll_frequency: stringify_keys(Map.get(agg, :scroll_frequency, %{})),
        takeover_duration_ms: stringify_keys(Map.get(agg, :takeover_duration_ms, %{})),
        layout_override_count: Map.get(agg, :layout_override_count, 0),
        command_concentration: stringify_keys(Map.get(agg, :command_concentration, %{}))
      }
    end)
  end

  defp get_accuracy(_args) do
    accuracy = Raxol.Adaptive.FeedbackLoop.get_accuracy()
    %{accuracy: Float.round(accuracy * 100, 1), unit: "percent"}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end
end
