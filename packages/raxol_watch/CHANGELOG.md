# Changelog

All notable changes to `raxol_watch` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-21

### Added

- `Raxol.Watch.ActionHandler.dispatch/2` -- routes a tap action's resulting
  `Event` to a configured dispatcher (pid, registered atom name, `{mod, fun}`,
  `{mod, fun, extra_args}`, or 1-arity function). Falls back to
  `Application.get_env(:raxol_watch, :action_dispatcher)` when `:to` is not
  passed. Returns `{:ok, event}` / `{:ok, nil}` / `{:error, reason, event}`.
- `Raxol.Watch.DeviceRegistry.clear_all/0` -- removes every registered
  device. Useful on user logout, and to reset state between tests.
- `Raxol.Watch.DeviceRegistry.unregister/2` -- the new optional `reason`
  argument is forwarded to telemetry. Defaults to `:explicit`. The Notifier
  uses `:delivery_failed` when auto-pruning after a permanent APNS/FCM error.
- **Auto-prune** on permanent delivery failures. When a push backend returns
  `:bad_device_token`, `:device_token_not_for_topic`, `:unregistered`,
  `:expired_token` (APNS), `:invalid_argument`, or `:sender_id_mismatch`
  (FCM), the Notifier automatically unregisters the device so subsequent
  pushes don't waste cycles on dead tokens. Transient errors
  (`:too_many_requests`, `:internal_server_error`, etc.) leave the device
  registered.
- **Telemetry events** (`telemetry` is now an explicit dependency):
  - `[:raxol_watch, :push, :start | :stop | :exception]` -- `:telemetry.span`
    around each per-device push. Metadata: `%{token, platform, priority,
    backend, result}`. Result is `:ok` or `{:error, reason}`.
  - `[:raxol_watch, :device, :registered]` -- on register. Metadata:
    `%{token, platform, prefs}`.
  - `[:raxol_watch, :device, :unregistered]` -- on unregister. Metadata:
    `%{token, reason}` where reason is `:explicit | :delivery_failed`.
  - `[:raxol_watch, :device, :cleared]` -- on `clear_all/0`. Measurements:
    `%{count}`.
  - `[:raxol_watch, :notifier, :coalesced]` -- when a normal-priority
    announcement replaces a pending debounced one. Metadata: `%{priority}`.
- `examples/watch_demo.exs` -- end-to-end live-test harness targeting a real
  paired iPhone + Apple Watch via APNS (designed against Series 4 / Model
  A2094 / watchOS 10.4).

### Changed

- **Breaking:** `Raxol.Watch.Push.APNS` and `Raxol.Watch.Push.FCM` now require
  a Pigeon 2.x dispatcher configured via app env. The old code called
  `Pigeon.APNS.push/1` / `Pigeon.FCM.push/1`, which do not exist in Pigeon 2.0
  -- the backends were non-functional. Configure with:

  ```elixir
  config :raxol_watch, Raxol.Watch.Push.APNS,
    dispatcher: MyApp.APNS,
    topic: "io.example.app"
  ```

  Returns `{:error, :no_apns_dispatcher_configured}`,
  `{:error, :no_apns_topic_configured}`, or
  `{:error, :no_fcm_dispatcher_configured}` when misconfigured. Empty-string
  topics now also fail with `:no_apns_topic_configured` (previously slipped
  past `is_binary/1` and produced a confusing downstream APNS error).

### Docs

- Reconcile `docs/features/WATCH.md` with the actual
  `DeviceRegistry.register/3` signature and the real `ActionHandler`
  default action map.

### Tests

- 51 example tests + 23 properties (StreamData), 0 failures. New coverage:
  Push.APNS / Push.FCM error paths, ActionHandler.dispatch dispatch
  variants, Formatter truncation invariants, DeviceRegistry round-trip
  properties, telemetry event emission, and auto-prune coverage for all
  six permanent failure reasons plus the transient-no-prune path.

## [0.1.0] - 2026-04-27

Initial release. Watch surface package for Raxol.

### Added

- `Raxol.Watch.Notifier` -- GenServer that subscribes to
  `Raxol.Core.Accessibility` announcements and pushes to all registered
  devices. 1-second debounce for normal-priority alerts; high-priority
  announcements bypass the debounce. Parallel push via `Task.async_stream`
  with per-device failure logging.
- `Raxol.Watch.DeviceRegistry` -- ETS-backed device registry with
  `read_concurrency: true`. Crash-safe init (re-uses existing table on
  restart). Supports per-device `high_priority_only` preference.
- `Raxol.Watch.Formatter` -- builds notification payloads from accessibility
  announcements and model-state projections. 160-character truncation via
  `String.length` (grapheme-aware). Maps Raxol priority to push priority.
- `Raxol.Watch.ActionHandler` -- maps watch tap actions back to Raxol events.
  Tap routes to `:enter`; "previous" maps to shift+tab.
- `Raxol.Watch.Push.Backend` -- behaviour for push backends.
- `Raxol.Watch.Push.APNS` -- Apple Push Notification Service backend (uses
  optional `pigeon` dependency).
- `Raxol.Watch.Push.FCM` -- Firebase Cloud Messaging backend for Wear OS
  (uses optional `pigeon` dependency).
- `Raxol.Watch.Push.Noop` -- no-op backend for tests; logs a warning if
  configured in `:prod`.
- `Raxol.Watch.Supervisor` -- `:rest_for_one` supervisor wiring
  DeviceRegistry and Notifier (Notifier depends on the registry being up).

### Notes

- 34 tests, 0 failures.
- Real push delivery requires the optional `pigeon` dependency to be added
  by the consumer. The default `Raxol.Watch.Push.Noop` backend works
  without any optional deps and is suitable for tests.
