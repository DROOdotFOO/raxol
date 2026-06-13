defmodule Raxol.Watch.Categories do
  @moduledoc """
  iOS `UNNotificationCategory` and Android `NotificationCompat.Action` data
  for `raxol_watch` notification types.

  Pure data, no platform calls. The host iOS app passes `ios_categories/0`
  to `UNUserNotificationCenter.setNotificationCategories`; the Wear OS app
  builds `NotificationCompat.Action` entries from `android_actions/1`.

  Three category buckets, matching the `:category` field on notifications
  produced by `Raxol.Watch.Formatter`:

    * `"raxol_alert"`: default. Details + Dismiss.
    * `"raxol_status"`: model-summary glances. Details + Dismiss.
    * `"raxol_chat"`: chat-style. Reply (with text input) + Mute + Pin +
      Delete + Dismiss. Reply uses iOS `UNTextInputNotificationAction` /
      Android `RemoteInput` so the OS prompts for text before the action
      ID arrives back at the bot. Use `Raxol.Watch.ActionHandler.handle_reply_action/3`
      to translate that text into a `:reply` Event.

  ## iOS shape

      [
        %{
          identifier: "raxol_chat",
          actions: [
            %{
              identifier: "reply",
              title: "Reply",
              options: [:foreground],
              text_input: %{button_title: "Send", placeholder: "Reply..."}
            },
            %{identifier: "mute", title: "Mute", options: []},
            ...
          ],
          intent_identifiers: [],
          options: []
        },
        ...
      ]

  Host iOS code (Swift):

      let categories = RaxolWatchCategories.iosCategories()
        .map { dict -> UNNotificationCategory in ... }
      UNUserNotificationCenter.current().setNotificationCategories(Set(categories))

  ## Android shape

      %{
        "raxol_chat" => [
          %{id: "reply", title: "Reply", remote_input: %{label: "Reply...", choices: []}},
          %{id: "mute", title: "Mute"},
          ...
        ],
        ...
      }
  """

  @doc "iOS `UNNotificationCategory` data for the host app to register."
  @spec ios_categories() :: [map()]
  def ios_categories do
    [
      ios_category("raxol_alert", [
        ios_action("details", "Details"),
        ios_action("dismiss", "Dismiss", options: [:destructive])
      ]),
      ios_category("raxol_status", [
        ios_action("details", "Details"),
        ios_action("dismiss", "Dismiss", options: [:destructive])
      ]),
      ios_category("raxol_chat", [
        ios_text_action("reply", "Reply",
          button_title: "Send",
          placeholder: "Reply..."
        ),
        ios_action("mute", "Mute"),
        ios_action("pin", "Pin"),
        ios_action("delete", "Delete", options: [:destructive]),
        ios_action("dismiss", "Dismiss")
      ])
    ]
  end

  @doc """
  Android `NotificationCompat.Action` data for the host app.

  Returns all categories when called without args, or a single category's
  actions when called with the category string.
  """
  @spec android_actions() :: %{required(String.t()) => [map()]}
  def android_actions do
    %{
      "raxol_alert" => [
        android_action("details", "Details"),
        android_action("dismiss", "Dismiss")
      ],
      "raxol_status" => [
        android_action("details", "Details"),
        android_action("dismiss", "Dismiss")
      ],
      "raxol_chat" => [
        android_reply_action("reply", "Reply", "Reply..."),
        android_action("mute", "Mute"),
        android_action("pin", "Pin"),
        android_action("delete", "Delete"),
        android_action("dismiss", "Dismiss")
      ]
    }
  end

  @spec android_actions(String.t()) :: [map()] | nil
  def android_actions(category) when is_binary(category) do
    Map.get(android_actions(), category)
  end

  @doc "Known notification categories shipped by `Raxol.Watch.Formatter`."
  @spec known_categories() :: [String.t()]
  def known_categories, do: ["raxol_alert", "raxol_status", "raxol_chat"]

  # --- iOS builders ---

  defp ios_category(identifier, actions) do
    %{
      identifier: identifier,
      actions: actions,
      intent_identifiers: [],
      options: []
    }
  end

  defp ios_action(identifier, title, opts \\ []) do
    %{
      identifier: identifier,
      title: title,
      options: Keyword.get(opts, :options, [])
    }
  end

  defp ios_text_action(identifier, title, opts) do
    %{
      identifier: identifier,
      title: title,
      options: Keyword.get(opts, :options, [:foreground]),
      text_input: %{
        button_title: Keyword.fetch!(opts, :button_title),
        placeholder: Keyword.fetch!(opts, :placeholder)
      }
    }
  end

  # --- Android builders ---

  defp android_action(id, title) do
    %{id: id, title: title}
  end

  defp android_reply_action(id, title, placeholder) do
    %{id: id, title: title, remote_input: %{label: placeholder, choices: []}}
  end
end
