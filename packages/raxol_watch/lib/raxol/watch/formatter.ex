defmodule Raxol.Watch.Formatter do
  @moduledoc """
  Formats TEA model state and accessibility announcements into
  watch-sized notification payloads.

  Notifications are truncated to 160 chars for glanceability on
  1.3"-2.0" watch screens. Priority maps announcement urgency to
  push notification priority (vibration behavior).
  """

  @max_body_length 160
  @default_title "Raxol"
  @default_category "raxol_alert"

  @default_actions [
    %{id: "details", label: "Details"},
    %{id: "dismiss", label: "Dismiss"}
  ]

  @type notification :: %{
          title: String.t(),
          body: String.t(),
          category: String.t(),
          actions: [%{id: String.t(), label: String.t()}],
          priority: :high | :normal | :silent,
          badge: non_neg_integer()
        }

  @doc """
  Formats an accessibility announcement into a notification payload.
  """
  @spec format_announcement(String.t(), atom()) :: notification()
  def format_announcement(message, priority \\ :normal) do
    %{
      title: @default_title,
      body: truncate(message),
      category: @default_category,
      actions: actions_for_priority(priority),
      priority: map_priority(priority),
      badge: badge_for_priority(priority)
    }
  end

  @doc """
  Formats model state projections into a glanceable summary notification.

  Takes a map of `{label, value}` pairs and renders them as a compact
  multi-line body.
  """
  @spec format_model_summary(String.t(), [{String.t(), term()}]) :: notification()
  def format_model_summary(title \\ @default_title, projections) do
    body =
      projections
      |> Enum.map_join("\n", fn {label, value} -> "#{label}: #{value}" end)
      |> truncate()

    %{
      title: title,
      body: body,
      category: "raxol_status",
      actions: @default_actions,
      priority: :normal,
      badge: 0
    }
  end

  @doc "Returns the max body length for watch notifications."
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  # -- Private --

  defp truncate(text) do
    if String.length(text) <= @max_body_length do
      text
    else
      String.slice(text, 0, @max_body_length - 3) <> "..."
    end
  end

  defp map_priority(:high), do: :high
  defp map_priority(:low), do: :silent
  defp map_priority(_), do: :normal

  defp badge_for_priority(:high), do: 1
  defp badge_for_priority(_), do: 0

  defp actions_for_priority(:high) do
    [
      %{id: "acknowledge", label: "OK"},
      %{id: "details", label: "Details"},
      %{id: "dismiss", label: "Dismiss"}
    ]
  end

  defp actions_for_priority(_), do: @default_actions
end
