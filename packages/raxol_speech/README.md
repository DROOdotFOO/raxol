# Raxol Speech

[![Hex.pm](https://img.shields.io/hexpm/v/raxol_speech.svg)](https://hex.pm/packages/raxol_speech)
[![HexDocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/raxol_speech)

Speech surface for Raxol. TTS reads accessibility announcements aloud, STT captures voice input via Bumblebee/Whisper and injects as events.

## Install

```elixir
{:raxol_speech, "~> 0.2"}
```

For speech-to-text, add the optional ML dependencies:

```elixir
{:bumblebee, "~> 0.6"},
{:nx, "~> 0.9"},
{:exla, "~> 0.9"}
```

## Usage

```elixir
# In your supervision tree (TTS only)
children = [
  {Raxol.Speech.Supervisor, tts_backend: Raxol.Speech.TTS.OsSay}
]

# With STT enabled (requires Bumblebee)
children = [
  {Raxol.Speech.Supervisor, enable_stt: true}
]
```

### Text-to-Speech

```elixir
Raxol.Speech.Speaker.speak("Hello world")
Raxol.Speech.Speaker.stop_speaking()
```

The Speaker subscribes to `Raxol.Core.Accessibility` announcements automatically. High-priority announcements interrupt current speech.

### Speech-to-Text

```elixir
Raxol.Speech.Listener.start_recording()
{:ok, text} = Raxol.Speech.Listener.stop_recording()
```

Recognized text is translated to Raxol events via `InputAdapter`. Voice commands like "quit", "up", "scroll down" map to key events.

### Custom TTS backend

Implement the `Raxol.Speech.TTS.Backend` behaviour:

```elixir
@behaviour Raxol.Speech.TTS.Backend

@impl true
def speak(text), do: ...

@impl true
def stop, do: :ok

@impl true
def speaking?, do: false
```

Use `Raxol.Speech.TTS.Noop` for testing. `Raxol.Speech.TTS.Sanitize.strip_control_chars/1` is exposed so custom backends can share the same input contract (C0/C1 control chars stripped, tabs/newlines preserved).

### Telemetry

Attach to these events to observe TTS and STT lifecycle:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:raxol_speech, :tts, :speak, :start]` | `system_time` | `source, backend, byte_size, priority` |
| `[:raxol_speech, :tts, :speak, :stop]` | `duration` | `source, backend, byte_size, priority, result` |
| `[:raxol_speech, :tts, :speak, :exception]` | `duration` | `kind, reason, stacktrace, ...` |
| `[:raxol_speech, :tts, :stopped]` | `%{}` | `source` |
| `[:raxol_speech, :tts, :interrupted]` | `%{}` | `priority, backend` |
| `[:raxol_speech, :recognize, :start]` | `system_time` | `audio_bytes` |
| `[:raxol_speech, :recognize, :stop]` | `duration` | `audio_bytes, success, text` (or `error`) |
| `[:raxol_speech, :listener, :recording, :started]` | `system_time` | `max_duration_ms, max_bytes` |
| `[:raxol_speech, :listener, :recording, :stopped]` | `audio_bytes` | `reason: :explicit \| :max_duration_reached \| :max_bytes_exceeded` |

`source` on `:tts.speak` is `:api` for direct `Speaker.speak/1` calls, `:announcement` for accessibility-driven speech.

### Live test

`examples/speech_demo.exs` exercises TTS + STT on the dev machine. Requires `say` (macOS, built-in) or `espeak`/`espeak-ng` (Linux), plus `sox` on PATH for STT.

```bash
cd packages/raxol_speech
mix run --no-halt examples/speech_demo.exs           # TTS + 3s recording + transcription
SKIP_STT=1 mix run --no-halt examples/speech_demo.exs # TTS only
STT_DURATION_MS=5000 mix run --no-halt examples/speech_demo.exs
```

See [main docs](../../README.md) for the full Raxol framework.

## License

MIT. See [LICENSE.md](LICENSE.md).
