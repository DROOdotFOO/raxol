# Changelog

All notable changes to `raxol_speech` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-05-21

### Added

- `Raxol.Speech.TTS.Sanitize.strip_control_chars/1` -- public sanitization
  helper for custom TTS backends. Previously a private function inside
  `OsSay`. Strips C0/C1 control chars while preserving tabs and newlines.
- `examples/speech_demo.exs` -- live-test harness covering TTS + STT on the
  dev machine. Requires `say`/`espeak` for TTS and `sox` for STT.
- **Telemetry events** (`telemetry` is now an explicit dependency):
  - `[:raxol_speech, :tts, :speak, :start | :stop | :exception]` --
    `:telemetry.span` around each Speaker speak call. Metadata:
    `%{source, backend, byte_size, priority, result}`. `source` is
    `:api` for direct `Speaker.speak/1` calls and `:announcement` for
    accessibility-driven speech.
  - `[:raxol_speech, :tts, :stopped]` -- on `Speaker.stop_speaking/0`.
  - `[:raxol_speech, :tts, :interrupted]` -- when a high-priority
    announcement preempts current speech. Metadata: `%{priority, backend}`.
  - `[:raxol_speech, :recognize, :start | :stop | :exception]` --
    `:telemetry.span` around Whisper transcription. Metadata:
    `%{audio_bytes, success, text, error}`.
  - `[:raxol_speech, :listener, :recording, :started | :stopped]` --
    discrete events for mic capture lifecycle. Stop reason is one of
    `:explicit | :max_duration_reached | :max_bytes_exceeded`.

### Changed

- **Breaking:** the Recognizer telemetry event has moved from
  `[:raxol, :speech, :recognized]` (single event) to a proper
  `:telemetry.span` under `[:raxol_speech, :recognize]`. Consumers
  attaching to the old event name must update their handlers and switch
  to the `:start`/`:stop`/`:exception` triple. Metadata key `text` and
  `success` are unchanged; new keys are `audio_bytes` and (on error)
  `error`.

### Docs

- Reconcile `docs/features/SPEECH.md` with the actual API:
  `Speaker.speak/1` (not `say`), `Listener.start_recording/0` +
  `stop_recording/0` (not `listen/1`), and the real default voice command
  table (no `"paste"` / `"type X"` -- the fallback `:paste` event covers
  arbitrary phrases).

### Tests

- 36 example tests + 14 properties (StreamData), 0 failures. New coverage:
  Speaker priority-interrupt call order, Speaker telemetry, Sanitize
  invariants over UTF-8 inputs, InputAdapter merge / normalization
  properties.

## [0.1.0] - 2026-04-27

Initial release. Speech surface package for Raxol.

### Added

- `Raxol.Speech.Speaker` -- text-to-speech GenServer that subscribes to
  `Raxol.Core.Accessibility` announcements and speaks them aloud. High-priority
  announcements interrupt current speech.
- `Raxol.Speech.TTS.Backend` -- behaviour for TTS implementations.
- `Raxol.Speech.TTS.OsSay` -- macOS `say` / Linux `espeak` backend with text
  sanitization (control char stripping, 10KB max input).
- `Raxol.Speech.TTS.Noop` -- no-op backend for tests and headless environments.
- `Raxol.Speech.Recognizer` -- speech-to-text via Bumblebee/Whisper. Async
  Task-based transcription. Optional dependency on `bumblebee`, `nx`, `exla`.
- `Raxol.Speech.Listener` -- microphone capture via `sox` Port. Bounded by
  `max_duration` and `max_bytes`. Validates `record_command` against an
  allowlist.
- `Raxol.Speech.InputAdapter` -- translates recognized text into Raxol events.
  Ships with 21 default voice commands (e.g. "quit", "up", "scroll down").
- `Raxol.Speech.Supervisor` -- `:rest_for_one` supervisor wiring Speaker,
  Recognizer, and Listener so Listener depends on Recognizer being healthy.

### Notes

- 28 tests, 0 failures.
- STT requires the optional `bumblebee`, `nx`, and `exla` dependencies to be
  added by the consumer. TTS works without any optional deps.
