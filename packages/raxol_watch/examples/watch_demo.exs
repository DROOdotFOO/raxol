#
# Live-test harness for Apple Watch (e.g. Series 4 / Model A2094 / watchOS 10.4).
#
# Watch hardware can't run BEAM. Pushes go to APNS, target the paired iPhone's
# app by bundle topic, and the iPhone mirrors notifications to the watch per
# its iOS Watch app settings.
#
# What you need before running:
#   1. An Apple Developer account + an App ID (bundle identifier).
#   2. An APNs Auth Key (.p8) and its 10-char Key ID.
#   3. Your 10-char Team ID.
#   4. An iOS app installed on the iPhone paired with the watch that:
#      - Is signed with the matching bundle ID.
#      - Calls registerForRemoteNotifications and prints the device token
#        (64-hex-chars). Apple's "Sandbox" sample, or any minimal SwiftUI
#        app, works.
#   5. The device token from step 4, captured from Xcode console.
#
# Then:
#
#   cd packages/raxol_watch
#   APNS_KEY_PATH=/abs/path/to/AuthKey_ABC1234567.p8 \
#   APNS_KEY_ID=ABC1234567 \
#   APNS_TEAM_ID=DEF8901234 \
#   APNS_TOPIC=io.example.app \
#   APNS_DEVICE_TOKEN=<hex device token> \
#   APNS_MODE=dev \
#   mix run --no-halt examples/watch_demo.exs
#
# APNS_MODE defaults to :dev (sandbox APNS host) which pairs with an app
# built via Xcode debug. Use :prod only for TestFlight/App Store builds.
#

require Logger

defmodule WatchDemo do
  @env_vars ~w(APNS_KEY_PATH APNS_KEY_ID APNS_TEAM_ID APNS_TOPIC APNS_DEVICE_TOKEN)

  def run do
    with :ok <- check_env(),
         :ok <- check_pigeon(),
         {:ok, key_contents} <- read_key(),
         :ok <- configure(key_contents),
         {:ok, _sup} <- start_supervision_tree() do
      DeviceRegistry.register(System.get_env("APNS_DEVICE_TOKEN"), :apns)

      Logger.info(
        "Registered device #{redact(System.get_env("APNS_DEVICE_TOKEN"))} on APNS topic #{System.get_env("APNS_TOPIC")} (mode=#{System.get_env("APNS_MODE", "dev")})."
      )

      sleep(:settle)
      push_normal()
      sleep(:between)
      push_high()
      sleep(:final)

      :ok
    else
      {:error, :missing_env, missing} ->
        die("Missing required env vars: #{Enum.join(missing, ", ")}. See the header of this file for setup instructions.")

      {:error, :pigeon_not_available} ->
        die("Pigeon is not loaded. Run `mix deps.get` in packages/raxol_watch.")

      {:error, {:key_read_failed, reason}} ->
        die("Failed to read APNs key at #{System.get_env("APNS_KEY_PATH")}: #{inspect(reason)}")

      {:error, reason} ->
        die("Demo failed to start: #{inspect(reason)}")
    end
  end

  defp die(message) do
    IO.puts(:stderr, "watch_demo: " <> message)
    System.halt(1)
  end

  defp check_env do
    case Enum.reject(@env_vars, &(System.get_env(&1) not in [nil, ""])) do
      [] -> :ok
      missing -> {:error, :missing_env, missing}
    end
  end

  defp check_pigeon do
    if Code.ensure_loaded?(Pigeon.Dispatcher) and Code.ensure_loaded?(Pigeon.APNS) do
      :ok
    else
      {:error, :pigeon_not_available}
    end
  end

  defp read_key do
    case File.read(System.get_env("APNS_KEY_PATH")) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:key_read_failed, reason}}
    end
  end

  defp configure(key_contents) do
    mode =
      case System.get_env("APNS_MODE", "dev") do
        "prod" -> :prod
        _ -> :dev
      end

    Application.put_env(:raxol_watch, WatchDemo.APNS,
      adapter: Pigeon.APNS,
      key: key_contents,
      key_identifier: System.get_env("APNS_KEY_ID"),
      team_id: System.get_env("APNS_TEAM_ID"),
      mode: mode
    )

    Application.put_env(:raxol_watch, Raxol.Watch.Push.APNS,
      dispatcher: WatchDemo.APNS,
      topic: System.get_env("APNS_TOPIC")
    )

    :ok
  end

  defp start_supervision_tree do
    children = [
      WatchDemo.APNS,
      {Raxol.Watch.Supervisor, push_backend: Raxol.Watch.Push.APNS}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: WatchDemo.Supervisor)
  end

  defp push_normal do
    Logger.info("Sending normal-priority announcement (will debounce 1s)...")

    send(
      Raxol.Watch.Notifier,
      {:announcement_added, make_ref(),
       %{message: "Build queued: feature/watch-demo", priority: :medium}}
    )
  end

  defp push_high do
    Logger.info("Sending HIGH-priority announcement (bypasses debounce)...")

    send(
      Raxol.Watch.Notifier,
      {:announcement_added, make_ref(),
       %{message: "Build FAILED on feature/watch-demo (3 errors)", priority: :high}}
    )
  end

  # First sleep covers Pigeon HTTP/2 handshake + APNS TLS setup.
  defp sleep(:settle), do: Process.sleep(2_000)
  # Between sleep covers debounce window + APNS round-trip for the normal push.
  defp sleep(:between), do: Process.sleep(3_000)
  # Final sleep gives APNS time to deliver the high-priority push before exit.
  defp sleep(:final), do: Process.sleep(5_000)

  defp redact(<<head::binary-size(6), _rest::binary>>), do: head <> "..."
  defp redact(other), do: inspect(other)
end

alias Raxol.Watch.DeviceRegistry

# Define the Pigeon dispatcher module up here at the top level. `use` macros
# must run at compile time of the script, which is before WatchDemo.run/0.
defmodule WatchDemo.APNS do
  use Pigeon.Dispatcher, otp_app: :raxol_watch
end

WatchDemo.run()
