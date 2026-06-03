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

  defp build_notification(device_token, %{title: title, body: body} = notif) do
    high? = notif[:priority] == :high

    actions =
      notif
      |> Map.get(:actions, [])
      |> Enum.map(fn %{id: id, label: label} -> %{"id" => id, "label" => label} end)

    struct(Pigeon.FCM.Notification,
      target: {:token, device_token},
      notification: %{"title" => title, "body" => body},
      android: %{
        "priority" => if(high?, do: "HIGH", else: "NORMAL"),
        "notification" => %{
          "click_action" => Map.get(notif, :category, "raxol_alert")
        }
      },
      data: %{
        "category" => Map.get(notif, :category, "raxol_alert"),
        "actions" => Jason.encode!(actions)
      }
    )
  end
end
