# Recording & Replay

Record terminal sessions to asciinema v2 `.cast` files. Play them back with pause, seek, and speed controls. If your app crashes mid-recording, the session auto-saves so you can see what happened.

## Quick start

```bash
mix raxol.record my_session.cast
mix raxol.replay my_session.cast
```

## Recorder

`Raxol.Recording.Recorder` captures output and input events with timestamps. The rendering engine and dispatcher call into it automatically while it's running.

```elixir
{:ok, _} = Raxol.Recording.Recorder.start_link()

# These are typically called by the framework, not by you:
Raxol.Recording.Recorder.record_output(data)
Raxol.Recording.Recorder.record_input(data)

Raxol.Recording.Recorder.active?()  # => true

session = Raxol.Recording.Recorder.get_session()  # peek without stopping
session = Raxol.Recording.Recorder.stop()          # stop and get the session
```

## Player

`Raxol.Recording.Player` replays a `.cast` file or session struct:

```elixir
Raxol.Recording.Player.play("my_session.cast", speed: 2.0, max_delay: 5.0)
Raxol.Recording.Player.play(session, interactive: true)
```

Keyboard controls during playback:

| Key         | Action                          |
| ----------- | ------------------------------- |
| `space`     | Pause / resume                  |
| `+` / `=`   | Speed up (1x -> 2x -> 4x -> 8x) |
| `-`         | Slow down                       |
| `>` / `.`   | Skip forward 5s                 |
| `<` / `,`   | Skip backward 5s                |
| `0`-`9`     | Jump to 0%-90%                  |
| `q` / `ESC` | Quit                            |

Options: `:speed` (default 1.0), `:max_delay` (default 5.0s cap between events), `:interactive` (default true).

## Asciicast v2 Format

`Raxol.Recording.Asciicast` reads and writes the standard asciinema v2 format:

```elixir
alias Raxol.Recording.Asciicast

Asciicast.write!(session, "output.cast")

{:ok, session} = Asciicast.read("output.cast")
session = Asciicast.read!("output.cast")

# String encode/decode
cast_string = Asciicast.encode(session)
session = Asciicast.decode(cast_string)
```

The format is a JSON header followed by newline-delimited event arrays:

```
{"version": 2, "width": 80, "height": 24, "timestamp": 1234567890}
[0.5, "o", "Hello"]
[1.2, "o", " World\r\n"]
```

Upload `.cast` files to [asciinema.org](https://asciinema.org) to share them.

## Programmatic usage

```elixir
{:ok, _} = Raxol.Recording.Recorder.start_link()

# ... run your app ...

session = Raxol.Recording.Recorder.stop()
Raxol.Recording.Asciicast.write!(session, "debug_session.cast")

Raxol.Recording.Player.play("debug_session.cast")
```

On crash, the current session is saved automatically. No explicit stop needed for post-mortem.
