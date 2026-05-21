# Raxol Watch

[![Hex.pm](https://img.shields.io/hexpm/v/raxol_watch.svg)](https://hex.pm/packages/raxol_watch)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/raxol_watch)

Watch notification bridge for Raxol. Pushes glanceable summaries and accessibility announcements to Apple Watch (APNS) and Wear OS (FCM). Tap actions route back as events to the TEA app.

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
