defmodule Raxol.Watch.Push.APNS do
  @moduledoc """
  Apple Push Notification Service backend via Pigeon 2.x.

  Pigeon 2.x requires consumers to define a dispatcher module
  (`use Pigeon.Dispatcher, otp_app: :your_app`) and start it under
  their own supervision tree. This backend forwards to a configured
  dispatcher via `Pigeon.push/3`.

  ## Configuration

      config :raxol_watch, Raxol.Watch.Push.APNS,
        dispatcher: MyApp.APNS,
        topic: "io.example.app"

  `:dispatcher` is the module that called `use Pigeon.Dispatcher`,
  or a `pid` / registered name of a `Pigeon.start_link/1` instance.
  `:topic` defaults to the app's bundle identifier and is required
  by APNS.
  """

  @behaviour Raxol.Watch.Push.Backend

  @compile {:no_warn_undefined, [Pigeon, Pigeon.APNS.Notification]}

  @impl true
  def push(device_token, notification) do
    with {:ok, dispatcher} <- fetch_dispatcher(),
         {:ok, topic} <- fetch_topic(),
         true <- pigeon_loaded?() do
      apns_notification = build_notification(device_token, topic, notification)

      case Pigeon.push(dispatcher, apns_notification) do
        %{response: :success} -> :ok
        %{response: reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      false -> {:error, :pigeon_not_available}
      {:error, _} = err -> err
    end
  end

  defp pigeon_loaded? do
    Code.ensure_loaded?(Pigeon) and Code.ensure_loaded?(Pigeon.APNS.Notification)
  end

  defp fetch_dispatcher do
    case config(:dispatcher) do
      nil -> {:error, :no_apns_dispatcher_configured}
      dispatcher -> {:ok, dispatcher}
    end
  end

  defp fetch_topic do
    case config(:topic) do
      nil -> {:error, :no_apns_topic_configured}
      "" -> {:error, :no_apns_topic_configured}
      topic when is_binary(topic) -> {:ok, topic}
      other -> {:error, {:bad_apns_topic, other}}
    end
  end

  defp config(key) do
    :raxol_watch
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
  end

  defp build_notification(device_token, topic, notification) do
    high? = notification[:priority] == :high

    struct(Pigeon.APNS.Notification,
      device_token: device_token,
      topic: topic,
      priority: if(high?, do: 10, else: 5),
      push_type: "alert",
      payload: build_payload(notification)
    )
  end

  @doc """
  Builds the JSON-shaped APNS payload for a notification.

  Returns a map with the conventional `"aps"` key plus any rich-payload
  fields (`raxol.audio_url`, `raxol.image_url`, `raxol.media_type`,
  `raxol.location`, `raxol.body_long`) at the top level for the host iOS
  app's `UNNotificationServiceExtension` to consume.

  `mutable-content: 1` is set whenever audio or image is present, so the
  host extension knows to fetch the attachment. `interruption-level:
  "time-sensitive"` is set for high-priority notifications (iOS 15+).

  Public so consumers can introspect the payload (e.g. in tests). The
  Pigeon-side `Notification` struct assembly stays private.
  """
  @spec build_payload(map()) :: map()
  def build_payload(%{title: title, body: body} = notif) do
    high? = notif[:priority] == :high

    aps =
      %{
        "alert" => %{"title" => title, "body" => body},
        "badge" => Map.get(notif, :badge, 0),
        "category" => Map.get(notif, :category, "raxol_alert")
      }
      |> maybe_put_sound(high?)
      |> maybe_put_interruption_level(high?)
      |> maybe_put_mutable_content(notif)

    Map.merge(%{"aps" => aps}, build_custom_data(notif))
  end

  defp maybe_put_sound(aps, true), do: Map.put(aps, "sound", "default")
  defp maybe_put_sound(aps, false), do: aps

  defp maybe_put_interruption_level(aps, true),
    do: Map.put(aps, "interruption-level", "time-sensitive")

  defp maybe_put_interruption_level(aps, false), do: aps

  defp maybe_put_mutable_content(aps, notif) do
    if has_media?(notif), do: Map.put(aps, "mutable-content", 1), else: aps
  end

  defp has_media?(notif) do
    is_binary(notif[:audio_url]) or is_binary(notif[:image_url])
  end

  defp build_custom_data(notif) do
    []
    |> maybe_add("raxol.audio_url", notif[:audio_url])
    |> maybe_add("raxol.image_url", notif[:image_url])
    |> maybe_add("raxol.media_type", media_type_string(notif[:media_type]))
    |> maybe_add("raxol.location", notif[:location])
    |> maybe_add_distinct("raxol.body_long", notif[:body_long], notif[:body])
    |> Map.new()
  end

  defp media_type_string(nil), do: nil
  defp media_type_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp maybe_add(acc, _key, nil), do: acc
  defp maybe_add(acc, _key, ""), do: acc
  defp maybe_add(acc, key, value), do: [{key, value} | acc]

  defp maybe_add_distinct(acc, _key, nil, _other), do: acc
  defp maybe_add_distinct(acc, _key, "", _other), do: acc
  defp maybe_add_distinct(acc, _key, same, same), do: acc
  defp maybe_add_distinct(acc, key, value, _other), do: [{key, value} | acc]
end
