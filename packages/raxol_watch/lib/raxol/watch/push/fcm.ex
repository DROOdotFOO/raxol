defmodule Raxol.Watch.Push.FCM do
  @moduledoc """
  Firebase Cloud Messaging backend via Pigeon 2.x.

  Pigeon 2.x requires consumers to define an FCM dispatcher module
  (`use Pigeon.Dispatcher, otp_app: :your_app`) and a Goth worker for
  service-account auth. This backend forwards to a configured
  dispatcher via `Pigeon.push/3`.

  ## Configuration

      config :raxol_watch, Raxol.Watch.Push.FCM,
        dispatcher: MyApp.FCM
  """

  @behaviour Raxol.Watch.Push.Backend

  @compile {:no_warn_undefined, [Pigeon, Pigeon.FCM.Notification]}

  @impl true
  def push(device_token, notification) do
    with {:ok, dispatcher} <- fetch_dispatcher(),
         true <- pigeon_loaded?() do
      fcm_notification = build_notification(device_token, notification)

      case Pigeon.push(dispatcher, fcm_notification) do
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
    Code.ensure_loaded?(Pigeon) and Code.ensure_loaded?(Pigeon.FCM.Notification)
  end

  defp fetch_dispatcher do
    case :raxol_watch
         |> Application.get_env(__MODULE__, [])
         |> Keyword.get(:dispatcher) do
      nil -> {:error, :no_fcm_dispatcher_configured}
      dispatcher -> {:ok, dispatcher}
    end
  end

  defp build_notification(device_token, notif) do
    high? = notif[:priority] == :high

    struct(Pigeon.FCM.Notification,
      target: {:token, device_token},
      notification: build_notification_object(notif),
      android: %{
        "priority" => if(high?, do: "HIGH", else: "NORMAL"),
        "notification" => %{
          "click_action" => Map.get(notif, :category, "raxol_alert")
        }
      },
      data: build_data_payload(notif)
    )
  end

  @doc """
  Builds the FCM `notification` object: `title`, `body`, and `image` when
  the notification carries an `image_url`. FCM auto-downloads the image
  on Wear OS notifications.

  Public so consumers can introspect the payload; tests use it to assert
  shape without Pigeon mocking.
  """
  @spec build_notification_object(map()) :: map()
  def build_notification_object(%{title: title, body: body} = notif) do
    base = %{"title" => title, "body" => body}

    case notif[:image_url] do
      nil -> base
      "" -> base
      url when is_binary(url) -> Map.put(base, "image", url)
    end
  end

  @doc """
  Builds the FCM `data` payload. Always carries `category` and `actions`
  (JSON-encoded list of `{id, label}` maps). Optionally adds
  `raxol_audio_url`, `raxol_media_type`, `raxol_location` (JSON-encoded
  `{lat, lng, label?}` map), and `raxol_body_long`.

  All FCM data values must be strings, so the location map is JSON-encoded
  for the host Wear OS app to parse.
  """
  @spec build_data_payload(map()) :: %{required(String.t()) => String.t()}
  def build_data_payload(notif) do
    actions =
      notif
      |> Map.get(:actions, [])
      |> Enum.map(fn %{id: id, label: label} -> %{"id" => id, "label" => label} end)

    %{
      "category" => Map.get(notif, :category, "raxol_alert"),
      "actions" => Jason.encode!(actions)
    }
    |> maybe_put_string("raxol_audio_url", notif[:audio_url])
    |> maybe_put_string("raxol_media_type", media_type_string(notif[:media_type]))
    |> maybe_put_json("raxol_location", notif[:location])
    |> maybe_put_distinct_string("raxol_body_long", notif[:body_long], notif[:body])
  end

  defp media_type_string(nil), do: nil
  defp media_type_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp maybe_put_string(map, _key, nil), do: map
  defp maybe_put_string(map, _key, ""), do: map
  defp maybe_put_string(map, key, value) when is_binary(value), do: Map.put(map, key, value)

  defp maybe_put_json(map, _key, nil), do: map
  defp maybe_put_json(map, key, value), do: Map.put(map, key, Jason.encode!(value))

  defp maybe_put_distinct_string(map, _key, nil, _other), do: map
  defp maybe_put_distinct_string(map, _key, "", _other), do: map
  defp maybe_put_distinct_string(map, _key, same, same), do: map

  defp maybe_put_distinct_string(map, key, value, _other) when is_binary(value),
    do: Map.put(map, key, value)
end
