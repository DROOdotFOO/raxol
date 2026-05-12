# Speech Surface

`raxol_speech` gives a Raxol app a voice and an ear. TTS announces accessibility events; STT turns spoken words into key/paste events. Both go through the same surface, so a single app can be driven by keyboard, mouse, or voice without app-level changes.

## TTS

```elixir
Raxol.Speech.Speaker.say("Document saved")
```

The `Speaker` GenServer subscribes to Accessibility announcements at startup. Anything the framework announces (focus changes, validation errors, status updates) gets spoken automatically if `Speaker` is in the supervision tree.

Backends behind `Raxol.Speech.TTS.Backend`:

- `OsSay` -- macOS `say`, Linux `espeak`. Sanitizes input (strips control chars, caps at 10KB).
- `Noop` -- swallows speech. Default in test and CI.

Pick a backend in config:

```elixir
config :raxol_speech,
  tts_backend: Raxol.Speech.TTS.OsSay,
  tts_opts: [voice: "Samantha", rate: 200]
```

## STT

```elixir
Raxol.Speech.Listener.listen(max_duration_ms: 5000)
# ... user speaks ...
# Returns {:ok, "open file readme"} when transcription completes
```

`Listener` captures from the mic via a `sox` Port, bounded by `max_duration` and `max_bytes`. `Recognizer` runs Whisper through Bumblebee in a background Task. The two are wired `:rest_for_one` -- if Recognizer crashes, Listener restarts with it.

Optional deps: `bumblebee`, `nx`, `exla`. Without them, STT is a no-op.

## Voice Commands

`InputAdapter` maps transcribed phrases to Raxol events. 21 default commands ship out of the box:

| Phrase         | Event                            |
| -------------- | -------------------------------- |
| "tab"          | Tab key                          |
| "enter"        | Enter key                        |
| "escape"       | Escape key                       |
| "up", "down"   | Arrow keys                       |
| "page up"      | Page Up                          |
| "paste"        | Paste from clipboard             |
| "type X"       | Paste `X` as text                |

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

- [Watch](WATCH.md) -- the other accessibility-aware surface (push notifications)
- [Accessibility](#) -- announcements that Speaker subscribes to
