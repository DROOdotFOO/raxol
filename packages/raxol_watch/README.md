# Raxol Watch

[![Hex.pm](https://img.shields.io/hexpm/v/raxol_watch.svg)](https://hex.pm/packages/raxol_watch)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/raxol_watch)

Watch notification bridge for Raxol. Pushes glanceable summaries and accessibility announcements to Apple Watch (APNS) and Wear OS (FCM). Tap actions route back as events to the TEA app.

## What this is for

A 90-day platform digest (HN + GitHub + Reddit) found near-zero developer-facing framework activity in the Apple Watch / Wear OS notification space. Almost everything there is end-user product (mirror apps like WearBridge, complications, custom watch faces) or generic gateways (Prism, ntfy). Server-side push integration that actually understands an application model is unowned.

`raxol_watch` fills that gap. It treats the watch as one more rendering target for a TEA app: model state and accessibility announcements project into platform-appropriate notification payloads. APNS and FCM differences (priority levels, attachment URLs, action categories) are encoded in `Push.Backend` implementations, not pushed onto consumers. Delivery failures auto-prune dead device tokens. Debounced normal-priority pushes respect watch battery; high-priority bypasses debouncing. Telegram's own watch apps (announced 2026-06) ship voice / media / location / chat actions on the device. `raxol_watch` mirrors that capability surface on the server side, so your TEA app's announcements can carry the same payload shapes.

## Install

```elixir
{:raxol_watch, "~> 0.1"}
```

For production push notifications, add:

```elixir
{:pigeon, "~> 2.0"}
```

## Usage

```elixir
# In your supervision tree
children = [
  {Raxol.Watch.Supervisor, push_backend: Raxol.Watch.Push.APNS}
]
```

### Device Registration

```elixir
Raxol.Watch.DeviceRegistry.register("device_token_abc", :apns)
Raxol.Watch.DeviceRegistry.register("device_token_xyz", :fcm, high_priority_only: true)
Raxol.Watch.DeviceRegistry.unregister("device_token_abc")
```

### Sending Notifications

```elixir
# From an accessibility announcement
notification = Raxol.Watch.Formatter.format_announcement("Build failed", :high)
Raxol.Watch.Notifier.push_to_all(notification)

# From model state projections
notification = Raxol.Watch.Formatter.format_model_summary("Dashboard", [
  {"CPU", "42%"},
  {"Memory", "1.2 GB"},
  {"Requests", "847/s"}
])
Raxol.Watch.Notifier.push_to_all(notification)
```

The Notifier also subscribes to `Raxol.Core.Accessibility` announcements automatically. High-priority alerts push immediately; normal alerts are debounced (1 second) to respect watch battery.

### Rich Notification Payloads

Mirroring the watch surface capabilities Telegram shipped on Apple Watch / Wear OS in June 2026, `Formatter` builds notifications with optional voice, image, sticker, location, and long-body attachments. Every constructor preserves the full text under `:body_long` while keeping `:body` truncated to 160 chars for the watch-face glance.

```elixir
# Voice message
Raxol.Watch.Formatter.format_audio("Alice", "Voice message",
  "https://cdn.example.com/voice.m4a")

# Photo or video thumbnail
Raxol.Watch.Formatter.format_image("Build", "Screenshot attached",
  "https://cdn.example.com/build.png", media_type: :photo)

# Sticker
Raxol.Watch.Formatter.format_sticker("Bob", "(sticker)",
  "https://cdn.example.com/sticker.png")

# Geographic location with optional label
Raxol.Watch.Formatter.format_location("Alice", "Meeting spot",
  %{lat: 37.7749, lng: -122.4194, label: "SF"})

# Long-form message
Raxol.Watch.Formatter.format_long_message("Build",
  String.duplicate("...detailed log...", 100))

# Chat-style (long body + chat tap-back actions)
Raxol.Watch.Formatter.format_chat_message("Alice", "Hey, you free?")
```

**APNS encoding (W2).** `Raxol.Watch.Push.APNS.build_payload/1` emits the JSON payload with:

  * `mutable-content: 1` whenever `audio_url` or `image_url` is set, so the host iOS app's `UNNotificationServiceExtension` knows to fetch the attachment.
  * `interruption-level: "time-sensitive"` for high-priority notifications (iOS 15+, surfaces past Focus modes).
  * `aps.sound: "default"` for high priority.
  * Custom data keys at the top level: `raxol.audio_url`, `raxol.image_url`, `raxol.media_type` ("sticker" | "photo" | "video_thumb"), `raxol.location` (the `{lat, lng, label?}` map), `raxol.body_long` (only when distinct from `body`).

**FCM encoding (W3).** `Raxol.Watch.Push.FCM.build_notification_object/1` adds the `image` field to the FCM notification when `image_url` is set (Wear OS auto-downloads). `build_data_payload/1` JSON-encodes the actions list and adds:

  * `raxol_audio_url` (string)
  * `raxol_media_type` (string)
  * `raxol_location` (JSON-encoded map; FCM data values must be strings)
  * `raxol_body_long` (only when distinct from `body`)

The host iOS / Wear OS app is responsible for actually downloading the media and rendering the rich UI. `UNNotificationServiceExtension` on iOS, `NotificationCompat` + `BigPictureStyle` / `MessagingStyle` on Wear OS.

### Chat Tap-Back Actions

The default action map now includes chat-style actions alongside the existing navigation set:

| Action ID | Event type | Data shape |
|-----------|------------|------------|
| `pause`   | `:key`     | `%{key: :char, char: " "}` |
| `details` | `:key`     | `%{key: :enter}` |
| `next`    | `:key`     | `%{key: :tab}` |
| `mute`    | `:custom`  | `%{action: :mute}` |
| `pin`     | `:custom`  | `%{action: :pin}` |
| `delete`  | `:custom`  | `%{action: :delete}` |
| `dismiss` | `nil`      | (no event) |

TEA apps pattern-match on `event.type` and `event.data.action` to handle chat tap-backs. The dispatcher channel (`{:watch_action, event}`) is unchanged so existing handlers keep working.

### Quick-Reply (Text Input)

iOS `UNTextInputNotificationAction` and Android `RemoteInput` prompt the user for text before the action arrives back. `handle_reply_action/3` and `dispatch_reply/3` translate the action ID + typed text into an `:reply` event:

```elixir
# Handler-only (returns the Event):
event = Raxol.Watch.ActionHandler.handle_reply_action("reply", "Sounds good!")
# %Event{type: :reply, data: %{action: "reply", text: "Sounds good!"}}

# Or dispatch through the configured channel:
Raxol.Watch.ActionHandler.dispatch_reply("reply", "Sounds good!", to: MyApp.TEA)
# Sends {:watch_action, %Event{type: :reply, ...}} to MyApp.TEA
```

### Notification Categories

`Raxol.Watch.Categories` exposes the iOS `UNNotificationCategory` and Android notification-action data the host apps need to register at launch. Pure data, no platform calls:

```elixir
# Host iOS app passes this to UNUserNotificationCenter.setNotificationCategories
ios_payload = Raxol.Watch.Categories.ios_categories()

# Host Android app reads per-category action arrays
chat_actions = Raxol.Watch.Categories.android_actions("raxol_chat")
```

Three category buckets matching the `:category` field on notifications: `"raxol_alert"`, `"raxol_status"`, `"raxol_chat"` (with `reply` text-input action).

### Tap Actions

Watch notification actions map back to Raxol events via `ActionHandler`:

```elixir
event = Raxol.Watch.ActionHandler.handle_action("details")
# => Event with key :enter
```

### Custom Push Backend

Implement the `Raxol.Watch.Push.Backend` behaviour. Use `Raxol.Watch.Push.Noop` for testing.

### Telemetry

Attach to these events to observe push lifecycle and device churn:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:raxol_watch, :push, :start]` | `system_time` | `token, platform, priority, backend` |
| `[:raxol_watch, :push, :stop]` | `duration` | `token, platform, priority, backend, result` |
| `[:raxol_watch, :push, :exception]` | `duration` | `kind, reason, stacktrace, ...` |
| `[:raxol_watch, :device, :registered]` | `system_time` | `token, platform, prefs` |
| `[:raxol_watch, :device, :unregistered]` | `system_time` | `token, reason` |
| `[:raxol_watch, :device, :cleared]` | `count` | `%{}` |
| `[:raxol_watch, :notifier, :coalesced]` | `count: 1` | `priority` |

`reason` on `:unregistered` is `:explicit` for user-driven removal and `:delivery_failed` when the Notifier auto-prunes a device after a permanent APNS/FCM error.

### Auto-prune on Delivery Failure

When the push backend returns a permanent failure reason (APNS: `:bad_device_token`, `:device_token_not_for_topic`, `:unregistered`, `:expired_token`; FCM: `:invalid_argument`, `:sender_id_mismatch`), the Notifier automatically unregisters the device. Transient failures (`:too_many_requests`, `:internal_server_error`, etc.) leave the device registered.

### Tap-back Dispatch

`ActionHandler.handle_action/2` returns an `Event` but does not route it. Use `ActionHandler.dispatch/2` to forward the Event to a TEA process:

```elixir
# Send {:watch_action, event} to a pid or registered name:
Raxol.Watch.ActionHandler.dispatch("details", to: MyApp.TEA)

# Or invoke a callback:
Raxol.Watch.ActionHandler.dispatch("details", to: fn ev -> MyApp.handle(ev) end)

# Or configure a default app-wide:
Application.put_env(:raxol_watch, :action_dispatcher, MyApp.TEA)
Raxol.Watch.ActionHandler.dispatch("details")
```

### Live Testing on Apple Watch

Apple Watch hardware can't run BEAM. Pushes go via APNS to the paired iPhone, which mirrors notifications to the watch per the user's iOS Watch settings. Confirmed paths against watchOS 10.4 (Series 4 / A2094).

See [`examples/watch_demo.exs`](examples/watch_demo.exs) for an end-to-end runner that wires up Pigeon, registers a device token, and emits both a debounced normal-priority announcement and an immediate high-priority one.

Prerequisites: Apple Developer account, App ID + bundle identifier, APNs Auth Key (`.p8`) + Key ID + Team ID, and a device token captured from a paired iPhone app that called `registerForRemoteNotifications`.

### APNS Configuration

The APNS backend uses Pigeon 2.x dispatchers. In your app, define a dispatcher module and wire it via app env:

```elixir
defmodule MyApp.APNS do
  use Pigeon.Dispatcher, otp_app: :my_app
end

# Tell raxol_watch which dispatcher to use:
config :raxol_watch, Raxol.Watch.Push.APNS,
  dispatcher: MyApp.APNS,
  topic: "io.example.app"   # your bundle identifier

# Pigeon's own config for the dispatcher:
config :my_app, MyApp.APNS,
  adapter: Pigeon.APNS,
  key: File.read!("AuthKey_ABC1234567.p8"),
  key_identifier: "ABC1234567",
  team_id: "DEF8901234",
  mode: :dev   # :prod for App Store / TestFlight builds
```

See [main docs](../../README.md) for the full Raxol framework.

## License

MIT. See [LICENSE.md](LICENSE.md).
