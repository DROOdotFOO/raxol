# Watch Surface

`raxol_watch` pushes glanceable summaries from a Raxol app to iOS or Android devices. Accessibility announcements become notifications; taps come back as Raxol events. It's a low-bandwidth surface for status updates rather than full UI.

## Quick start

```elixir
children = [
  {Raxol.Watch.Supervisor, push_backend: Raxol.Watch.Push.APNS}
]

# APNS/FCM credentials are read by the backend module from its own config.
```

Register a device:

```elixir
# register(device_token, :apns | :fcm, opts)
Raxol.Watch.DeviceRegistry.register("device-token-here", :apns)
Raxol.Watch.DeviceRegistry.register("wear-os-token", :fcm, high_priority_only: true)
```

Supported opts: `muted: false`, `high_priority_only: false`.

When the app announces something via Accessibility, registered devices get a push.

## Push backends

| Backend  | Notes                                |
| -------- | ------------------------------------ |
| `APNS`   | Apple Push Notification service      |
| `FCM`    | Firebase Cloud Messaging (Android)   |
| `Noop`   | Drops sends; logs a warning in prod  |

`pigeon` is the optional dep that powers APNS/FCM. Without it the surface compiles but defaults to `Noop`.

## Debouncing

`Notifier` subscribes to Accessibility events with a 1s debounce. Multiple rapid announcements coalesce into one push, useful when a form change emits five field-validation announcements in 200ms.

High-priority announcements (errors, alerts) bypass the debounce and push immediately.

Parallel send across devices via `Task.async_stream`. Failures log per-device but don't block the others.

## Tap actions

When a user taps a notification, `ActionHandler.handle_action/2` translates the action ID into a `Raxol.Core.Events.Event`. Default mapping:

| Action ID     | Event                                          |
| ------------- | ---------------------------------------------- |
| `details`     | `:key` with `key: :enter`                      |
| `acknowledge` | `:key` with `key: :enter`                      |
| `pause`       | `:key` with `char: " "` (space)                |
| `quit`        | `:key` with `char: "q"`                        |
| `next`        | `:key` with `key: :tab`                        |
| `previous`    | `:key` with `key: :tab, modifiers: [:shift]`   |
| `mute`        | `:custom` with `%{action: :mute}` (W4)         |
| `pin`         | `:custom` with `%{action: :pin}` (W4)          |
| `delete`      | `:custom` with `%{action: :delete}` (W4)       |
| `dismiss`     | `nil` (no event emitted)                       |

Pass `action_map:` to merge in custom bindings:

```elixir
Raxol.Watch.ActionHandler.handle_action("snooze",
  action_map: %{"snooze" => {:key, %{key: :char, char: "s"}}}
)
```

Custom event types beyond `:key` work too: any `{type, data}` where `type` is an atom produces `Event.new(type, data)`.

`Formatter` attaches `details` + `dismiss` to normal notifications,
`acknowledge` + `details` + `dismiss` to high-priority ones, and the full
chat tap-back set (`reply` + `mute` + `pin` + `delete` + `dismiss`) to
chat-style notifications.

## Quick reply (text input)

iOS `UNTextInputNotificationAction` and Android `RemoteInput` prompt the user for text before the action arrives back at the app. `handle_reply_action/3` translates the action ID + typed text into a `:reply` event:

```elixir
event = Raxol.Watch.ActionHandler.handle_reply_action("reply", "Sounds good!")
# %Event{type: :reply, data: %{action: "reply", text: "Sounds good!"}}

# Or dispatch through the configured channel:
Raxol.Watch.ActionHandler.dispatch_reply("reply", "Sounds good!", to: MyApp.TEA)
# Sends {:watch_action, %Event{type: :reply, ...}} to MyApp.TEA
```

Replies use the same `{:watch_action, event}` channel as other tap-backs, so consumers pattern-match on `event.type == :reply` rather than a separate message tag.

## Notification categories

`Raxol.Watch.Categories` returns pure data for the host iOS / Android apps to register at launch:

```elixir
# Host iOS app passes this to UNUserNotificationCenter.setNotificationCategories
ios_payload = Raxol.Watch.Categories.ios_categories()

# Host Android app reads per-category action arrays
chat_actions = Raxol.Watch.Categories.android_actions("raxol_chat")
```

Three category buckets matching the `:category` field on notifications:

| Category        | Actions                                         |
| --------------- | ----------------------------------------------- |
| `raxol_alert`   | Details, Dismiss                                |
| `raxol_status`  | Details, Dismiss                                |
| `raxol_chat`    | Reply (text input), Mute, Pin, Delete, Dismiss  |

Pure data, no platform calls. The host app translates to `UNNotificationCategory` (iOS) or `NotificationCompat.Action` + `RemoteInput` (Android).

## Formatting

`Formatter` truncates the watch-glance `body` to 160 chars (using `String.length`, so emoji count correctly) and maps Raxol priority levels to APNS/FCM priority fields. Buffer content is stripped to plain text; styling doesn't survive the trip.

The full untruncated text is preserved under `:body_long` on every constructor, for the watch detail view that fetches when the user taps "expand".

### Rich notification constructors (W1)

| Constructor             | Carries                                    |
| ----------------------- | ------------------------------------------ |
| `format_announcement/2` | Text-only, priority-based actions          |
| `format_model_summary/2`| Multi-line projection text, status actions |
| `format_audio/4`        | `:audio_url`, chat actions                 |
| `format_image/4`        | `:image_url` + `:media_type` (`:photo` default), chat actions |
| `format_sticker/4`      | Convenience over `format_image/4` with `:media_type => :sticker` |
| `format_location/4`     | `:location => %{lat, lng, label?}`, chat actions |
| `format_long_message/3` | Body truncated to glance, `:body_long` carries full |
| `format_chat_message/3` | Same as `format_long_message/3` but documented for chat use |

Notification fields exposed: `body_long`, `audio_url`, `image_url`, `media_type` (`:sticker | :photo | :video_thumb`), `location`. Existing constructors stay backward-compatible (new fields nil-defaulted).

## APNS payload encoding (W2)

`Raxol.Watch.Push.APNS.build_payload/1` emits the JSON payload with:

- `mutable-content: 1` when `audio_url` or `image_url` is present, so the host iOS app's `UNNotificationServiceExtension` triggers an attachment fetch.
- `interruption-level: "time-sensitive"` and `aps.sound: "default"` for high-priority notifications (iOS 15+, surfaces past Focus modes).
- Custom data at the top level: `raxol.audio_url`, `raxol.image_url`, `raxol.media_type` (atom serialized as string), `raxol.location` (the `{lat, lng, label?}` map), `raxol.body_long` (only when distinct from `body`).

`build_payload/1` is `@doc`-public so consumers can introspect or test the payload shape without Pigeon mocking.

## FCM payload encoding (W3)

`Raxol.Watch.Push.FCM.build_notification_object/1` and `build_data_payload/1` emit the FCM body:

- `notification.image` carries `image_url` (Wear OS auto-downloads).
- `data.category` and JSON-encoded `data.actions` always present.
- `data.raxol_audio_url` (string)
- `data.raxol_media_type` (string)
- `data.raxol_location` (JSON-encoded map; FCM data values must be strings)
- `data.raxol_body_long` (only when distinct from `body`)

The host iOS / Wear OS app downloads the media and renders the notification: `UNNotificationServiceExtension` on iOS, `NotificationCompat` + `BigPictureStyle` / `MessagingStyle` on Android.

## Device registry

`DeviceRegistry` is ETS-backed with `read_concurrency: true`. Crash-safe init means the registry recovers cleanly if the GenServer restarts.

Devices don't expire automatically. Hook `unregister/1` into your auth layer when sessions end.

## See also

- [Telegram](TELEGRAM.md): interactive messaging surface
- [Speech](SPEECH.md): the other accessibility-driven surface
