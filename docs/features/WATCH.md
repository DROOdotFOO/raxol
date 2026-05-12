# Watch Surface

`raxol_watch` pushes glanceable summaries from a Raxol app to iOS or Android devices. Accessibility announcements become notifications; taps come back as Raxol events. It's a low-bandwidth surface for status updates rather than full UI.

## Quick Start

```elixir
config :raxol_watch,
  push_backend: Raxol.Watch.Push.APNS,
  push_opts: [key_id: "ABC", team_id: "XYZ", topic: "io.example.app"]

children = [
  Raxol.Watch.Supervisor
]
```

Register a device:

```elixir
Raxol.Watch.DeviceRegistry.register("user-123", %{
  platform: :apns,
  token: "device-token-here"
})
```

When the app announces something via Accessibility, registered devices get a push.

## Push Backends

| Backend  | Notes                                |
| -------- | ------------------------------------ |
| `APNS`   | Apple Push Notification service      |
| `FCM`    | Firebase Cloud Messaging (Android)   |
| `Noop`   | Drops sends; logs a warning in prod  |

`pigeon` is the optional dep that powers APNS/FCM. Without it the surface compiles but defaults to `Noop`.

## Debouncing

`Notifier` subscribes to Accessibility events with a 1s debounce. Multiple rapid announcements coalesce into one push -- useful when a form change emits five field-validation announcements in 200ms.

High-priority announcements (errors, alerts) bypass the debounce and push immediately.

Parallel send across devices via `Task.async_stream`. Failures log per-device but don't block the others.

## Tap Actions

When a user taps a notification, `ActionHandler` translates the action into a Raxol event:

| Action         | Event                  |
| -------------- | ---------------------- |
| Default tap    | Focus the announced Component |
| "Approve"      | Click the linked button    |
| "Dismiss"      | Send `:dismiss` message    |
| Shift+Tab      | "Previous" navigation      |

Actions are declared per notification via accessibility metadata.

## Formatting

`Formatter` truncates content to 160 chars (using `String.length`, so emoji are counted correctly) and maps Raxol priority levels to APNS/FCM priority fields. Buffer content is stripped to plain text -- styling doesn't survive the trip.

## Device Registry

`DeviceRegistry` is ETS-backed with `read_concurrency: true`. Crash-safe init means the registry recovers cleanly if the GenServer restarts.

Devices don't expire automatically. Hook `unregister/1` into your auth layer when sessions end.

## See Also

- [Telegram](TELEGRAM.md) -- richer messaging surface
- [Speech](SPEECH.md) -- the other accessibility-driven surface
