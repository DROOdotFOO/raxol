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
  @chat_category "raxol_chat"
  @status_category "raxol_status"

  @default_actions [
    %{id: "details", label: "Details"},
    %{id: "dismiss", label: "Dismiss"}
  ]

  @chat_actions [
    %{id: "reply", label: "Reply"},
    %{id: "mute", label: "Mute"},
    %{id: "pin", label: "Pin"},
    %{id: "delete", label: "Delete"},
    %{id: "dismiss", label: "Dismiss"}
  ]

  @type media_type :: :sticker | :photo | :video_thumb

  @type location :: %{
          required(:lat) => float(),
          required(:lng) => float(),
          optional(:label) => String.t() | nil
        }

  @type notification :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:category) => String.t(),
          required(:actions) => [%{id: String.t(), label: String.t()}],
          required(:priority) => :high | :normal | :silent,
          required(:badge) => non_neg_integer(),
          optional(:body_long) => String.t() | nil,
          optional(:audio_url) => String.t() | nil,
          optional(:image_url) => String.t() | nil,
          optional(:media_type) => media_type() | nil,
          optional(:location) => location() | nil
        }

  @doc """
  Formats an accessibility announcement into a notification payload.
  """
  @spec format_announcement(String.t(), atom()) :: notification()
  def format_announcement(message, priority \\ :normal) do
    base(@default_title, message)
    |> Map.merge(%{
      category: @default_category,
      actions: actions_for_priority(priority),
      priority: map_priority(priority),
      badge: badge_for_priority(priority)
    })
  end

  @doc """
  Formats model state projections into a glanceable summary notification.

  Takes a map of `{label, value}` pairs and renders them as a compact
  multi-line body.
  """
  @spec format_model_summary(String.t(), [{String.t(), term()}]) :: notification()
  def format_model_summary(title \\ @default_title, projections) do
    long =
      Enum.map_join(projections, "\n", fn {label, value} -> "#{label}: #{value}" end)

    base(title, long)
    |> Map.merge(%{
      category: @status_category,
      actions: actions_for_category(:status),
      priority: :normal,
      badge: 0
    })
  end

  @doc """
  Notification with an attached voice / audio clip.

  `audio_url` should resolve from the host iOS / Android app's perspective
  (the app's NotificationServiceExtension downloads and attaches it).
  """
  @spec format_audio(String.t(), String.t(), String.t(), keyword()) :: notification()
  def format_audio(title, body, audio_url, opts \\ []) when is_binary(audio_url) do
    title
    |> base(body)
    |> Map.merge(%{
      category: opts[:category] || @chat_category,
      actions: opts[:actions] || actions_for_category(:chat),
      priority: opts[:priority] || :normal,
      badge: opts[:badge] || 0,
      audio_url: audio_url
    })
  end

  @doc """
  Notification with an attached image (photo or video thumbnail).
  """
  @spec format_image(String.t(), String.t(), String.t(), keyword()) :: notification()
  def format_image(title, body, image_url, opts \\ []) when is_binary(image_url) do
    title
    |> base(body)
    |> Map.merge(%{
      category: opts[:category] || @chat_category,
      actions: opts[:actions] || actions_for_category(:chat),
      priority: opts[:priority] || :normal,
      badge: opts[:badge] || 0,
      image_url: image_url,
      media_type: opts[:media_type] || :photo
    })
  end

  @doc """
  Sticker notification. Convenience over `format_image/4` with
  `media_type: :sticker`.
  """
  @spec format_sticker(String.t(), String.t(), String.t(), keyword()) :: notification()
  def format_sticker(title, body, sticker_url, opts \\ []) when is_binary(sticker_url) do
    format_image(title, body, sticker_url, Keyword.put(opts, :media_type, :sticker))
  end

  @doc """
  Notification carrying a geographic location.

  The optional `:label` on the location map (e.g. `"Home"`, `"Office"`) is
  shown alongside the map preview on platforms that support it.
  """
  @spec format_location(String.t(), String.t(), location(), keyword()) :: notification()
  def format_location(title, body, %{lat: lat, lng: lng} = location, opts \\ [])
      when is_float(lat) and is_float(lng) do
    title
    |> base(body)
    |> Map.merge(%{
      category: opts[:category] || @chat_category,
      actions: opts[:actions] || actions_for_category(:chat),
      priority: opts[:priority] || :normal,
      badge: opts[:badge] || 0,
      location: location
    })
  end

  @doc """
  Long-form message notification. `body` becomes the 160-char glance
  shown on the watch face; `body_long` carries the full text for the
  detail view.
  """
  @spec format_long_message(String.t(), String.t(), keyword()) :: notification()
  def format_long_message(title, body_long, opts \\ []) when is_binary(body_long) do
    title
    |> base(body_long)
    |> Map.merge(%{
      category: opts[:category] || @chat_category,
      actions: opts[:actions] || actions_for_category(:chat),
      priority: opts[:priority] || :normal,
      badge: opts[:badge] || 0
    })
  end

  @doc """
  Chat-style message notification: glance + long body + chat action set
  (reply, mute, pin, delete, dismiss).
  """
  @spec format_chat_message(String.t(), String.t(), keyword()) :: notification()
  def format_chat_message(title, body, opts \\ []) do
    format_long_message(title, body, opts)
  end

  @doc "Returns the action list for a notification category."
  @spec actions_for_category(:alert | :status | :chat) ::
          [%{id: String.t(), label: String.t()}]
  def actions_for_category(:chat), do: @chat_actions
  def actions_for_category(:status), do: @default_actions
  def actions_for_category(:alert), do: @default_actions

  @doc "Returns the max body length for the glanceable body field."
  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  # -- Private --

  # Builds the shared base for every constructor: title, truncated body for
  # the watch glance, and the full body preserved under :body_long.
  defp base(title, full_body) when is_binary(full_body) do
    %{
      title: title,
      body: truncate(full_body),
      body_long: full_body,
      audio_url: nil,
      image_url: nil,
      media_type: nil,
      location: nil
    }
  end

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
