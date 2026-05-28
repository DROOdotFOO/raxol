# Speech Surface

`raxol_speech` gives a Raxol app a voice and an ear. TTS announces accessibility events; STT turns spoken words into key/paste events. Both go through the same surface, so a single app can be driven by keyboard, mouse, or voice without app-level changes.

## TTS

```elixir
Raxol.Speech.Speaker.speak("Document saved")
Raxol.Speech.Speaker.stop_speaking()
```

The `Speaker` GenServer subscribes to Accessibility announcements at startup. Anything the framework announces (focus changes, validation errors, status updates) gets spoken automatically if `Speaker` is in the supervision tree. High-priority announcements interrupt current speech.

Backends behind `Raxol.Speech.TTS.Backend`:

- `OsSay`: macOS `say`, Linux `espeak`. Sanitizes input (strips control chars, caps at 10KB).
- `Noop`: swallows speech. Default in test and CI.

Pick a backend in config:

```elixir
config :raxol_speech,
  tts_backend: Raxol.Speech.TTS.OsSay,
  tts_opts: [voice: "Samantha", rate: 200]
```

## STT

Push-to-talk: `start_recording/0` opens the mic, `stop_recording/0` closes it and runs transcription.

```elixir
:ok = Raxol.Speech.Listener.start_recording()
# ... user speaks ...
{:ok, "open file readme"} = Raxol.Speech.Listener.stop_recording()
```

`Listener` captures from the mic via a `sox` Port, bounded by `max_duration_ms` and `max_bytes` (configured at `start_link/1` time, defaults 5 min / 10 MB). `Recognizer` runs Whisper through Bumblebee in a background Task. The two are wired `:rest_for_one`: if Recognizer crashes, Listener restarts with it.

Optional deps: `bumblebee`, `nx`, `exla`. Without them, `Recognizer.recognize/1` returns `{:error, :bumblebee_not_available}`.

## Voice Commands

`InputAdapter` maps transcribed phrases to Raxol events. 20 default phrases ship out of the box (see `InputAdapter.default_commands/0` for the full list):

| Phrase                         | Event                                |
| ------------------------------ | ------------------------------------ |
| "tab" / "next"                 | Tab                                  |
| "previous"                     | Shift+Tab                            |
| "enter"                        | Enter                                |
| "escape"                       | Escape                               |
| "backspace"                    | Backspace                            |
| "up" / "down" / "left" / "right" | Arrow keys                         |
| "page up" / "page down"        | Page Up / Page Down                  |
| "scroll up" / "scroll down"    | `k` / `j`                            |
| "space"                        | Space char                           |
| "yes" / "no" / "help"          | `y` / `n` / `h`                      |
| "quit" / "exit"                | `q`                                  |

Any phrase that is not a recognized command falls through to a `:paste` event with the original text as payload, so dictating prose injects it verbatim.

Custom commands extend the map:

```elixir
config :raxol_speech, :voice_commands, %{
  "save now" => {:key, :ctrl_s},
  "search" => {:focus, "search-input"}
}
```

## Security

`Listener` validates `record_command` against an allowlist before spawning the Port. Don't expose this surface to untrusted networks; the threat model assumes a trusted local user holding a microphone.

## See Also

- [Watch](WATCH.md): the other accessibility-aware surface (push notifications)
- [Accessibility](#): announcements that Speaker subscribes to
