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

  defp build_notification(device_token, topic, %{title: title, body: body} = notif) do
    high? = notif[:priority] == :high

    aps =
      %{
        "alert" => %{"title" => title, "body" => body},
        "badge" => Map.get(notif, :badge, 0),
        "category" => Map.get(notif, :category, "raxol_alert")
      }
      |> maybe_put_sound(high?)

    %Pigeon.APNS.Notification{
      device_token: device_token,
      topic: topic,
      priority: if(high?, do: 10, else: 5),
      push_type: "alert",
      payload: %{"aps" => aps}
    }
  end

  defp maybe_put_sound(aps, true), do: Map.put(aps, "sound", "default")
  defp maybe_put_sound(aps, false), do: aps
end
