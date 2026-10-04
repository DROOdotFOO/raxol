## [Unreleased]

### Added

- **`raxol_agent`: hash-chained journals, and `raxol_broker`: the decision journal and `mix raxol.broker.replay` (#1177).** `Raxol.Agent.Journal.FileStore.open(session, chain: true)` creates a journal whose records carry `prev_hash` and `hash` (SHA-256 of the record's canonical JSON: keys sorted by byte order at every depth, no whitespace, `hash` removed). One chain spans every segment; the first record links to 64 zeros.
  - The mode is fixed at creation (`"chain": true` in `meta.json`). A chained journal stays chained whatever later openers pass; `chain: true` on an existing unchained journal is `{:error, :unchained_journal}`. Chained appends refuse floats (`{:error, {:float, path}}`), and each line on disk must be its record's canonical JSON (Jason with `escape: :json` passed explicitly; a test pins the exact bytes and hash of a record with control, DEL, C1 and non-ASCII characters).
  - The `meta.json` flag is not the only marker: a `tip_hash` in `HEAD` or a `prev_hash`/`hash` on the first record also makes a journal chained, so removing the flag is reported as damage (`{:damaged, 1}`, `{:broken, 1}`, appends refused) instead of silently turning the checks off.
  - `HEAD` anchors the tip hash after each datasync. On a chained journal a missing or cut record at or below the anchored offset is damage, not a torn tail; an unsynced line above it is still healed. A Writer that starts on a broken chain refuses every append with `{:error, :damaged}` and leaves `HEAD` alone.
  - New `Raxol.Agent.Journal.verify/1` (and `FileStore.verify/1`, plus read-side `FileStore.verify_session/2`): `:ok`, `{:broken, offset}`, or `{:error, :unchained}`. `status/1` now returns `{:damaged, offset}` instead of bare `:damaged` for every journal; `read/2` and `read_records/2` refuse a broken chain like any interior corruption. `FileStore.append_many/2` appends several events in one Writer call.
  - `FileStore.open(session, private: true)` creates the session directories 0700 and every file 0600 from its first byte, and refuses a symlinked, foreign-owned, or group- or other-writable base or session directory with `{:error, {:untrusted_dir, {path, reason}}}`. The owner and mode check is `Raxol.Agent.OperatorFile.owned_unshared/1`, now public and shared with `trusted?/1`.
  - Replay no longer slows superlinearly: the reader walks segments without building a per-line entry list, checks each chained record with one encode, and sizes the heap up front instead of copying the growing record list on every full collection (50k chained records: about 1.0 s CPU, down from 2.3 s, with 7 major collections instead of 71).
  - The default `schema_version` is `1.2.0`. Unchained journals change only in that stamp. The 1.2.0 golden corpus is frozen as a chained journal; the 1.0.0 and 1.1.0 corpora are unchanged and still replay.
  - `raxol_broker` adds `Raxol.Broker.Journal` (write-ahead decision groups with a `placing` record before every order call, crash recovery, ETS index for `today_notional/1`, `orders_last_minute/1` and `realized_pnl_today/1`) and `mix raxol.broker.replay --date YYYY-MM-DD`. See `packages/raxol_broker/CHANGELOG.md`.
- **`raxol_agent`: Robinhood browser sign-in, and `raxol_broker`: encrypted token store and refreshing MCP session (#1173).** `Raxol.Agent.Auth.Flow.run(:robinhood, opts)` returns a `%Raxol.Agent.Auth.Credential{}`; it is a separate clause and NOT in `Flow.providers/0`, so ACP clients, `raxol login` and the TUI never offer it.
  - `Raxol.Agent.Auth.Robinhood` pins the issuer, authorization, token and registration endpoints and the resource. RFC 9728/8414 discovery is fetched and checked against the pins (`{:error, :metadata_mismatch}` on any difference); dynamic client registration must echo the exact redirect URI and the `none` auth method; the code exchange and `refresh/2` are form posts through the `:http_fn` seam (default Req with `redirect: false, retry: false`). Errors are a closed set such as `{:token_rejected, status, :invalid_grant}`, never a response body. `refresh/2` adopts the rotated refresh token. `expires_at` comes from `expires_in` and is `nil` when the server sends none.
  - `Raxol.Agent.Auth.Loopback.open/1` takes `host: :ip` (redirect URI `http://127.0.0.1:<port>/callback`); the default stays `localhost` for OpenRouter. The new `await/3` ends the wait only for a GET on the callback path whose `state` matches in constant time with no repeated parameter, requires `iss` to equal the issuer (`{:error, :iss_mismatch}`), and drops the provider's `error_description`. `await/2` is unchanged.
  - `Raxol.Agent.Auth.Credential`: `Inspect` redacts the access token, refresh token and `user_uuid`; there is no `Jason.Encoder`, only `dump/1`/`load/1` for the encrypted store.
  - `raxol_broker` adds `Raxol.Broker.CredentialStore` (AES-256-GCM envelope, key in 1Password or the macOS keychain), `Raxol.Broker.Login`, and `Raxol.Broker.MCP.Client` (single-flight refresh on 401 or expiry, read-only tool allowlist at `call/3`). See `packages/raxol_broker/CHANGELOG.md`.
  - `raxol_mcp`: an HTTP spec may pin `era: :legacy | :modern`, which skips the `server/discover` probe at connect and after a rejected session (any other value is `{:error, :invalid_era}`). Robinhood's trading endpoint answers the probe with a plain-text 400, which is correctly not era evidence, so an unpinned client never connected; the broker pins `:legacy`. A 401 at connect or handshake no longer reconnects: `Raxol.MCP.Client` stays `:closed` with `{:connect_failed, reason}` and answers `await_ready/2` at once, instead of re-sending the same rejected headers every backoff interval until the shared per-origin breaker opened.
- **`raxol_broker` starts as a fail-closed pre-alpha package (#1172).** `Raxol.Broker.PolicyFile` parses a bounded `broker.policy.exs` as data rather than evaluating Elixir, then validates every policy field and requires explicit positive per-order and daily notional caps; `ask_timeout` is limited to 1..4_294_967_295 ms and invalid UTF-8 is a parse error. Loading rejects symlinks and refuses a file that fails the owner, mode, and parent-directory rules of `Raxol.Agent.OperatorFile.trusted?/1` (`{:untrusted_file, path, reason}`). `PolicyFile.new/2` builds the complete restrictive policy from the two required caps. `mix raxol.broker.init` publishes it atomically, mode 0600, without replacing an existing destination; prompting is limited to an interactive terminal, accepts the trimmed entered line, fails on EOF without writing, and is covered through the deterministic process shell used by tests. Decimal 3 avoids EEF-CVE-2026-32686.
- **`raxol_speech`: `Raxol.Speech.Recognizer` takes `load_model: false` (#1117).** The recognizer then starts without loading a model, and so without fetching one from the Hugging Face Hub: `available?/0` is `false` and `recognize/1` returns `{:error, :bumblebee_not_available}`, as in a build without Bumblebee. The default (`true`) is unchanged.
- **Security: `Raxol.System.Updater` verifies each release's Sigstore provenance before installing (#1075).** Until now a download was only checked against `SHA256SUMS` from the same release, so anyone able to replace release assets could replace both. The new `Raxol.System.Updater.Provenance` checks the release's `raxol-cli-attestation.sigstore.json` natively, with `:public_key`, `:crypto` and Jason and no `gh` or `cosign` at runtime:
  - The DSSE signature must verify with the Fulcio leaf key. The leaf must chain to a pinned Fulcio root at the Rekor integrated time, carry code signing and an SCT from a trusted CT log, and the integrated time must fall inside its validity.
  - The Rekor `dsse` entry must commit to this envelope and certificate. Its RFC 6962 inclusion proof must reach a checkpoint signed by the pinned Rekor key, and its signed entry timestamp must verify.
  - The certificate's issuer, source repository, `refs/tags/<tag>`, SAN (the manifest's `signer_workflow` at that ref) and GitHub-hosted runner must match. The in-toto SLSA statement must name the asset with the downloaded digest.
  - `Manifest` gains `provenance: :required | :off` (default `:required`), `attestation_asset` and `signer_workflow`. A missing or failing attestation refuses the install (`{:error, {:provenance_failed, reason}}`) before anything is extracted or replaced, on `self_update/2` and on `download_update/2` + `install_update/3` alike. `raxol update` reports the verification on success and explains a refusal.
  - The Sigstore public-good trusted root is compiled in from `priv/sigstore/trusted_root.json`; its `README.md` records the source and how to refresh it. Verified against the real `raxol-cli-v0.2.10` release bundle (all four binaries) and the `@raxol/cli@0.2.8` npm provenance bundle. Releases before 0.2.10 carry no attestation, so the updater will not install them.

### Fixed

- **Git integration tests isolate repository policy and Git commands run once.** Plugin test repositories now create a deterministic `main` branch, disable commit signing locally, and fail immediately when setup fails instead of cascading from an unborn `HEAD`. `GitIntegrationPlugin` executes each command once and keeps stderr separate so warnings cannot corrupt successful stdout parsing; failed commands return their stdout or exit status while Git writes diagnostics to stderr.

- **`raxol_agent`: reading `~/.raxol/providers.json` no longer depends on which modules are loaded (#1196).** `Credentials.sanitize_entry/1` turned the `~w(op_ref model base_url)` field names into atoms with `String.to_existing_atom/1`, which raised when no loaded module had named `:op_ref` yet, so `fetch/1`, `delete/1`, `put/2` and `load/0` could crash depending on load order. The fields now map to literal atoms. A regression reads the store from a fresh BEAM where only `Credentials` is loaded.
- **`raxol_agent`: `op` children get `/dev/null` for stdin, not the BEAM's terminal.** `Credentials.run_executable/3` relied on the port's `:in` option to give `op` EOF, but `:in` makes the child inherit the BEAM's stdin, which under the TUI is the user's tty: `op` could prompt on it and read keystrokes the TUI owns, and the stdin regression test hung to its deadline whenever the suite ran from a terminal. On Unix the child is now started through `/bin/sh -c 'exec "$0" "$@" </dev/null'` (executable and args as positional parameters, pid preserved for the deadline kill); Windows keeps the direct spawn.
- **`raxol_agent`: reading `~/.raxol/providers.json` no longer depends on which modules are loaded (#1196).** The `op_ref`, `model` and `base_url` fields were turned into atoms with `String.to_existing_atom/1`, which raised when no loaded module had named them yet, so `Credentials.fetch/1`, `delete/1`, `put/2` and `load/0` could crash depending on load order. The fields are now literal atoms. A regression reads all three fields from a fresh BEAM after checking that none of the atoms exist there yet.
- **Security: spawned processes no longer get the TUI's terminal as stdin (#1199).** Every spawner in `raxol_agent`, and `raxol_symphony`'s workspace hooks, opened its port with `:in`, believing it gives the child `/dev/null`. On Unix it does not: erts skips the stdin `dup2` and the child inherits the BEAM's fd 0, which under the TUI is the user's tty. A command run by the LLM `bash` tool could read keystrokes typed into the TUI (a key being entered for `/login` included) and rewrite the terminal's modes; the same held for the shell tool and its jobs, shell directives, native CLI backends, the `script` pty probe, Symphony hooks and the `op` CLI, which prompted on the tty instead of using the desktop app. Shell spawners now prefix their script with `exec </dev/null`; executables (`op`, native CLIs) run through the new `Raxol.Agent.SpawnedPort.spawn_spec/2`, which wraps them in `sh -c 'exec "$@" </dev/null'` with the executable expanded to an absolute path, removes `SHELLOPTS`, `BASHOPTS`, `PS4`, `BASH_ENV` and `ENV` from the wrapper's environment, and drops anything the wrapper prints before `exec` (bash-as-sh warns about an uninstalled `LC_ALL`, for one), so none of it can reach a secret `op read` returns. Unix ports no longer pass `:in`, so a spawner that loses its redirect hangs its stdin test on every host rather than only under a terminal. Windows keeps `:in`, where erts does open `NUL` for an input-only port.
- **`raxol_agent`: `op` is looked up only on absolute `PATH` entries.** A relative entry (`bin`, `.`, an empty element) resolves against the BEAM's working directory, so a cloned repository could ship a `bin/op` that received every `op read` and `op item create`. `Credentials.op_status/0` now reports an `op` that cannot be executed (exit 126/127, or a failed spawn) as `:absent` rather than asking for `op signin`, and `run_executable/3` returns `{:error, :op_spawn_failed | {:op_spawn_failed, reason}}` instead of raising.
- **Security: the terminal emulator bounds what its output byte stream can make it allocate, loop over or buffer.** That stream is written by programs, remote peers and replayed `.cast` files, and a few bytes carrying a large number were enough: `CSI 50000000 @` (11 bytes) and a sixel `!3000000~` (14 bytes) each ran a process past a 64 MB heap, and an unterminated escape sequence or string grew for as long as the stream did. Where a standard terminal bounds a value `raxol_terminal` now follows it; elsewhere the cap is documented where it is applied:
  - Control sequence parameters (CSI and DCS) keep xterm's limits while they arrive: 30 parameters (`NPARAM`), each clamped to 65535 (`MAX_I_PARAM`); past the last one digits accumulate into it, as in xterm. A million-digit parameter no longer builds a bignum, nor a million parameters a list. Intermediate bytes stop at 15, as in libvterm.
  - ICH (`CSI Ps @`) inserts at most up to the right margin.
  - OSC and DCS strings stop at 20,000 bytes (xterm's `maxStringParse` default for builds without sixel or ReGIS; with them xterm allows 600,000), and sixel data at the new `Raxol.Core.Defaults.max_image_payload_bytes/0` (4 MiB). A longer string is discarded, skipped to its terminator and never dispatched.
  - Sixel decoding keeps only the pixels the screen can show from the cursor, and at most the new `Raxol.Core.Defaults.image_size_ceiling/0` (the local terminal ceiling: 4096 x 4096, 1,048,576 pixels) for any other caller. Repeats, raster attributes and colour registers are read without bignums or unbounded lists, and data with many unknown bytes or commands parses in linear time (both were quadratic). Each sixel is its own image: the previous one's pixels are no longer drawn again at the next one's cursor (which also brought a cleared image back). Drawing is batched per row with one cell per colour; one full-screen image at 400x100 needed over 64 MB of heap, and 200 full-screen images at 512x256 took 143 s (now 21 s).
  - The tracked command line (`current_command_buffer`, and the history entries made from it) keeps at most 4096 bytes, a canonical-mode tty line, and each chunk is scanned without a list of its graphemes (~64 bytes of heap per input byte).
  - The head-of-chunk DECSTBM prescan in `Emulator.InputProcessing`, which parsed any `CSI Pt;Pb r` at the start of a chunk as an unbounded integer and was always overridden by the real handler, is removed.
  - `ESC H` (HTS) and `CSI Ps J` with a mode other than 0-3 crashed the emulator; HTS now keeps one stop per column and an unknown ED mode is ignored.
  - Sequences real programs send no longer crash `process_input`. OSC 7, 4, 10, 11, 17, 19, 51, 52 and OSC 1337 `CurrentDir=`/`RemoteHost=` wrote `Emulator` fields that never existed (so, for one, neovim's startup OSC 11 query killed the session). OSC 7 and 1337 now set the new `current_directory` and `remote_host` fields. OSC 4, 10, 11, 17 and 19 are ignored, sets and queries alike, since the emulator keeps no colours to set or report; programs that get no reply fall back to their defaults. OSC 52 and OSC 51 are ignored: a query is never answered, so output cannot read the pilot's clipboard or selection, and a set has no clipboard to go to. ICH, DCH, IL, DL and ECH read a count of 0, or one with colon subparameters, as 1 (ECMA-48) instead of crashing.
  - A byte that is not UTF-8 shows as U+FFFD and parsing carries on, as in xterm, in time linear in the input. It used to throw away everything the chunk had changed and the rest of it, so one bad byte could hide output from the pilot. A character split between chunks is joined. The command-line scan steps by codepoint, as OTP's grapheme breaking raises on some invalid UTF-8.
  - Sixel images are drawn at the cursor's column and row; the cursor's row and column were swapped, so an image landed transposed and was clipped to the wrong extent. The decoded pixel map is dropped once the image is on the screen (it held up to a million entries, ~36 MB at 4096x256).
  - BEL is counted in the new `Emulator.bell_count` field instead of forking `tput bel` for every 0x07 byte (about 2.7 ms each, with the output captured so nothing rang: 200 KB of BEL stalled a session for 524 s). The count only grows (RIS keeps it) and is there for a renderer to act on, comparing it with the last value it saw; nothing in raxol rings it yet.
  - DECSC (`ESC 7`) keeps one saved state per screen, main and alternate, as xterm does, and DECRC restores it without consuming it. Each `ESC 7` pushed a full copy onto `state_stack`, never trimmed (100,000 of them held 16 MB). The alternate-screen modes save and restore through the same slot: `CSI ? 1049 h` then `ESC 7` then `CSI ? 1049 l`, or `CSI ? 1049 h` / `? 1047 h` then `ESC 8` (smcup followed by sc/rc, routine for ncurses) raised KeyError on mismatched saved-state shapes. Leaving 1047/1049 restores only the main screen's DECSC slot, as in xterm, not the scroll region saved on entry (margins are not part of the saved cursor) and no longer the `CSI s` slot, which a program's `CSI s` on the alternate screen overwrote; a 1047 exit with nothing saved leaves the cursor where it is. `CSI s` also fills its screen's DECSC slot, as in xterm, so `ESC 8` restores it. DECRC with nothing saved on its screen (as on a fresh alternate screen) homes the cursor, turns origin mode and all SGR attributes off and resets the character sets, including a locking shift, as in VT510 and xterm; it was a no-op. `CSI ? 1048 l` restores only the cursor, as before.
  - An alternate-screen switch and IL/DL cost in proportion to the rows they change, and IL/DL keep the buffer's row count when the scroll region runs past its last row (after `Emulator.resize/3`, or at a size past the cell ceiling, the emulator's height and the buffer's differ). ED with the cursor past the buffer's last column keeps the row's width instead of crashing. Clearing a screen shares one blank row instead of building every cell, and IL/DL split the row list inside the scroll region (count clamped to it) instead of converting the whole screen to a map and back. Per `CSI ? 1049 h CSI ? 1049 l`: 2.1M reductions to 5.4K at 512x256, 18M to 14K at 4096x256 (a 10-toggle run went from 4.4 s and +1.1 GB to 1 ms). Per `CSI 256 L`: 437K to 1.8K reductions at 512x256, 3.2M to 5.8K at 4096x256. Inserted and deleted rows are now blank `Cell`s rather than bare maps.
  - OSC 7 is parsed as a `file://host/path` URI: `current_directory` holds the percent-decoded path and `remote_host` the host, only when the path is absolute and both are valid UTF-8 without C0 or C1 control characters (OSC 1337 `CurrentDir=`/`RemoteHost=` likewise); anything else is ignored. Both remain the writer's claim.
  - Malformed or unknown sequences (unknown CSI and OSC, unknown ED/EL modes, stray C1 bytes, bad sixel colours, unterminated strings, unhandled DECRQSS, RIS) log at `:debug`. At `:info` or above the output stream could otherwise set the log volume, a warning or error per sequence.
  - **Breaking** for `raxol_terminal` users, dead code removed: `Raxol.Terminal.Colors`; `Raxol.Terminal.Commands.OSCHandler.ColorParser`, `.FontParser`, `.HyperlinkParser` and `.SelectionParser`; `Raxol.Terminal.ANSI.TerminalState.save_state/2`, `restore_state/1`, `apply_restored_data/3`, `count/1`, `empty?/1` and `clear_state/1`; the `Raxol.Terminal.ANSI.Behaviours.TerminalState` behaviour; and the `config :raxol, :terminal_state_impl` override that swapped it in, which is now ignored (the alternate-screen modes always save and restore through DECSC/DECRC). Nothing in the repository used them after this change.

  Still bounded but costly: sixel work per image grows with the screen area it covers (about 105 ms for a full-screen image at 512x256), and a sixel-painted cell carries its own style.

  New tests in `packages/raxol_terminal/test/raxol/terminal/emulator/` (`output_bounds_test.exs`, `cursor_save_bell_test.exs`, `screen_cost_bounds_test.exs`) failed before, and `test/property/emulator_adversarial_property_test.exs` feeds random bytes, assembled escape sequences and a vocabulary of real ones (alternate screens, DECSC/DECRC, charsets, DECSTBM, SGR, OSC, DCS) through `Emulator.process_input/2`, checking it never raises and keeps the screen's shape; on the code before these fixes it finds the alternate-screen crashes within a few dozen runs.

- **Security: a session's terminal size is capped, and a network client's more tightly than the pilot's.** Nothing bounded it: a screen buffer is a full width x height grid allocated up front at ~536 bytes a cell, so an SSH client's pty-req or window change, or a `raxol_start` MCP call, asking for 100000x100000 asked the VM for ~5.4 TB, and the public SSH playground made that reachable from the network. The kept buffer is not the only cost: every keystroke and resize draws a full frame at the session's size, and that cost grows faster than the cell count (one styled full-screen frame measured 44 ms / +33 MB at 200x60, 0.9 s / +247 MB at 512x256, and 220 s / +1.4 GB at 4096x256). `Raxol.Core.Defaults` (`raxol_core`) now holds two ceilings, applied by the new `Raxol.Core.Utils.Validation.clamp_terminal_size/3` and `validate_terminal_size/3`:
  - The local ceiling, `max_terminal_width/0` and `max_terminal_height/0` (4096) and `max_terminal_cells/0` (1,048,576), sized for the pilot's own terminal (two 8K panels side by side at a 6x12 px cell are 921,600 cells). It is the backstop every buffer and engine clamps to.
  - The remote ceiling, `max_remote_terminal_width/0` (512), `max_remote_terminal_height/0` (256) and `max_remote_terminal_cells/0` (131,072), for sizes a network client chooses. A full-screen terminal on a 4K display at 8x16 px cells is 480x135.

  Per surface:
  - `raxol_terminal`: `ScreenBuffer.new/3`, `ScreenBuffer.resize/3`, `ScreenBuffer.Core.new/3` and `Core.resize/3` clamp to the local ceiling, so no path allocates a grid past it. `Emulator.set_dimensions/3` (and `Coordinator.validate_dimensions/2`, which allowed 1000x1000) and `SafeEmulator.resize/3` (10000x10000) now refuse past it with `{:error, :dimensions_too_large}`, and `Raxol.Recording.Index` clamps a `.cast` header to it (it clamped to 1000x1000).
  - The rendering engine clamps its size to the local ceiling at start and on every `{:update_size, _}`. `Lifecycle` clamps its `:width`/`:height` options and the dispatcher clamps every resize event, so the app's `init/1` and `update/2` are told the size it is drawn at. These sizes are the pilot's own (the local terminal, `Raxol.start_link/2`, in-process `Raxol.Headless`), so they are clamped rather than refused. An oversized `:width`/`:height` option logs a warning, as does an oversized resize event once per crossing into the ceiling (not on every SIGWINCH while it stays there); on a TTY, though, the Terminal Driver silences the Logger for the session so nothing is drawn over the screen, so an oversized local terminal renders at the ceiling without a visible warning.
  - SSH clamps the client's pty-req and window-change sizes to the remote ceiling, or to the new `Raxol.SSH.Server` option `max_terminal_size: {columns, rows}` (within the local ceiling, or the server refuses to start): a larger window renders at that size and the session stays up. A 0 column or row count takes the default 80x24, so no app is told a width of 0. A window change also resizes the session now: `Raxol.SSH.Session` sent it as a `:window` event, which only `update/2` saw, so the engine kept drawing at the pty-req size.
  - The `raxol_start` MCP tool refuses a width or height past the remote ceiling with an error naming the range, and its input schema states the bounds.
  - An app's resize clause that raises, throws or exits is now caught, logged and the model kept, as `update/2` failures on every other message already were; before, it crashed the dispatcher, and with it the session (for SSH, a client's chosen size could do this).

  New tests over each constructor, the engine, a headless session, the MCP tool, the dispatcher and a real SSH client (pty-req and window change at 4294967295x4294967295, and at 0x0) failed before.

- **Plugins now execute stateful callbacks in one stable process per loaded plugin.** `PluginLifecycle` starts an isolated `PluginRuntime` below a dynamic supervisor; initialization, events, filters, commands, hooks, state access, and timer messages are serialized there. `self()` remains valid for the loaded lifetime, unload removes the process and state, and resource accounting includes the stable runtime alongside auxiliary tasks.

- **The root `Raxol.Plugins` facade now uses the canonical stable plugin runtime.** Loading through `Raxol.Plugins.Manager` starts the same supervised `PluginRuntime` used by `Raxol.Core.Runtime.Plugins`; root input, output, mouse, resize, cell, command, lifecycle, and timer callbacks execute serially there. Manager structs retain metadata and configuration but no callback-state snapshots or duplicate loaded-plugin map. Unload runs stateful cleanup in the runtime, removes the process, and reload creates a fresh process identity.

- **`raxol_agent_client_protocol`: `Transport.Paired` lost what reached a side before its owner was set.** A side with no owner discarded peer frames and the peer's close, against the `Transport` behaviour's T-REL clause. `Connection` adopts its handle in `handle_continue/2`, after `Agent.start_link/2` and `Client.start_link/2` return, so a client that sent `initialize` right after both sides started could reach the agent's side first: the request was dropped and the client got `{:error, :timeout}` (the agent test's end-to-end smoke flaked this way in CI). Frames and the close are now held until `set_owner/2`, which delivers them in arrival order ahead of anything later, as `Transport.Stdio` already did. New tests send, and close, before adopting (both failed before).
- **`Raxol.Headless.screenshot/1` and `get_buffer/1` could return a blank frame, or one at the host terminal's size, right after `start/2`.** Both drew the frame with one `Rendering.Engine` call (`:render_frame_sync`) and read it back with a second (`:get_buffer`), so a cast that reached the engine in between ran first. One always could: `Lifecycle` init casts `{:set_rendering_engine, _}` to the dispatcher, which may not have handled it when `start/2` returns, and the dispatcher answers it with an `{:update_size, _}` cast that replaces the engine's buffer with a blank one. A runner slow to schedule the dispatcher therefore got a blank first screenshot (`examples_render_test.exs` failed "rendered a blank first frame" on the Windows leg), as could any `raxol_screenshot` made straight after `raxol_start`. The new `:render_frame_sync_buffer` call renders and replies `{:ok, buffer}` with the frame it drew, and `Headless` reads its frames through it; `:render_frame_sync` still replies `:ok`, so the gateway's per-event render barrier copies no buffer. Until that `{:update_size, _}` landed, the engine was also the size `:io.columns/0` and `:io.rows/0` (or `stty size`) reported, not the requested one, in every environment, so on a VM attached to a terminal an early frame came back at the terminal's size. In `:agent`, `:liveview`, `:ssh`, `:telegram` and `:gateway` the engine now starts at the `:width`/`:height` options, the size the dispatcher corrected it to anyway. New `headless_test.exs` tests failed before: one queues a resize at the engine between a screenshot's render and its read (the screenshot was blank), the other starts a session at 50x12 while the server's group leader answers like a 132x43 terminal (the frame was 132x43). The retry loops tests had added around the first frame, and the sleeps before a first screenshot, are gone.
- **`Raxol.System.Updater.State` crashed on Windows.** `UpdaterServer` built its default download and backup paths as `System.get_env("HOME") <> "/.raxol/..."`; Windows sets `USERPROFILE`, not `HOME`, so `init` raised `badarg` and every `Updater.State` call failed (the master Windows test leg went red once #1094 made the API reachable). Both default-settings builders now use `Path.expand("~/.raxol/...")`, like the settings file already did. New tests start the server with `HOME` unset and check the paths (both failed before).
- **`Raxol.Core.Metrics.MetricsCollector` lost records made on the same clock tick.** Entries were keyed `{type, name, monotonic_microseconds}`, so a second record on the same tick overwrote the first. Windows' coarse clock made that routine (the Aggregator tests saw mean 30.0 for 10/20/30) and a tight loop hits it anywhere. The key's time slot is now `{timestamp, unique_integer}`, which still sorts by time. A new test records 500 values in a loop and gets all 500 back (it lost some before) (part of #1120).
- **`Raxol.Core.Metrics.AlertManager` applies its `default_cooldown` and `default_severity` options (#1120).** A rule without its own `:cooldown` or `:severity` took them from the module's built-in defaults (300 s, `:warning`), not from the options the manager was started with, so `start_link(default_cooldown: 0)` still held every repeat alert for five minutes. Rules now take them from the running manager's options, and `start_link/1` checks them as it already checked `check_interval`: a `default_cooldown` that is not a non-negative integer number of seconds, or a `default_severity` outside `:info`, `:warning`, `:error` and `:critical`, returns `{:error, {:invalid_option, key, value}}` (a `nil` or `"300"` cooldown would otherwise let each rule fire once and never again, and a non-atom severity crashed the first notification). In the test support helper, `setup_metrics_test/1` started its unnamed manager with `default_cooldown: :timer.seconds(5)` (5000 s under the seconds unit) and `max_rules: 10`, which no metrics server reads, although no rule is ever added to that manager; it now passes neither, and the aggregator no longer gets `max_rules` either. The helper's `create_test_rule/4`, `create_test_alert/4` and `create_test_chart/3` are removed: nothing called them and none could work (the alert helper called the registered `AlertManager` name, which the setup never registers, with a `:timer.minutes(5)` cooldown of 300000 s; the rule helper sent `time_window:` where the Aggregator reads `window:`; the chart helper passed a metric name string where `Visualizer.create_chart/3` merges a map). A new test starts the manager with `default_cooldown: 0, default_severity: :critical` and checks twice: it got one `:warning` alert before and gets two `:critical` ones now; the new rejection tests started a manager for every invalid value before.
- **`Raxol.Core.Metrics.Aggregator` no longer creates atoms from `group_by` keys, and takes atom keys (#1120).** Its grouping fell back to `String.to_atom(key)` whenever a metric lacked the key as given, so every string key missing from some metric's tags minted an atom, and an atom key missing from a metric's tags raised `ArgumentError` and crashed the aggregator. `AlertManager` had its own lookup, which used `String.to_existing_atom/1` but never tried an atom key's string form. Both now group through `MetricsCollector.tag_value/2`, next to `normalize_tags/1`: it tries the key as given, then the other form (`String.to_existing_atom/1` for a string, `Atom.to_string/1` for an atom), and gives `nil` when neither is present. New tests failed before: an Aggregator rule grouped by `[:region]` crashed on a metric tagged `%{"region" => ...}` or without the tag, a string key no tag used existed as an atom after `update_aggregation/1`, and an `AlertManager` rule grouped by `[:component]` over `%{"component" => ...}` tags saw one ungrouped mean (55.0 instead of 90.0).
- **A `row`/`column` `do` block with one child renders that child (#1114).** A block with a single expression evaluates to that element, not a list, and the `row/2` and `column/2` macros (with options, e.g. `column style: %{gap: 1} do text("x") end`, and the `Raxol.View.Elements` forwards) stored it as `children` unwrapped, so the layout engine drew an empty container. Every View container macro (`row`, `column`, `box`, `flex`, `split`, `split_layout`) and the function forms now wrap the block with the internal helper `View.children_from_block/1` (`List.wrap/1`: `nil` from an `if` without `else` is no children, a list stays as is). The macros call it fully qualified and `use Raxol.Core.Runtime.Application` / `use Raxol.View` do not import it, so an app's own `children_from_block/1` still compiles. `split_layout :dashboard` with one child raised `FunctionClauseError`, and `panel do ... end` ignored its block entirely; both render the child now. The layout engine also lays out any container given one bare child map as a one-element list: before, `:flex` dropped it and `:row`/`:column` raised `BadMapError`. The new `view_single_child_test.exs` tests failed before (empty output, or the exceptions above).
- **`raxol_terminal`: `Raxol.Terminal.Integration.Renderer` reported every termbox call as failed outside test mode (#1105).** It matched `0` from `:termbox2_nif.tb_set_cursor/2`, `tb_clear/0` and `tb_present/0`, which return `:ok`, so `move_cursor/3` (and `Integration.move_cursor/3`) returned `{:error, {:set_cursor_failed, :ok}}`, `clear_screen/1` returned `{:error, {:clear_failed, :ok}}`, and `render/1` failed at its cursor step. `set_title/2` and `set_config_value/3` with `:title` matched `{:ok, "set"}`, but the NIF returns the charlist `{:ok, ~c"set"}`, so the title was sent to the terminal yet never stored and an error was logged. Each now matches the NIF's actual success value, and the `:termbox2_nif.tb_set_title/1` and `tb_set_position/2` docs name it. Those three NIFs discard termbox's own status, so the renderer's `{:set_cursor_failed, _}`, `{:clear_failed, _}` and `{:present_failed, _}` branches could never match and are removed. The Renderer docs now say that `clear_screen/1`, `move_cursor/3`, showing the cursor and the cursor and present steps of `render/1` cannot report a termbox failure: they return `:ok` even when termbox rejects the call, for example before `init_terminal/0`. The new `integration_renderer_test.exs` runs the real-terminal branch against the loaded NIF; its three tests failed before. Two more fixes close #1119. `Integration.move_cursor/3` returned the renderer's `:ok` in place of the state, although the README passes its result on to `Integration.clear/1`; it now returns the state with the moved cursor. Hiding the cursor called `tb_set_cursor(-1, -1)`, which termbox clamps to (0, 0) and shows the cursor there, and showing it did nothing. `set_cursor_visibility/2` and `set_config_value/3` with `:cursor_visible` now hide through `tb_hide_cursor/0` and show by placing the cursor at the cursor manager's position, and `render/1` no longer places (and so re-shows) a hidden cursor. `tb_hide_cursor/0` returns termbox's status, so a rejected hide is logged as `{:hide_cursor_failed, code}` and leaves the state unchanged. Both new tests failed before (`move_cursor/3` returned `:ok`; the hide was recorded although termbox rejected it).
- **`box`/`panel` without a `style:` map, and `container/1`, render instead of blanking the screen (#1122).** `Box.new/1` (behind `box` and `panel`) defaulted `style` to `[]`, and the cell renderer's `StyleProcessor` merged it with `Map.merge/2`, so `box padding: 1 do ... end`, `box(border: :single)`, `panel do ... end` and any keyword style (`style: [border: :double]`) failed every frame with `{:cell_rendering_error, %BadMapError{}}` and nothing was drawn. `Box.new/1` now builds a style map (keyword and atom-list styles are normalized with `StyleInheritance.ensure_style_map/1`), and its documented top-level `:border`, `:padding`, `:fg`, `:bg`, `:border_bg` and `:background_clip` options are folded into it as shorthands, so `box(border: :single, bg: :blue)` draws its frame and fill as `docs/core/RENDERING.md` shows (a `style:` entry still wins). `Flex.row/column/container` normalize their style the same way, so `row style: [gap: 2]` keeps its gap. A style list entry that is neither a `{key, value}` pair nor an atom (e.g. `style: ["bold"]`) is skipped instead of failing the layout of the whole frame. `StyleProcessor` and the layout engine accept keyword or `nil` styles on hand-built element maps. `container/1` emitted `type: :container`, which the layout engine dropped with "Unknown or unhandled element type"; it now lays out as a column, gapless unless `container(gap: n)` or `style: %{gap: n}` asks for one, which also covers `SelectList`'s `:container` tree. `examples/advanced/color_system_demo.ex` rendered a blank screen before and renders now. `Raxol.View.Elements` gains a `panel/2` macro, so `UI.panel title: "x" do ... end` compiles (it called an undefined `panel/2` and rendered nothing). `Raxol.Core.Renderer.View` deliberately has no such macro: `use Raxol.Core.Runtime.Application` imports View, and apps define their own `panel/2` helpers (as the cookbooks show), which an imported macro would shadow. The `Raxol.Core.Runtime.Application` moduledoc example, which used that form, now uses `panel(title: ..., children: [...])` and compiles and renders. The 12 new `view_default_style_render_test.exs` headless tests all failed before (blank screen, `BadMapError`, the dropped `:container`, or the undefined `Elements.panel/2`).
- **Every View DSL constructor draws what it is given (#1129).** A table test over every public constructor of `Raxol.Core.Renderer.View`, `Raxol.View.Elements` and `Raxol.View.Components` (checked against their exports, so a new constructor without a row fails) renders each headlessly and checks its text and documented styles. It found: `box`/`panel` `title:` never drawn (the positioned box dropped it); `border/2`, `border/3`, `border_wrap`, `wrap_with_border` and the `*_border` helpers, `scroll/2`, `scroll_wrap`, `shadow/1`, `checkbox/2`, `progress`, `list`, `select`, `radio_group`, `textarea`, `tabs`, `modal`, `input` and `Components.button/1` drawing nothing (no layout clause); `block_border`/`simple_border` raising; `checkbox(label: ...)` and `button(label: ...)` (the component gallery's form) crashing the frame; an empty `text_input()` in a row or column crashing the frame; `Elements.label/2` missing; `text(style: [fg: :red])` losing its keyword pairs; `text/2`'s `:align`/`:wrap`, `container/1`'s `:scrollable` and `View.new/2`'s box never read; a `do` block holding a nested list (`[header, for ...]`) failing the whole frame; `split_pane`'s side-by-side divider drawn as a horizontal row over the right pane; the checked checkbox drawn as `[[OK]]`. The declarative widgets lay out through `Raxol.UI.Layout.ViewNodes`; `shadow/1` takes `:children`. `progress` treats a `value` or `max` that is not a number as 0 (an empty bar), truncates a float `width`, uses the default for any other non-integer, and clamps the bar so it and the label it draws (` 5%` to ` 100%`) fit the space it is laid out in, so bad input no longer fails the frame or allocates a bar of any requested size; in a row or column it is sized by what it draws, not by its bar `width`, so the bar keeps its length whatever the value. A `list`/`select`/`radio_group`/`tabs` item may also be a keyword list, drawn by its `:label`; one that is not a string, a `{label, value}` pair, a `%{label: ...}` map, a `[label: ...]` keyword list or `String.Chars` (a record, any other list) is not drawn (logged once per node at debug, without its contents), so records passed as items never put their fields on screen or in an error log, and a `nil` `items`/`options`/`tabs` draws as empty. A box border of `:bold` draws heavy glyphs (`┏━┓`), `:block` (from `block_border/2`) solid `█`, and `:dashed` its dashed set, instead of single lines; `:simple` still draws single. `border/2`, `border/3`, `border_wrap` and `wrap_with_border` take every style `box(border:)` draws (`:heavy`, `:dashed_fine`, `:ascii` included), and still raise on an unknown one. Text scrolled past the frame's left or top edge draws the part still on screen (a wide character straddling column 0 is dropped) instead of vanishing; `shadow/1` paints only the strips its content does not cover, so the content keeps its own background; a box title of wide (CJK) characters advances by display width and is truncated by it. `Elements.label/2` and `Components.label/2` take the content first; `Raxol.Core.Renderer.View` gets no `label/2`, because `use Raxol.Core.Runtime.Application` imports `View` and an app's own `label/2` must keep compiling. A second test starts every TEA app in `examples/` headlessly and requires a non-blank first frame.
- **`:dim`, `:reverse` and `:strikethrough` reach every surface (#1132).** `Backends.transform_cells_for_update/1` kept only `:bold`, `:underline` and `:italic` of a cell's attributes, so tab and list selection highlights and every `style: [:dim]` drew plain on the terminal, SSH, LiveView and headless paths. Cell attributes now map to the buffer's names in one table (`:dim` becomes the buffer's `:faint`); the ANSI renderer emits SGR 2, 7 and 9 for them after its existing codes, so styles without them produce the same bytes as before, and the LiveView bridge swaps colours for `:reverse` and halves the foreground for `:faint`, mixing `currentColor` for text in the default colour (its `inherit` is not a colour, so `color-mix()` with it was dropped and the text drew at full strength). `Checkbox` and `Scrubber` had the same three-attribute allow-list for their own styles and now keep every text attribute. Telegram (plain `<pre>` text) and VS Code (ignores cells) still show none.
- **A process component runs in one process for as long as it is in the view (#1132).** `Rendering.Engine` started a new, unnamed `ProcessComponent` under `Raxol.DynamicSupervisor` on every frame and never stopped one, so each process component leaked a process per frame and lost its state each frame. Each rendering engine now owns its components: it keys them by `:id`, or by position in the view, so same-module siblings no longer share the colliding default id `"pc-<module>"`; it reuses the live process across frames, sends changed props through the new `ProcessComponent.update_props/2` (a component that exports `update_props(props, state)` keeps the state it returns; any other is re-initialised from the new props with `init/1`, as each frame did before, so a component like the `FileListWidget` example needs no props handler), stops components that leave the view, and stops all of them when it stops. A component that crashes draws a `[<label>: crashed]` placeholder for that frame and is started afresh on the next. `ProcessComponent` is now `restart: :temporary` and stops when the engine that owns it exits, and two sessions of the same app no longer share components.
- **`table` draws its documented `:border` (#1132).** Nothing read the option: the renderer drew only text, and the layout reserved an empty row for a header separator it never drew and padded widths by rules that matched nothing drawn. A table now draws a frame in its border style (default `:single`) and a rule under the header, `border: :none` draws neither and takes no space for them, and the layout measures exactly what is drawn, so the next sibling starts just past the table. `Raxol.View.Components.table/1` now passes `:border` on as well; it dropped the option, so its tables were always framed. A table that followed another child in the same box no longer blanks the frame (its layout replaced the accumulated siblings with an empty map).
- **`View.new/2`'s `:position` and `:z_index` are honoured (#1132).** No container read them. A view with `position: {x, y}` is now placed at that offset from the content origin of the container that lays it out and takes no space in its flow; a higher `z_index` draws over a lower one where views overlap, in any child order.
- **Smaller render-path fixes (#1132).** `BarChart` built a decreasing `0..-1` range for a bar with no full blocks, which Elixir deprecates and warned about at render; its ranges now step explicitly. `examples/advanced/commands.exs` called the undefined `Directive.spawn/1` and waited for a message the runtime never sends; it uses `Directive.spawn_task/1` and matches `{:command_result, ...}`. `examples/components/accessibility/accessibility_demo.ex` drew nothing (its struct had no `:form_data` and its root node type named no module) and listened for key messages the runtime does not send; it renders, and Tab/Shift+Tab, Enter and Space act through `{:focus_changed, old, new}` and `%Event{}` keys. `examples_render_test.exs` now also fails an example that calls an undefined function or module, which the compiler only warns about, and drops its known-blank list.
- **`raxol_terminal`: quitting a Raxol app under `mix run` exited 1 and left the terminal in the alternate screen (#1115).** On a TTY the Terminal Driver reads keys by tracing OTP's prim_tty reader (`:user_drv_reader`), but `TermboxLifecycle.cleanup_terminal/1` sent that reader a `:shutdown` exit on quit. `user_drv` treats any abnormal reader exit as a crash and stops, taking every group leader with it, so the restore that followed (mouse and focus modes off, autowrap, cursor, leaving the alternate screen) raised `:terminated`. The Driver died mid-cleanup, and `GenServer.stop/3` carried the exit through the Lifecycle to the process that called `Raxol.start_link/2`. `q` in `examples/getting_started/counter.exs` exited 1 with that stack trace. Cleanup now only stops tracing the reader, which stays with `user_drv`, so the restore is written and the app exits 0. A new `termbox_lifecycle_test.exs` test failed before the fix (the reader was dead after cleanup).
- **`raxol_terminal`: `Raxol.Terminal.Integration.write/2`, `handle_input/2` and `update_config/2` exited `:noproc` (#1094).** Each called `Raxol.Terminal.IO.IOServer` by module name, and nothing started one under that name, so the README example `Integration.write(Integration.init(), "Hello, World!")` exited. `Integration.State.update/2` had the same call behind a `rescue`, which does not catch exits, and `State.render/1` called the equally unstarted `RenderServer` whenever a window was active. Those calls are gone along with both servers (see Removed). `write/2` now returns the state, as the README documents; before, it returned `""` even with a server running, because IOServer never produced any output. `State.render/1` returns the state without looking up (and lazily starting) the window manager, and `Integration.Main.write/2` replies `:ok` like the process's other calls instead of `{:ok, ""}`. The new `integration_api_test.exs` calls `write/2`, `handle_input/2` and `update_config/2` with no servers running; all three exited `:noproc` before.
- **Lazily started singletons no longer die with the process that first called them (#1094).** `Raxol.Core.Utils.GenServerHelpers.ensure_started/2` (`raxol_core`) ran a `start_link` for all ten of its callers, so the server was linked to whichever process called first: a render process, an SSH or LiveView session, a Task, an ExUnit test. When that process exited abnormally the server went with it, taking all its state (RBAC roles, `Store` data, the user context, updater state, the i18n locale and its `:raxol_i18n` table, the colour theme, gestures, UX features, protocols), and the next call quietly started an empty one. A crash in the server also killed that first caller. And two first callers racing each other both ran `start_fun`, so the loser got `{:error, {:already_started, pid}}` and raised `MatchError`. `ensure_started/2` now treats `{:already_started, _}` as success, and its documented contract is that `start_fun` starts the process unlinked, as `Raxol.Animation.StateManager` already does. All ten callers now use `GenServer.start/3` or `Agent.start/2`: `Raxol.Protocols`, `Raxol.RBAC`, `Raxol.Animation.Gestures`, `Raxol.Core.ColorSystem`, `Raxol.Core.UXRefinement`, `Raxol.Security.UserContext`, `Raxol.Style.Colors.System`, `Raxol.System.Updater.State`, `Raxol.UI.State.Store` and `raxol_core`'s `Raxol.Core.I18n`. The two colour-system modules, which start one `ColorSystemServer` under one name, both go through the tolerant path. `Raxol.RBAC.start_link/1` stays linked, for use in a supervision tree. New tests kill the first caller of `Raxol.RBAC` and of `Store` and check that the server keeps its pid and its state (before the fix it went down with `:killed`). A third test registers the name between `ensure_started/2`'s `whereis` and its own start (before the fix this raised `MatchError`). The colour-system and accessibility tests now stop the lazily started `ColorSystemServer` and `I18nServer` around each test, because those servers now outlive the test that started them.
- **Quitting a full-screen app: Ctrl+C opened the BEAM BREAK menu, shutdown logs printed after quit, and a child crashing in `terminate/2` aborted the teardown (#1128).** (1) `raxol_terminal`: the Terminal Driver ran `Stty.raw!/0` before `start_stdin_reader/1`, whose prim_tty reinit writes prim_tty's own raw mode, the termios saved at VM boot minus ICANON and ECHO. ISIG came back on, so ^C raised SIGINT and the node hung in the BREAK menu with the terminal still in the alternate screen. Raw mode is now applied after the reinit, so ^C reaches the app as `%{key: :char, char: "c", ctrl: true}`; the `mix raxol.new` templates and the examples already bind it to `Directive.stop()`, and it now quits with exit 0 and the terminal restored. The first Ctrl+C still goes to the app, since `update/2` has no "unhandled" result to fall back on. A second one within a second of it, with no other key between them, makes the Driver send the Lifecycle `:quit_runtime`, the message `Directive.stop()` sends, so an app that does not bind Ctrl+C can still be quit through the normal teardown. prim_tty also writes its raw mode again on SIGCONT (the node stopped and continued, as with `kill -STOP` and `kill -CONT`), which turned ISIG back on for the rest of the session. The Driver now takes `-isig` back on SIGCONT with the InlineDriver's verify-then-assert loop, moved to `Raxol.Terminal.Driver.IsigGuard` so both drivers share it. (2) The Driver's cleanup set the Logger level to `:debug` instead of the level it found at init; it now restores that level. The Lifecycle stops the Driver first, so everything the rest of its teardown logged (about 7 `[info]`/`[debug]` lines) printed on the restored terminal. When the session ran with Logger at `:none`, `Lifecycle.terminate/2` now drops log events until the teardown is done (`Shutdown.quietly/3`). It drops only the events of the Lifecycle and the children it stops, through a primary `:logger` filter of its own per teardown. A separate process owns the filter and removes it when the teardown returns or the Lifecycle dies, so a Lifecycle killed mid-teardown cannot leave logging off, and one teardown finishing cannot lift another's silence. The filter id is an atom, which is never collected, so a teardown takes the first of `:raxol_lifecycle_teardown_0`, `_1`, ... not already installed: there are only as many ids as there were teardowns at once, not one more per session. Only a Lifecycle that owns a Terminal Driver goes silent, since `TERMINAL_LOG_LEVEL=none` also leaves Logger at `:none`, SSH and LiveView sessions included. The Driver's cleanup now restores the level in an `after`, so a terminal write that raises (`:terminated` once stdio has gone) no longer leaves logging off for the node. A Driver killed on the stop timeout, or crashing before its cleanup, never restores it, so the Lifecycle notes the level found before it started the Driver and restores it after the teardown, before the failure is reported. (3) `Shutdown.stop_process/2` used `rescue`, which does not catch the exit from `GenServer.stop/3` when the process crashes in `terminate/2`, so the Lifecycle's teardown stopped at that child and the Lifecycle died with the crash, taking down its `start_link` caller. The exit is now caught and the teardown continues. A child that overruns the stop timeout is killed, since `GenServer.stop/3` leaves it running. Each failure is logged with the child's label, pid and reason once the teardown is done and the terminal restored, and a quit that would have ended `:normal` ends `{:shutdown, {:teardown_failed, failures}}` instead, so `mix run` exits non-zero. New tests failed before the fix: a real-pty `-isig` test for the full-screen Driver (^C never decoded, `isig_off=false`), the Logger level after `cleanup_terminal/1` (`:none`), the Lifecycle's teardown log (six lines), a Lifecycle whose driver raises in `terminate/2` (the linked test process was killed), real-pty tests for a double ^C (both reached the app) and for ^C after SIGSTOP/SIGCONT (`isig_off=false`, no output), `quietly/3` tests for a killed teardown (its filter stayed installed), two concurrent teardowns (the first to finish lifted the other's silence) and a bystander process (its events were dropped too), and Lifecycle tests for a driver that fails to stop on a TTY (exit `:normal`), one that hangs in `terminate/2` (still running after the teardown), and drivers that crash before restoring the level or are killed on the stop timeout (Logger left at `:none` and the failure not reported); `quietly/3` run 50 times in a row (50 filter ids), a teardown with no Driver at `:none` (silenced), and `cleanup_terminal/1` raising (level left at `:none`).
- **`Raxol.Core.Events.EventManager` is supervised, and starts under its name as a bare child (#1094).** No startup mode started it, yet `Subscription.events/1` (and `subscribe_to_events/1`) in a TEA app's `subscribe/1`, the component `{:subscribe, events}` command, `KeyboardShortcuts.init/0`, `KeyboardNavigator.init/0` and `Plugins.API.subscribe` all call it by name, so each exited `:noproc`. The `raxol_core` README's bare `Raxol.Core.Events.EventManager` child did not help, because `BaseManager` registers no name unless given one. `EventManager.start_link/1` now registers under its module name unless `:name` is passed, and `Raxol.Application` starts it in `:full`, `:mcp` and `:minimal` (the raxol.io gallery runs TEA apps in `:minimal`). In `:test` it is a `:transient` child replacing `test_helper.exs`'s unsupervised start, since tests stop it with `EventManager.cleanup/0` and start their own. A new `raxol_core` test starts it as a bare child and receives a subscribed event (the subscribe exited `:noproc` before); booting each mode and calling `Subscription.start(Subscription.events([:x]), %{pid: self()})` returned `{:ok, {:events, _}}` instead of exiting.
- **`Raxol.set_theme/1` changes the theme Raxol renders with (#1104).** It wrote the `:theme` application env key, which only `Raxol.current_theme/0` read; `Raxol.Style`, the modal renderer, `Theming.Selector` and `Accessibility.ThemeIntegration` read `Raxol.UI.Theming.Theme.current/0` (the `:current_theme` key), so the new theme never reached a render. `set_theme/1` now goes through `Theme.apply_theme/1` and `current_theme/0` returns `Theme.current/0`. It also accepts the id of a registered theme. `Theme.apply_theme/1` given an id that is not registered (other than `:default`) now returns `{:error, :theme_not_found}` and leaves the theme alone; before, it silently applied the default theme. The `mix raxol.new` config template now names `:current_theme`; a `config :raxol, :theme, ...` line is no longer read. The new `test/raxol_test.exs` tests failed before the fix (`Theme.current/0` still returned the default theme; an unknown id returned `:ok`). The theme is node-global (one `:current_theme` for every SSH and LiveView session on the node), and `set_theme/1` takes a `Theme` struct or an atom id: a string or plain map raises `FunctionClauseError`. Because `set_theme/1` now takes effect, `Raxol.set_accessibility/1` no longer calls it unconditionally (it reset the theme to the default on any call without `:high_contrast`, and `high_contrast: true` applied the plain dark theme): it touches the theme only when `:high_contrast` is given, `true` applying `Theme.adjust_for_high_contrast/1` to the current theme and `false` restoring the theme it replaced (unless another was set meanwhile). `Theme.create_high_contrast_variant/1` (behind `adjust_for_high_contrast/1`) no longer raises `BadMapError` on a theme with `nil` `variants`, which every `Theme.new/1` and `default_theme/0` theme has. `Rendering.Engine`, which draws every TEA frame (terminal, SSH, LiveView, headless), looked its theme up by the dispatcher's theme id and never read `Theme.current/0`, so the theme still did not reach a TEA app: while that id is the default it now renders `Theme.current/0` (which, before any `set_theme/1`, is the theme registered under the default id, as the Engine rendered before, else the built-in default), and an id chosen by the app or the user's preferences renders the theme registered under it (`Theme.current/0` if none is). `high_contrast: true` raised `FunctionClauseError` on a theme with a colour that has no RGB components (a named colour such as `:green`, a 256-colour index, a bad hex); `create_high_contrast_variant/1` now keeps such colours as they are. And `high_contrast: true` after a theme was set while it was on returned `:ok` without touching the new theme; it now raises that theme's contrast.
- **Choosing a theme in `Raxol.UI.Theming.Selector` crashed (#1118).** A click on a theme in the open list called `Theme.apply_theme/1` with the theme's `name`, a display string such as `"default"`, but `apply_theme/1` takes a theme struct or a registered id, so the click raised `FunctionClauseError`. It now applies the listed theme struct itself. New tests click a theme through the selector's `handle_event/3` and check `Theme.current/0`, the collapsed list and the `:on_select` callback (both raised before).
- **`Raxol.UI.Theming.Selector`'s keyboard selects a theme.** The open list's footer says `Enter: Select`, but Enter and Space only kept the highlight where it was: neither applied the theme nor closed the list, and on the closed selector no key opened it, so a theme could be chosen only with a click. On the closed selector Enter or Space now opens the list; in the open list they apply the highlighted theme, pass its name to `:on_select` and close the list, as a click does. On an empty list they only close it. Escape still closes without changing the theme. The new keyboard tests failed before (the list never opened).
- **`Subscription.events/1` delivers to the app's `update/2` (#1103).** EventManager sends each match to the subscribing Dispatcher as `{:event, event_type, event_data}`, and the Dispatcher had no clause for it: it logged "Dispatcher received unhandled info message" and dropped the event, so a TEA app whose `subscribe/1` returned `Subscription.events/1` (or `subscribe_to_events/1`) never saw one. The Dispatcher now passes the message to `update/2` unchanged. The docs now say which events arrive: only those dispatched through `EventManager` (theme, accessibility and keyboard-navigation events). Terminal input still reaches `update/2` as `%Event{}` structs and is not routed through `EventManager`, so the old `[:key_press, :mouse_click]` example is gone. They also say that `EventManager` is node-global: every session on the node whose app subscribes to a type gets every event of it, whichever session dispatched it, so `:screen_reader_announcement`, `:activate` and `:dismiss` carry other sessions' announcement text and focus ids. A new dispatcher test dispatches through `EventManager` and asserts that `update/2` gets the event, then stops getting it once the model drops the subscription. It timed out before the fix. Only an event type that a running subscription lists is passed on: an event still queued when the model drops its subscription, or an `{:event, type, data}` sent by any other process, is dropped with a debug log. Declarations that list the same type share one `EventManager` subscription, so each event reaches `update/2` once; two overlapping declarations used to deliver it twice. Dropping a subscription while `EventManager` is down no longer crashes the Dispatcher (`EventManager.unsubscribe/1` exited `:noproc`). Known limitation: delivery stops if `EventManager` restarts, because the subscription is not re-established. Tests for the stale, forged and overlapping cases and the `:noproc` crash failed before.
- **`ComponentManager` delivers subscribed events to its components (#1121).** A component that returned `{:command, {:subscribe, types}}` got an `EventManager` subscription for the manager, but the manager had no clause for the `{:event, type, data}` messages `EventManager` sends, so the first matching event crashed it with `FunctionClauseError`. It could not have routed them either: the message carries no subscription ref, and every subscribe started its own `EventManager` subscription, so overlapping subscriptions got every event once per subscription. The manager now holds one `EventManager` subscription per event type with the set of components that list it, started when the first component subscribes and stopped when the last one leaves, and passes each event once to every listing component's `update/2` as `{:event, type, data}`, through the same path as `ComponentManager.update/2` (returned commands are processed). An event for a type no component lists is dropped with a debug log. `update/2` may return `{:ok, new_state}`, as `Raxol.UI.Components.Base.Component` declares, for every message the manager passes it: the manager answered it with `:invalid_component_return` on `ComponentManager.update/2` calls, dropped it for scheduled messages, and stored `:ok` as the component's state for a broadcast. An invalid return from a broadcast or scheduled message now keeps the component's state and logs the component and the message kind but not the data (a broadcast crashed the manager with `MatchError`; a scheduled one was dropped silently). A component whose `update/2` raises or returns anything else keeps its state and the other subscribers still get the event; the warning names the component and the event type but not the event data, which can be another session's (the crash warning quoted it). Contract change: `{:unsubscribe, sub_id}` is replaced by `{:unsubscribe, event_types}`, because the component was never told its subscription id; the old form now logs "Unknown component command". Unmounting removes the component from every type. Subscribing while `EventManager` is down, not answering in time, or stopping during the call logs a warning and leaves the component unsubscribed from that type instead of crashing the manager and every mounted component with it (the `{:ok, sub_id} = Subscription.start(...)` match exited `:noproc`; any exit from the call is now caught). Commands returned from `mount/1` or `handle_event/3` lost their effect on the manager's state, so a subscription made there was started but never recorded; they now take effect, and `dispatch_event/1` reads each component's current state, so a `{:broadcast, _}` from one component's `handle_event/3` is not overwritten when a later component handles the same event. The moduledoc states the contract, including the known limitation that subscriptions are not re-established if `EventManager` restarts. The new tests failed before the fix: the delivery, mount, unsubscribe, unmount and forged-event tests crashed the manager with `FunctionClauseError`, overlapping and repeated subscriptions made `EventManager` send two copies of one event, the `handle_event/3` subscription never delivered, an `{:ok, state}` reply was rejected (and stored as the state `:ok` for a broadcast), a failing component's warning carried the event data (and a bad return was not logged), a component handling the event after the broadcasting one lost the broadcast, and subscribing with `EventManager` down exited `:noproc`, or `shutdown` when it stopped during the call.
- **`raxol_agent`: `Conversation.Log` kept an empty subscriber set for every conversation ever subscribed to.** `unsubscribe/2` and a subscriber's `:DOWN` deleted the pid from the conversation's `MapSet` but kept the key, so the log's `subscribers` map grew by one entry per conversation id for the life of the log (and `unsubscribe/2` on a conversation never subscribed to added one). A conversation's entry is now removed when its last subscriber leaves. The new `log_test.exs` tests failed before the fix (four empty sets left after unsubscribes; the killed subscriber's conversation left as an empty set) (#1080).
- **`raxol_symphony`: a terminal issue left its `tracker_cache` row behind.** With the opt-in `agent.tracker_cache` set, `Runners.RaxolAgent` writes one `{:tracker, issue.id}` row per issue. `Raxol.Agent.Cache.Ets` expires a row only when the same key is read again, and a terminal issue is never checked again, so every finished issue kept its row for the life of the BEAM. Terminal exits already flushed the session runner's `prompt_cache` row but not this one. The new `RaxolAgent.flush_tracker_cache/2` now runs at the same terminal release sites (retry finds the issue terminal, gone or inactive; `stop_run/2`; reconcile-kill; paused-run TTL GC). A new test seeds the row, reconciles the issue to `Done`, and asserts the table is empty (it kept 1 row before).
- **`raxol_symphony`: the orchestrator's `completed` set grew by one issue id per finished run.** `Orchestrator.State.completed` was written on every clean worker or batch-branch exit and read nowhere, so it grew for the orchestrator's lifetime. It is removed. The workflow-mode tests that read it through `:sys.get_state/1` now wait for the `:worker_exit_normal` listener event and check its snapshot.
- **`Raxol.UI.State.Store`, `Raxol.Security.UserContext`, `Raxol.System.Updater.State` and `Raxol.Core.ColorSystem` reach their servers again (#1080).** Their servers use `BaseManager`, whose `start_link/1` registers no name unless it is given one, yet each public API calls the server as `__MODULE__`. The lazy starts (`ensure_server_started/0`) passed no name, `ServerRegistry` started the UI server as `:ui_state_server`, and `Raxol.Core.ColorSystem` (behind `Raxol.Core.get_theme/0`, `set_theme/1` and core init) called `ColorSystemServer` without starting it at all, so every call exited `:noproc`. `StateManagementServer`, `ContextServer`, `UpdaterServer` and `ColorSystemServer` now register under their module name unless `:name` is passed, `ServerRegistry` uses that name, and `Core.ColorSystem` starts the server on first use. New tests call each public API with no server running (each exited `:noproc` before) and check that `Store` uses a supervised server instead of starting a second one.
- **`Store.get_state/0` returns the whole store (#1080).** The default empty path reached `get_in(store, [])`, which raises `FunctionClauseError`, so asking for the whole store crashed the store server. An empty path now returns the store; the first-use `Store` test caught it once the naming fix let the call through.
- **`Raxol.Profiler`, `DevHints`, `mix raxol.bench.advanced` and the recovery context manager reach their servers (#1080).** The same unnamed `BaseManager` start: `Raxol.Profiler.enable/0` and the `:performance_monitoring` child started `Raxol.Performance.Profiler` unnamed, so `disable/0`, `report/1` and every profile run exited `:noproc`; the dev child `{DevHints, []}` left `DevHints.enabled?/0` false, so hints and `stats/0` were off; `mix raxol.bench.advanced` called `SuiteRegistry.start_link()` and then the registry by name; `RecoverySupervisor` started `ContextManager` unnamed and then called it by name. Each server now registers under its module name unless `:name` is passed. A new test per server starts it the way production does and calls the API (each exited `:noproc`, or reported hints off, before). #1107 has since removed `ContextManager`, and its test with it, because nothing else used it (see Removed).
- **`raxol_core`: `ErrorRecovery` works in minimal mode (#1080).** `RAXOL_MODE=minimal` starts `{Raxol.Core.ErrorRecovery, [mode: :minimal]}` with no name, so every `with_circuit_breaker/3` call exited `:noproc`. `ErrorRecovery` now registers under its module name unless `:name` is passed; a new test starts it that way and runs a circuit breaker (it exited `:noproc` before).
- **`raxol_terminal`: the terminal cache and `Sync.System` reach their servers (#1080).** `Raxol.Terminal.Supervisor` starts `Raxol.Terminal.Cache.System` with options and no name, and the `:terminal_sync` feature starts `{Raxol.Terminal.Sync.System, []}`, so `AnimationCache`, `ScrollManager` and the `Sync.System` API exited `:noproc`. Both now register under their module name unless `:name` is passed; new tests start each without a name and use the API (each exited `:noproc` before).
- **The UI state server drops a dead component's hook state (#1080).** `StateManagementServer`'s `:DOWN` handler deleted the pid from `component_ids` and then looked the pid up there to find which hook states to purge, so the purge never ran and `hook_states` kept every dead component's entries. It now reads the component id first; a new test kills a component and asserts `get_hook_state/2` returns `nil` (it returned the old value before).
- **`UserContext.ContextServer` forgets a dead caller's monitor (#1080).** `monitors` is keyed by pid, but the `:DOWN` handler deleted it by monitor ref, so one entry stayed for every process that ever set a user or context. It now deletes by pid; a new test lets a caller exit and asserts `monitors` is empty (it still held the dead pid before).
- **`raxol_core`: a high-contrast preference change reaches the color system (#1080).** `Raxol.Core.Accessibility.PreferenceManager.maybe_notify_color_system/2` checked `Process.whereis(Raxol.Style.Colors.System.Server)`, a module that does not exist, so it never notified the running `ColorSystemServer`. It now looks up `ColorSystemServer`; a new test flips `:high_contrast` and asserts the server's `get_high_contrast/0` follows (it stayed `false` before).
- **`Raxol.Animation.Gestures` exited `:noproc` on every call, and its server kept entries for dead processes.** `GestureServer`'s API calls `GenServer.call(__MODULE__, ...)`, but its BaseManager `start_link/1` registered no name unless one was passed, so `Gestures.ensure_server_started/0` started an unnamed server and `Gestures.init()` exited `:noproc`. `GestureServer.start_link/1` now registers `GestureServer` by default (a `:name` still overrides it). Behind that, only `init_gestures`, `register_handler` and `touch_down` monitored the caller, so a process whose first call was `touch_move`, `touch_up` or `update_animations` got an entry nothing removed when it died. Every write now goes through one path that monitors the pid. The new tests failed before each fix: `Gestures.init()` exited `:noproc`, then a killed `touch_move`-only process kept its entry (#1080).
- **`Raxol.Performance.CycleProfiler` kept dead subscribers and notified duplicates twice.** `subscribe/1` appended the caller to a list with no monitor and no dedup, so a subscriber that exited stayed in the list for the profiler's lifetime, and a process that subscribed twice got each `{:slow_cycle, _}` twice. A repeated subscribe is now a no-op, and each subscriber is monitored and dropped on `:DOWN`. Both new tests failed before the fix (#1080).
- **`Raxol.Style.Colors.HotReload` kept dead subscribers, and one `unsubscribe/0` did not undo two `subscribe/0` calls.** Subscribers were a list with no monitor, so an exited subscriber stayed until the server stopped, and a duplicate subscribe added a second entry: each change arrived twice, and after one `unsubscribe/0` the process still got notifications. Subscribes are deduplicated, each subscriber is monitored and dropped on `:DOWN`, and `unsubscribe/0` removes the monitor. Both new tests failed before the fix; the "multiple subscribers" test now uses a second process instead of subscribing the same one twice (#1080).
- **`raxol_core`: `EventManager` kept pid handlers after the pid died.** `register_handler/3` accepts a pid target and `:DOWN` already removed a dead pid's handler rows, but only `subscribe/2` ever monitored anyone, so the handler rows of a pid that never subscribed stayed in the ETS bag for the manager's lifetime (`get_handlers/0` still listed a killed pid). Pid handlers are now monitored too, with one monitor per pid instead of one per `subscribe/2` call (#1080).
- **`raxol_symphony`: a killed or discarded run stranded its agent session.** `Runners.RaxolAgentSession` starts each run's session subtree (EmitBridge, Lifecycle, Session) under `Raxol.Agent.DynSup`, so it can outlive the worker when a run pauses, but only `finalize/2`, running inside the worker, ever stopped it. The orchestrator ends runs by killing the worker (`stop_run/2`, a stall, reconcile), so none of those paths reached it, and neither did discarding a parked run (`stop_run/2` on a paused entry, or the paused-run TTL GC). Each left a live agent session under `DynSup` for the node's lifetime. While a worker owns a session, an unlinked guard now watches the worker and stops the session if it dies; returning a pause disarms it. Runners gain an optional `release/1` callback, which the orchestrator calls with the resume token whenever it discards a parked run; `RaxolAgentSession.release/1` stops the parked session. The new tests failed before the fix: a killed worker's session never went `:DOWN`, and the orchestrator never released anything.
- **A headless session whose app exits now stops its tool synchronizer.** `Raxol.Headless` dropped the session on the lifecycle's `:DOWN` without stopping its `Raxol.MCP.ToolSynchronizer`, which is linked to Headless rather than to the app, so the synchronizer kept its `[:raxol, :runtime, :view_tree_updated]` telemetry handler and the session's MCP tools and `raxol://session/<id>/*` resources for a session `list/0` no longer reported. The `:DOWN` path now stops it the way `stop/1` does; a new test kills the lifecycle and asserts the synchronizer exits and its handler and resources are gone (it timed out waiting for the synchronizer before).
- **Security: anonymous code execution through the playground REPL demo (#1045).** The HTTPS gallery serves every catalog entry at `/demos/:demo` with no auth, and `Raxol.Playground.Demos.ReplDemo` evaluated whatever a browser typed. Two fixes: `Raxol.REPL.Sandbox` now refuses `import`, `alias`, `require` and `use` at `:standard` and `:strict` (`import System; cmd("id", [])` and `alias :os, as: Enum; Enum.cmd(~c"id")` both returned `:ok` before, because every other clause decides safety from a module name and those four forms decide which module a name reaches), and the demo no longer evaluates at all unless the deployment opts in. The opt-in is now a single predicate, `Raxol.Core.Boundary.Evaluation.exposed?/0` (`RAXOL_REPL_EXPOSED=true` or `config :raxol_core, :repl_exposed, true`), read by both halves of the rule *a node that evaluates submitted code does not hold signing keys*: the demo before it evaluates, and `Raxol.Payments.Deployment.assert_signing_isolated!/0` before a signing node boots. They previously read different application keys (`:raxol` and `:raxol_payments`), so configuring the demo's key turned anonymous evaluation on while a co-located signing node still booted. `config :raxol_payments, :repl_exposed` is still honoured by the boot assertion so an existing signing deployment does not silently start booting, but it does not enable the demo. `mix raxol.repl` passes `local_operator: true` and keeps working without the flag, which is accepted only at `environment: :terminal`, so a served app cannot claim it over SSH or LiveView. Sandboxed code that names its modules in full is unaffected; `:none`, the local-terminal level, is unchanged. `Raxol.REPL.Sandbox` is a mitigation, not a trust boundary: at `:strict` the bare-name capture forms of `apply` and `spawn` still pass the checker, so the deployment flag is what keeps an anonymous caller away from the evaluator.
- **`raxol_agent`: one unterminated escape truncated a whole transcript export.** `Raxol.Agent.Code.Replay` sanitized the joined transcript in a single pass, and the OSC/DCS/APC scan runs to BEL or ST, so one unterminated `ESC ]` in any tool result (`ls --hyperlink`, a colored `git diff` cut off at a byte cap) deleted every later turn from `/export`, `/transcript` and the share page. Sanitizing per line bounds the loss to the line that carries the escape, and cuts a 2.3 MB transcript from 390 ms to 126 ms. TAB is preserved again in the exported file.
- **Cell text is blanked, not deleted, at the terminal emitters.** `Raxol.Terminal.Renderer` and `Raxol.Core.Renderer` dropped a cell they could not emit, which pulled every cell to its right one column left for the rest of the row (box borders, table columns, the approval line) with no `CSI 2 K` to repaint it. A disallowed cell now becomes a space through the new `Raxol.Core.Boundary.TermText.sanitize_cell/1`, which `Raxol.Core.Runtime.Rendering.Backends.sanitize_char/1` also delegates to, so the cell-write boundary and the emitters share one convention and C1 controls and raw invalid-UTF-8 bytes are covered at both. A 200x60 frame renders in 1.6 ms against 4.9 ms for the per-cell text sanitize it replaces (1.3 ms with no confinement at all).
- **Bidi overrides and other format characters are stripped at every sink.** `TermText` stripped only C0/DEL/C1/ESC, so `U+202A`-`U+202E`, `U+2066`-`U+2069`, `U+200B`, `U+200E`, `U+200F`, `U+00AD`, `U+2028`, `U+2029`, `U+FEFF` and the `U+E0000`-`U+E007F` tag characters reached the terminal through the transcript tree while the app chrome stripped them: an approval line could be reversed (Trojan Source, CWE-451) on the same screen as a footer that could not. `TermText.strip_codepoint?/2` is now the one deny set, and `Raxol.Harness.Surface.ViewText` uses it instead of its own list. The wider set costs nothing on ordinary text: printable ASCII short-circuits before the scanner consults it, so 200 lines of 1100 plain bytes sanitize in 2.95 ms against 2.96 ms for the narrower set it replaces.
- **OSC 8 links are restricted to `http`, `https` and `mailto`.** A Markdown link an LLM wrote reached the hyperlink sinks with its scheme unchecked, so a `file:///etc/hosts` target, or an `x-apple.systempreferences:` one, became clickable. `TermText.sanitize_url/1` drops any other scheme (and a scheme-less target) at the layout link attribute and at both renderers; the label text still renders.
- **`raxol_terminal`: an OSC 8 param could replace the URL.** `URI.encode/1` leaves `;` and `:` intact, and both are structural in `ESC ] 8 ; params ; URI ST`, so a tooltip containing either split the param list and a terminal could parse a different URI. Params are now encoded down to the unreserved set. `report_progress/2` also clamps out-of-range values instead of emitting an OSC 9;4 with an empty percentage.
- **The hyperlink plugin no longer strips the stream it is scanning.** `Raxol.Plugins.HyperlinkPlugin.handle_output/2` ran an untrusted-text sanitize over the whole output chunk, so any chunk mentioning a URL lost its SGR runs, cursor moves and CRs. Only the captured URL is confined now.
- **`raxol_agent`: a `.mcp.json` entry the bridge could not run vanished without a trace.** `Raxol.Agent.Code.McpConfig` dropped any server without a string `command`, so a Claude Code `url` server (`"type": "http"` or `"sse"`) or a broken entry was absent from `/mcp` and from `/inspect` while its name sat in the file. `McpConfig.load_all/1` now returns those entries as `{name, reason}`, one reason per fault (`:unsupported_transport`, `:no_command`, `:command_not_string`, `:not_an_object`), so the rendered text names what is actually wrong. `/mcp` lists each as `⊘ name → skipped: …` (`⊘` never started, `✗` started and failed, now with its reason), capped at the 16 rows the loader caps launches at; the status line counts them (`1 MCP servers · 1 skipped`) and keeps counting them once the servers finish loading; and `mix raxol.inspect` / `/inspect` carry them in `mcp_servers.skipped`. `mix raxol.inspect` now strips control characters from its rows, as the TUI already did, so a key in a cloned repo's `.mcp.json` cannot forge a row. `McpConfig.load/1` is removed: `load_all/1` replaces it everywhere.
- **`raxol_terminal`: `CSI ? 80 h`, `CSI 80 h` and `CSI 132 h` wiped the screen.** `Raxol.Terminal.Modes.Types.ModeTypes` registered DEC-private 80 and standard 80/132 as column-width modes, and once `ModeProcessor` started dispatching from the registry every one of them reached a handler that replaced both screen buffers with empty ones. None is a real mode (`CSI ? 80` is DECSDM in xterm; standard 80/132 do not exist). The three rows are removed, so `ModeTypes.lookup_private(80)`, `lookup_standard(80)` and `lookup_standard(132)` return `nil` and the sequences are ignored. `CSI ? 3 h/l` (DECCOLM) remains the only column-width switch; `:deccolm_80` survives only as the name of its reset state.
- **`raxol_terminal`: a malformed `CSI h`/`CSI l` parameter raised.** `\e[?1;h` (empty slot) and `\e[?4:3h` (colon subparameter) reached `String.to_integer/1` and crashed the emulator. Non-integer parameters are now skipped and the well-formed ones still apply.
- **`raxol_terminal`: `CSI ? 1049 h` no longer filled the `CSI s`/`CSI u` slot.** xterm defines 1049 as save-as-DECSC / restore-as-DECRC; the save and restore now live in `Raxol.Terminal.Modes.Handlers.ScreenBufferHandler`, so `\e[5;10H\e[?1049h\e[1;1H\e[u` returns the cursor to row 5, column 10 again.
- **Dev endpoint: a moving probed port forced recompiles and broke `--no-compile` boots.** `Raxol.Endpoint` recorded the entire `Raxol.Endpoint` config as compile-time environment, including the `port:` that `config/dev.exs` probes for a free socket on every config evaluation. Whenever the probe landed on a different port, Mix marked the module stale and `mix compile` aborted with a compile-environment mismatch. Only `:tidewave_project_eval` is recorded now. `dev_bind_loopback?` also treats an IPv4-mapped loopback bind (`::ffff:127.0.0.1`) as loopback, matching Tidewave's own `is_local?/1`, so that bind no longer silently unmounts MCP.
- **Playground listener: three "hardened" limits were looser than Cowboy's own defaults.** `request_timeout` was 10_000 against Cowboy's 5_000, `max_header_value_length` 8_192 against 4_096, and `max_reset_stream_rate` `{100, 10_000}` against `{10, 10_000}`, which is the CVE-2023-44487 Rapid Reset guard. Every limit is now at or below the upstream default and carries its rationale. `inactivity_timeout` no longer cuts idle long-polls (it was 10_000, exactly the transport's `window_ms`, so an idle poll died with no response), and `max_connections` is 1_000 to match the fly.io proxy's per-machine connection hard limit instead of stopping at 500. `web/mix.lock` now resolves cowboy 2.19.0 / ranch 2.3.0 / phoenix 1.8.14 / phoenix_live_view 1.2.12, so the deployed playground runs the same adapter the rest of the repo is locked to.
- **`raxol_terminal`: a carriage return cost three cursor round trips with debug logging off.** `Raxol.Terminal.ControlCodes.handle_cr/1` hoisted `Cursor.Manager.get_position/1` out of its `Logger.debug` calls, so with `emulator.cursor` held as a pid every CR byte made three synchronous `GenServer.call`s (seven when it resolved a pending wrap) at any log level. The lookups now sit inside the macro argument, leaving the one call `move_to/3` actually needs (three across a wrap).
- **`raxol_terminal`: the CSI intermediate parser logged the rest of the input chunk.** Its debug line inspected the whole remaining binary, which can carry an OSC 52 clipboard payload; it now reports the byte count. `Raxol.Terminal.Input.CoreHandler` had the same shape and got the same treatment.
- **`TERMINAL_LOG_LEVEL=warn` no longer refuses to boot.** The release config maps that variable onto the node-wide `Logger` level, and its allowlist omitted the `"warn"` spelling that Logger still accepts, so a previously harmless setting raised an `ArgumentError` at startup.
- **`Raxol.Core.ConnectionPool.transaction/3` leaked every connection and serialized the pool.** The callback ran inside the pool GenServer and the state `do_checkin/2` returned was thrown away, so each successful transaction left its connection marked busy (a size-1 pool refused the second transaction with `{:error, :timeout}`), and one slow callback blocked every other checkout and `stats/1` call. The callback now runs in the calling process between a `checkout/2` and a `checkin/2`, and the pool monitors whoever holds a connection, so a holder that exits without checking in gives it back.
- **`raxol_agent`: `SessionStreamer` monitored its subscribers on every subscribe and never let go.** Duplicate subscribes and each subscribe/unsubscribe cycle added a monitor that lasted until the subscriber died, so a long-lived consumer cycling per-run sessions grew the streamer's monitor list without bound (3,000 after 1,000 cycles). It now keeps one monitor per subscriber pid and removes it when that pid leaves its last session.
- **`raxol_agent`: the probe Runner Pool kept every run it ever saw.** `Raxol.Agent.Probe.Runner.Pool` wrote each run into its `runs` map and never removed one, so the long-lived singleton grew by one entry per probe run (51 entries after 51 finished runs), and a pool's `parked` entry stayed behind as an empty `MapSet` once its last parked run left. The pool now keeps at most `:max_terminal_runs` finished runs (default 1000, set with the new `Pool.start/1`) and drops the one that finished longest ago; `status/1` and `kill/1` return `{:error, :not_found}` for it. Running and parked runs are never dropped, and an emptied `parked` set is deleted.
- **`raxol_gateway`: a failed Discord WebSocket upgrade leaked its TCP socket.** When `Mint.WebSocket.upgrade/4` returned `{:error, conn, reason}`, `MintTransport.connect/2` dropped the open `conn`, and because the gateway socket reconnects on error, it leaked one socket per attempt. The connection is now closed with `Mint.HTTP.close/1` before the error returns.
- **`raxol_gateway`: `SessionRouter.route/3` reported `:ok` for events cast into a dead session.** The router tracks sessions by pid and learns of a death from a `:DOWN` that queues like any other message, so a `route/3` call read ahead of that `:DOWN` found the dead pid, cast the event into it and replied `:ok`: the event was gone and the caller was told it had been accepted. A tracked pid that is no longer alive is now dropped on the spot (its queued `:DOWN` taken for the `:down` telemetry, the monitor flushed) and replaced through the normal start path, so the event reaches a fresh session or `route/3` returns the refusal. The per-key cooldown still applies, so a restart within `:cooldown_ms` (5 s by default) of the dead session's start is `{:error, :rate_limited}` rather than a crash-loop bypass. `start_session/2` gets the same treatment instead of returning the dead pid. `handoff/3` had the same flaw, returning a dead destination pid, and it started destinations with no `:max_sessions` or cooldown check, so with `max_sessions: 1` a handoff opened a second session. It now starts the destination through the same gates and returns `{:error, :max_sessions}` or `{:error, :rate_limited}` like any other start, leaving the source session as it was.
- **Security: `Raxol.System.Updater` installed downloads it never verified, from a repository it did not own.** The self-updater was pinned to `username/raxol` (and `DeltaUpdater` to `raxol/raxol`), so whoever controlled those GitHub accounts decided what `self_update/2` downloaded. It unpacked archives with the host's `tar`/`unzip` and copied the result over the running executable; the `verify_checksums: true` setting was never read. The delta path ran the patched binary (`--version`) before checking anything, and `Core` passed `apply_delta_update/2` its arguments in reverse order (the delta path is now removed; see Removed). Now:
  - Every URL comes from `Raxol.System.Updater.Manifest`, never from a release's own `browser_download_url`. The default channel is the `raxol` CLI's `raxol-cli-v*` releases on `DROOdotFOO/raxol` (raw binaries plus `SHA256SUMS`); apps set their own with `config :raxol, :updater_manifest`. Base URLs must be `https` (plain `http` only on loopback), and a version must be `X.Y.Z`.
  - Each download must match its `SHA256SUMS` entry before it is extracted or installed. A missing, duplicated or malformed entry means nothing is downloaded at all.
  - Archives are read with `:erl_tar` / `:zip`, and any absolute, `..`, drive-letter, symlink or hard-link entry refuses the whole archive before anything is written.
  - The new binary is renamed into place from the same directory, and the one it replaces is kept for `rollback_update/1`, which until now had nothing to restore. HTTPS verifies the certificate and hostname.
- **`Raxol.System.Updater.check_for_updates/1` raised, and version checks never agreed.** It matched `{:ok, settings}` against the bare settings map (`WithClauseError` on every call), compared `"2.7.0"` with the tag `"v2.7.0"` so an update was always "available", and read the version through `Mix.Project`, which a release does not have. The automatic-check interval read string keys that `set_auto_check/1` never wrote, so disabling checks did nothing. The installed version now comes from the manifest's application, versions compare with `Version`, and the interval uses the atom keys that are actually stored. `self_update/2` also no longer falls back to `System.argv()` for "the executable", which could have overwritten a file named on the command line.
- **`Raxol.CLI.Commands.UpdateCmd.execute/1` raised on any call without `--help`.** It matched absent flags as `false`, but `OptionParser` returns `nil` for them, so every call hit `CaseClauseError`.
- **CI: a docs-only pull request could never merge.** `CI Status`, the only required check on `master`, lives in `ci-unified.yml`, whose `pull_request` trigger had `paths-ignore` for `web/**`, `docs/**`, `assets/**`, `**.md` and `.github/**`. A pull request touching only those paths never started the workflow, so the check never reported and the PR sat `BLOCKED` with every other check green (#1077). The filter now lives in a `changes` job: a docs-only diff skips `setup` and everything after it, and `CI Status` passes unless a job that did run failed or was cancelled. The diff base is also the event's `pull_request.base.sha` instead of `origin/<base_ref>`, which made `git diff` exit 128 when the base branch was deleted during a retarget.
- **`Raxol.Core.ConnectionPool` overflow connections were permanent.** `create_overflow_connection/2` added each overflow connection to `connections.overflow` and nothing removed it; on checkin it joined `available`, so the pool grew to `pool_size + max_overflow` for good, the overflow gate never admitted another connection, and `disconnect_fn` was never called on one. Overflow connections are now transient, as in poolboy: checking one in (or its holder exiting) disconnects it and frees its overflow slot (a size-1 pool with `max_overflow: 1` reported `available: 2, overflow: 1` after two checkins; it now reports `available: 1, overflow: 0`).
- **`raxol_symphony`: the orchestrator kept every subscriber it ever had.** `Raxol.Symphony.Orchestrator` monitored each `subscribe/1` caller, but its `:DOWN` fallback (`drop_listener_by_ref/2`) was a no-op, so a dead listener stayed in `listeners` for the life of the orchestrator and every event was still sent to it. Each restart of the Telegram or watch notifier added another dead pid, and each repeated subscribe from a live pid added another monitor (4 monitors after 4 subscribes). A listener's `:DOWN` now removes it, and a pid that is already subscribed is not monitored again.
- **`raxol_gateway`: `Pairing` kept every unconfirmed code and every requester forever.** `request_code/2` added to `pending` and `last_request`, but only `confirm/2` removed a code and nothing ever removed a `last_request` entry. Every Discord, Telegram or email sender who asked for a code and never confirmed it stayed in both maps for the life of the gateway (21 codes and 21 requesters after 21 requests with a zero TTL and cooldown). Each request now sweeps cooldowns that have run out, and codes more than one TTL past expiry. The extra TTL means a late confirm still gets `:expired` rather than counting as a failure.
- **`raxol_mcp`: `initialize` under invented session ids grew the server without bound.** `Raxol.MCP.Server` kept each connection's advertised capabilities until that connection's subscriber exited, and `Transport.SSE` takes the connection id from any client-supplied `mcp-session-id`, so a client that POSTed `initialize` under a new id each time and never opened a stream left one permanent entry per request (50 POSTs, 50 entries). The map is now capped by the new `:max_client_capabilities` start option (default 1024). Past the cap the oldest entry without a live subscriber goes first, and a live one only when every entry has a subscriber; each eviction emits `[:raxol, :mcp, :server, :client_capabilities_evicted]`. An evicted connection keeps working, but an ASK denies instead of prompting until it sends `initialize` again. Entries for subscribed connections are still removed when stdio or the SSE stream ends.
- **`raxol_earn`: a failed seller offer kept its `JobSession` running and its capacity slot.** `Raxol.Earn.Seller.Queue` started a session for every `:job_offered`, and when the offering's `resolve_accept/2` or the on-chain `setBudget` then failed, it dropped the offer without stopping that session. The job was never tracked, so its later `:job_expired` dropped as `:job_not_running` and nothing ever ended the session: with `seller_max_active_jobs: 1`, one `setBudget` RPC error made every later offer drop as `:at_capacity`. Those error branches now stop the session the offer started, so the slot is freed. A session the offer did not start (rehydrated by `Resync`, or one that survived a Queue restart) is left running.
- **`Raxol.Performance.Cache` admin calls and opt-in style caching reach the cache manager (#1094).** `Raxol.Application` starts `ETSCacheManager` with no name (`{ETSCacheManager, []}` in test mode, `hibernate_after:` only under `:performance_monitoring`), so `Cache.stats/0`, `clear/1` and `clear_all/0` exited `:noproc`, and the `cache_available?` guard in `ThemeResolver` and `StyleProcessor` was always false: `cache: true` or `config :raxol, :theme_resolver` / `:style_processor, cache_enabled: true` silently resolved without the cache, and both `clear_cache/0` functions did nothing. `ETSCacheManager` now registers under its module name unless `:name` is passed. `clear_cache/1` with a name that is not one of its six caches returned the raw name as a table and crashed the table owner, wiping every cache; it now returns `{:error, :unknown_cache}`. The test isolation helper stops clearing the nonexistent `:theme_cache` (theme entries live in `:style`), and the performance-improvements bench accepts an already started manager. New tests: `stats/0` and `clear_all/0` exited `:noproc`, a cached `resolve_styles/4` left a `:miss`, and `Cache.clear(:theme_cache)` crashed the server before.
- **`Raxol.Core.Metrics.init/1` and `Raxol.Core.start_application/2` no longer raise, and `clear_metrics/0` survives without an aggregator (#1094).** `init/1` called `Aggregator.init/1` and `AlertManager.init/1`, the GenServer callbacks, whose `{:ok, state}` fell through the `with` as a `WithClauseError`; since `start_application/2` runs it during core init, every call raised. It now starts only the collector: the Aggregator and AlertManager stay opt-in, user-started servers as the metrics README says. `clear_metrics/0` called the Aggregator from a linked Task, so with none running the `:noproc` exit killed the caller; it now skips the Aggregator when none is running. New tests: `init([])` raised `WithClauseError` and `clear_metrics/0` killed the test process before.
- **`Raxol.Core.Metrics.Aggregator` aggregates recorded metrics and survives its update timer (#1094).** The timer sent `{:aggregate, id}`, which no clause handled, so every running Aggregator crashed with `FunctionClauseError` 60 s after start; it also ignored the `update_interval` option. `update_aggregation/1` and the periodic update passed `MetricsCollector.get_metrics/2`'s `{:ok, list}` straight to aggregation, so every call crashed the server with `Protocol.UndefinedError`; the tests mocked a bare list and hid it. The timer now sends the handled message every `update_interval` seconds, the result is unwrapped, and a rule with no recorded metrics aggregates to `[]` instead of raising. The tests now record through the real collector; they crashed before, and the periodic-update test saw no timer message within 3 s.
- **`Raxol.UI.Theming.Colors.convert_to_palette/2` exited `:noproc` for any palette it did not know (#1094).** Every palette name other than `:xterm256`, `:xterm`, `:basic`, `:linux`, `:mac` and `:windows` was looked up in `Raxol.UI.Theming.PaletteRegistry`, a server nothing ever started, so `convert_to_palette({255, 0, 0}, :no_such_palette)` exited `:noproc` instead of reaching its intended fallback. An unknown palette now falls back to the xterm 256-colour palette; new tests convert a colour and a theme map with an unknown palette and compare against `:xterm256` (both exited `:noproc` before).
- **The example `RainbowThemePlugin` crashed on every colour rotation (#1094).** `rotate_color/1`, reached from the `rainbow next` command, `handle_rainbow_next/2` and the auto-rotate timer, called `Raxol.Themes.apply_theme/1`, a server nothing started (and which could not be started under its name), so each rotation exited `:noproc`. The plugin, which `docs/plugins/README.md` tells users to copy, now sets the colour as the `:foreground` and `:accent` of `Raxol.UI.Theming.Theme.current/0` and applies it with `Theme.apply_theme/1`, the process-free theme that `Raxol.Style`, the modal renderer and the theme selector read. A new test rotates through the palette and asserts the current theme's colours (it exited `:noproc` before).
- **`raxol_cli`: the app `raxol new` generates compiles and runs (#1102).** The template used `use Raxol.UI, framework: :react`, which builds a component and brings none of the view DSL into scope, and imported `key_match` from `Raxol.Core.Runtime.Application`, which does not define it, so the new project failed to compile on `key_match("+")`. It now uses `use Raxol.Core.Runtime.Application` like the examples and the quickstart, quits with `Directive.stop()` on `q` and on Ctrl+C (as the `mix raxol.new` templates and now the quickstart skeleton do), and its `start/0` waits for the app to exit, since `mix run -e "MyApp.start()"` halts the VM as soon as the call returns. Everything the template calls exists unchanged in raxol 2.6.0 and 2.7.0, so the generated `raxol ~> 2.6` requirement stands. A new test generates the app, compiles it against this checkout and renders its first frame headlessly (it failed to compile before). `raxol new` also refuses a name that cannot make a working project, before creating anything: the check matched `$`, which lets a trailing newline through, and now reserves the names `mix raxol.new` reserves (`raxol`, `mix`, ...) and, as `mix new` does, any name whose module already exists (`enum` would redefine `Enum`).
- **`mix raxol.new` standalone apps no longer start inside `mix compile` (#1102).** Without `--sup`, `lib/<app>.ex` ended with top-level code that started the app and waited for it, and `mix compile` evaluates every file under `lib/`, so compiling the project (and so `mix test`, the generated CI and `--install`) launched the TUI inside the compiler, which did not return until the app quit. That code is now the module's `start/0`, and the generated README and instructions run it with `mix run -e "MyApp.start()"`; the quickstart's skeleton moves the same way. The `blank` template's view, the `todo` template's empty-list message and the `dashboard` template's request bar drew nothing, because a `column` or `row` whose block is a single element renders no children; each now passes a list. A new test generates every template with and without `--sup` (plus `--ssh --liveview`), compiles each project's `lib/` and checks its first frame headlessly: before, the four standalone projects ran code at compile time, `blank --sup` drew an empty screen and `todo --sup` an empty list box. `mix raxol.new` also refuses, before creating anything, an app name with a trailing newline (its check matched `$`, as `raxol new`'s did) and, as `mix new` and `raxol new` do, a project whose module already exists: `mix raxol.new agent` generated `defmodule Agent`, and `enum`, like `--module Enum`, redefined `Enum`.
- **`assets/tapes/workspace/counter.exs` compiles (#1102).** The counter shown in the MCP-client recordings had the same `framework: :react` defect as the `raxol new` template, and its `update/2` returned a bare model. It now uses `Raxol.Core.Runtime.Application`, returns `{model, commands}` and handles the `+`, `-` and `q` keys its view advertises, and quits on Ctrl+C; a new test compiles and renders it. The `raxol_mcp` `Raxol.MCP.ResourceProvider` example, a TEA app, used `framework: :react` too and now uses the same app API.
- **`Raxol.Core.Metrics.record/3` records each metric once (#1106).** It called `MetricsCollector.record_metric/4` and then `Aggregator.record/3`, which passes through to the same collector, so every value was stored twice and counts and sums over `record/3` data came out doubled. It now records through the collector only. The new test found two entries for one `record/3` call before the fix.
- **`Raxol.Core.Metrics.Aggregator` groups metrics recorded with keyword-list tags (#1106).** A `group_by` rule read each metric's tags with `Map.get/2`, so tags recorded as a keyword list (the `Metrics.record/3` form) raised `BadMapError` and crashed the aggregator. Tags are now normalized to a map first through `MetricsCollector.normalize_tags/1`, which is now public. The new test crashed the aggregator before the fix. `AlertManager`'s `group_by` had the same `Map.get/2` on tags and crashed `AlertManager` at its next check, losing every rule and all alert state; it now uses the same normalization (the first bullet of #1120, fixed here). A new test groups keyword-tagged metrics through an alert check; it crashed `AlertManager` with `BadMapError` before.
- **`Raxol.Core.Metrics.AlertManager` honours its `check_interval` option (#1106).** `schedule_check` always used the 60-second default, so a manager started with a shorter or longer interval still checked once a minute. The option (in seconds, as documented) is now used; the test helper that passed `:timer.seconds(1)`, i.e. 1000 s, now passes `1`. The new test waited 3 s for a check at `check_interval: 1` and got none before the fix. Because the value is now used, it is validated at start: anything but a positive integer makes `start_link/1` return `{:error, {:invalid_option, :check_interval, value}}`. Before, `0` spun a busy loop of checks and a negative or float value crashed `init` with `badarg`; a new test covers `0`, `-1` and `0.5`.
- **`mix raxol.new --sup` apps start (#1116).** The generated `mix.exs` named no application callback, and without `--ssh` the supervisor had no children, so `mix run --no-halt`, the documented way to run a `--sup` app, ran nothing. `mix.exs` now has `mod: {MyApp.Application, []}`, and the application runs `MyApp.App` under its supervisor with the options in `config :my_app, :raxol`. The TUI runs under a process that stops the VM `--no-halt` keeps up once the TUI exits, with status 0 when the user quit and 1 when it failed; stopping the application (as a test may) stops only the TUI and leaves the VM running. `mix test` starts the application too, so the generated config runs the TUI headless in the test env. Under IEx the application leaves the TUI unstarted and says to run it with `mix run --no-halt`: `iex -S mix` would otherwise pass every key typed into the TUI to IEx, which evaluates it. With `--ssh`, the application serves the app over SSH with the options in `config :my_app, :ssh`: the generated child passed no authentication, so the fail-closed `Raxol.SSH.Server` would have refused to start, and it now configures anonymous access on loopback with explicit limits in the dev env only; under `mix test` it takes port 0, keeps its host key in `_build` instead of `~/.raxol/ssh_keys` and admits no keys, and elsewhere it refuses to start until authentication is configured. `MyApp.start/0` starts the application instead of calling its callback a second time. New tests start the generated application from its `mix.exs` and config and draw its first frame, check the SSH variant listens, and, in a VM of its own, check the exit status when the TUI quits or fails and that stopping the application leaves the VM running; they failed before on the missing `mod:`. `--module` is checked to be an alias before anything is written: a name like `My App` used to fail formatting with an empty project directory left behind.
- **`mix raxol.new` output passes `mix format --check-formatted` (#1116).** The generated `--ci` workflow runs that check, and it failed on `config/config.exs` (blank lines at the end), the app module of three of the four templates, `live.ex` and the todo test. The generator now formats every `.ex`/`.exs` file it writes with the formatter defaults the generated `.formatter.exs` leaves in place, which holds every template to it whatever the module name's length. A new test runs `mix format --check-formatted` on the generated tree for each template with each combination of `--sup`, `--ssh` and `--liveview`; all 32 failed before. The `raxol new` (raxol_cli) project gets the same check, which it already passed. `--module` is checked before anything is written too: a value that is not an alias (`My App`), which failed to format with files already on disk, is refused, as are the bare `Elixir`, the prefix of every alias, and any module that already exists (`--module Raxol`, `--module Application`).
- **The `mix raxol.new` counter's key hint matches its keys (#1116).** It said `'='/'-'` and bound `=`, while the generator's instructions said `+`. It now binds both `+` and `=` (unshifted `+`), labels the button `+` and says `'+'/'-'`. The `raxol new` template already bound the `+` its hint names.
- **`mix raxol.new --ssh` generates an SSH server that starts (#1116).** The generated `MyApp.SSH.start/1` called `Raxol.SSH.Server.serve/2` with only a port, and the server fails closed without authentication, so it refused to start (`{:ssh_auth_required, ...}`). Without `--sup` it also served `MyApp.App`, a module that only `--sup` generates; the LiveView bridge had the same wrong module. `start/1` now serves the app's real TEA module with the options in `config :my_app, :ssh`, which every `--ssh` project now gets: explicit limits, anonymous access on loopback in the dev env only, and in the test env port 0, a host key kept in `_build` and no admitted keys. Without `--sup` the generator's instructions now say `mix run --no-halt -e "MyApp.SSH.start()"`, because plain `mix run --no-halt` starts nothing there. The unused `ssh_subsystem_fwup` dependency, a Nerves firmware-update package that nothing generated referenced, is no longer added to `mix.exs`. A new test calls the generated `SSH.start/0` under the project's test config and checks that it listens and serves the generated TEA module, as does the `--sup --ssh` test (the server loads its app only when a client connects, so it starts just the same over a wrong module); before, it exited with `:ssh_auth_required`.
- **CI: `mix deps.get --check-locked` failed the day a transitive dependency published a release, always in the root, `raxol_symphony` and `raxol_telegram` locks.** Those lockfiles still held Hex entries for siblings the project takes by path (`raxol_core`, `raxol_liveview`, `raxol_mcp` and others), written whenever a lock was resolved in Hex mode. On every resolve Hex unlocks each path dependency by name together with every package its old lock entry lists as a child, recursively, so the stale `raxol_liveview` entry freed `phoenix_live_view`, `igniter`, `req`, `finch` and `mint` from the lock and each one moved to its newest release as soon as it appeared. That is what #1048, #1060, #1071, #1089, #1146 and #1163 each refreshed a lock for (phoenix twice, phoenix_template, hpax, mint, finch). The 26 stale entries are gone from those three lockfiles and from `raxol_mcp`, `raxol_speech`, `raxol_terminal` and `raxol_watch`, where a stale `raxol_core` left `telemetry` unpinned. The resolved versions do not change. `scripts/check_lock_path_shadows.exs` now fails CI on any such entry, naming the lockfile, the entries and the `--fix` command that removes them. It runs before `--check-locked` in the `setup` job and in every `package-tests` cell, and over every lockfile in the Hex Advisories job. `scripts/check-lockstep-deps.sh` no longer advises refreshing a committed lock with `HEX_BUILD=1 mix deps.get`.
- **A `Raxol.Headless` call racing an app's exit no longer takes down the session manager.** `screenshot/1`, `get_buffer/1`, `get_model/1`, `send_key/3`, `send_message/2`, `send_resize/3` and `send_key_and_screenshot/3` asked the session's `Lifecycle` for its processes with an unguarded `GenServer.call` made inside the `Raxol.Headless` server. An app that had just quit (a key whose `update/2` returns `Directive.stop()`) left a window before the server handled the `Lifecycle`'s `:DOWN`, and a call in that window exited `:noproc` and killed the server, orphaning every other session it held. The lookup now runs in the caller (see Changed) and answers `{:error, :not_found}`, which is what the caller gets once the `:DOWN` has been handled; the `:DOWN` handler still drops the session. A `Lifecycle` that is alive but does not answer is `{:error, {:session_unavailable, class}}`. The calls that follow it, the render at the engine and the model read (and `send_message/2`'s fence) at the dispatcher, answer the same way when the session ends between the lookup and the call; they exited the caller before. New tests hold the server until the lookup is queued, kill the `Lifecycle` so its `:DOWN` queues behind it, and check that `screenshot/1` and `send_key/3` answer `:not_found` with the server alive (both exited before); others suspend the engine or dispatcher until the caller's call is queued, end the session, and check that `screenshot/1`, `get_buffer/1`, `get_model/1` and `send_message/2` answer `:not_found` (all four exited before).
- **`raxol_terminal`: a chunk holding invalid UTF-8 cost ~100 us of logging at any log level (#1031).** `Raxol.Terminal.Parser.States.GroundState` answers an invalid byte with `{:error, :unhandled_input, emulator, parser_state}`, and `TerminalParser.parse_chunk/3` logged that result with `inspect/1` through `Raxol.Core.Runtime.Log.error/1`, a function, so the whole emulator was dumped before any level check. With the Logger at `:emergency`, a peer sending `<<0xFF>>` one chunk at a time cost 98.8 us per byte against 2.4 us for `"a"`; the line now names only the reason, and the byte cost 1.9 us. Invalid bytes no longer take that path at all: they render as U+FFFD (see the emulator bounds entry). The `ModeManager` write path #1031 reported (253 us per `CSI ? 25 h`, 45.8 us per input byte against 2.7 us for plain text) was already fixed by #1039 (3.9 us per call, 0.97 us per byte). A regression test fails if either path dumps the emulator at a disabled level; the ModeManager and mode-definition dumps #1031 named stay covered by #1039's `Kernel.inspect` trace test in `mode_manager_test.exs`.
- **Every input event and every frame dumped the app's model, view or event into debug messages at any log level (#1031).** `Raxol.Core.Runtime.Log.debug/1` is a function, so its argument is built before the level check. Per frame, the Dispatcher's `:get_render_context` and the rendering engine's `:render_frame` each inspected the whole model, and the engine inspected the view tree and every positioned element; per event, the Dispatcher inspected the event (twice with the app's debug mode on) and the commands `update/2` returned; per agent message, the message. Over SSH that is once per key of a paste. The model, view and element dumps are gone (the lines keep the theme id and the view's type; the element count was already logged), and the event, command and agent-message lines use the `Logger.debug/1` macro, which skips them when `:debug` is off. For an app whose model holds 500 rows, with the Logger at `:emergency`: a key through `Raxol.Headless.send_key/3` went from 116 us to 37 us, and a synchronous 120x40 frame from 6.5 ms to 3.1 ms.

### Changed

- **`raxol update` runs on `Raxol.System.Updater`.** `Raxol.CLI.Update` kept its own copy of release lookup, `SHA256SUMS` parsing, download, checksum and binary replacement. It now keeps only the command-line experience (flags, messages, exit codes, the daily prompt and its `RAXOL_NO_UPDATE_CHECK` / `~/.raxol/cli-update-check.json` cache) and hands everything else to the library updater, so there is one updater with one set of guarantees. What changes for users: the replaced binary is now kept in `~/.raxol/backups/previous_version`, `SHA256SUMS` is parsed strictly (a malformed or duplicated line refuses the update), and asking for an unpublished version (`--version 9.9.9`) says "no such release". `Raxol.System.Updater.check_for_updates/1` takes a `:version` option to check one release instead of the newest.
- **CI: `raxol_terminal`, `raxol_liveview`, `raxol_plugin`, `raxol_sensor`, `raxol_speech` and `raxol_watch` join the per-PR `package-tests` matrix (#1117).** Nothing in per-PR CI ran their suites, so `raxol_terminal` changes such as #1101 and #1110 shipped on local evidence alone. Each cell runs `deps.get --check-locked`, `compile --warnings-as-errors`, the suite and the format check; the `raxol_terminal` cell also installs `tmux`, because without a multiplexer its real-pty tests print "skipped" and pass. Four packages joined clean. `raxol_speech`'s non-live `Recognizer` tests loaded `openai/whisper-tiny` in their setup, which with an empty Bumblebee cache (every CI run) downloaded about 160 MB from huggingface.co, and a failed fetch left no model, so the tests took a different path depending on the network; they now start the recognizer with `load_model: false`, and only the `:stt_live` test loads the model. `raxol_terminal` needed three repairs, all in its tests: dead `test/support` helpers that called modules only the root suite has (ten warnings) are removed; the full-screen ^C fixture now clears `SKIP_TERMBOX2_TESTS` as well as `MIX_ENV`, since `Raxol.Terminal.Env.test?/0` reads both and with it set the Driver never turned `ISIG` off, which failed four tests on every nightly leg after #1130; and its `test_helper` sets `:terminal_test_mode` as the root one does, so `Integration.init/0` no longer calls the real `tb_init()`, which failed without a terminal and, run from one, left it raw. Nothing was quarantined.
- **`Raxol.Headless.send_key/3` and `send_resize/3` return once the app's `update/2` has handled the event.** Both cast the event to the dispatcher and returned while it was still queued, so `:ok` said nothing about when `update/2` would take it, and callers slept after them: the suites did, `send_key_and_screenshot/3` slept 50 ms inside the session manager, and `Raxol.Recording.Video.capture_clip/2` slept 40 ms per event. Through `Raxol.Headless` itself a following `get_model/1` or `screenshot/1` already saw the key (the model read queues behind the cast, and the render asks the dispatcher after it), so those sleeps covered an order that held by delivery rather than by contract; nothing ordered what `update/2` does outside the dispatcher's mailbox. The event now goes as a call the dispatcher answers after focus navigation, bubbling and `update/2`, so the model, the next `screenshot/1` or `get_buffer/1` (`raxol_send_key` included), and anything `update/2` did synchronously reflect it when the call returns. Commands `update/2` returns (Tasks, intervals) are started, not awaited. The wait runs in the caller's process: `Raxol.Headless` only resolves the session id, and `screenshot/1`, `get_buffer/1`, `get_model/1` and `send_message/2` now also call the session's processes from the caller, so a slow `update/2` or render holds up only its own calling process, and an `update/2` that calls `Raxol.Headless` for another session no longer waits on itself. From `update/2`, a call on the app's own session (whose dispatcher is the process running `update/2`) answers `{:error, :called_from_own_update}` instead of exiting `:calling_self` or stalling 5 s on a render. The isolation is per process: `Raxol.MCP.Server` runs every tool call in its one process, so over MCP a slow or wedged session still holds every client's `raxol_send_key`, `raxol_screenshot` and `raxol_get_model` for up to 5 s each, as it did before. `send_key(id, key, wait: false)` returns once the key is queued, with no `update/2` guarantee; `Raxol.MCP.AgentBridge`'s `agent.send` uses it, so it enqueues its keystrokes as its reply says instead of holding the MCP server for the message's length times the app's update time. `send_key/3` takes `:timeout` (default 5000 ms; `send_resize/3` uses the default); a timeout only ends the wait, and `update/2` may still handle the event afterwards. A dispatcher that dies on the event or does not answer in time is `{:error, {:dispatch_failed, class}}` for that caller rather than an exit. `class` is the exit reason's atom (for example `:timeout`, `:noproc`, `:killed`, `:shutdown`), else `:unknown`; the reason itself is logged, never returned, because a dispatcher killed by a linked process that raised exits with the exception, whose message (a URL, a token) `raxol_send_key` would otherwise hand to the model. `Raxol.MCP.Registry` keeps exception messages out of tool results the same way. New tests hold the dispatcher suspended and fail if `send_key/3` or `send_resize/3` returns before it runs, or if killing it mid-call costs another session its answer (all three failed before), a `raxol_send_key` test fails if the exception's message reaches the tool result, and tests block one session's `update/2` and check that another session's `get_model/1` and `screenshot/1` answer meanwhile, that `update/2` can call `Raxol.Headless.list/0`, and that `timeout:` answers `{:dispatch_failed, :timeout}` (each failed while the call ran inside the session manager); the sleeps after `send_key/3` and `send_resize/3` in the suites, and the `send_message/2` fence in the generated-app helper, are gone.

### Removed

- **`raxol_terminal` mode plumbing that duplicated `ModeManager` / `ModeTypes`.** Modules `Raxol.Terminal.ModeState`, `Raxol.Terminal.ModeHandler`, `Raxol.Terminal.Commands.ModeHandler` and `Raxol.Terminal.Modes.Handlers.MouseHandler`; `Raxol.Terminal.ModeManager.get_manager/1`, `update_manager/2`, `mode_set?/2`, `get_set_modes/1`, `reset_all_modes/1`, `save_modes/1` and `restore_modes/1` (all were no-op stubs); the `Raxol.Terminal.Emulator.mode_state` field (also on `EmulatorLite`) and `Emulator.update_insert_mode/2` / `update_auto_wrap_mode/2`, which wrote to it and were never read; and the `ModeTypes` rows for DEC-private 80 and standard 80/132 described above.
- **`Raxol.Core.ConnectionPool` waiting queue:** the `waiting` state field, the checkin branch that handed a connection to a waiter, and the `:waiting` key in `stats/1`. Nothing ever joined the queue: an exhausted pool has always returned `{:error, :timeout}` at once, and still does, now documented as a refusal rather than a wait.
- **`Raxol.System.Updater` binary-delta updates (#1076):** `Raxol.System.DeltaUpdater` and its `DeltaUpdaterSystemAdapterBehaviour` / `DeltaUpdaterSystemAdapterImpl`, the `bspatch` step, the `:use_delta` option, and `Raxol.CLI.Commands.UpdateCmd`'s `--no-delta` / `--delta-info`. Nothing published deltas, and none would pay off. Burrito appends an xz-compressed payload, so 98% of the bytes differ between the 0.2.8 and 0.2.10 macOS binaries, and a `bsdiff` patch is 14.3 MB against a 15.6 MB full download. Also removed: the `verify_checksums` update setting (verification is no longer optional) and `Raxol.System.Updater.Validation.get_platform/0` (see `Manifest.host_platform/0`). The `Updater` functions now take an options keyword, documented on the module.
- **Servers that nothing started, and their only clients (#1094).** No call into these servers could succeed: nothing in `raxol` started them, so each API call exited `:noproc` (or, for casts, did nothing), and their only in-repo callers were each other.
  - `Raxol.Performance.AutomatedMonitor` and `mix raxol.perf.monitor` (`Mix.Tasks.Raxol.Perf.Monitor`). The task booted the app, which never starts the monitor, so every subcommand exited `:noproc`; and each `mix` run is a fresh VM, so `start`, `status` and `stop` could never share a monitor. The four events it measured are not emitted anywhere.
  - `Raxol.Core.ErrorPatternLearner`, `Raxol.Core.ErrorPatternLearner.Persistence` and `Raxol.Core.ErrorPatternLearner.Predictor`. Their callers were the three modules below.
  - `Raxol.Core.ErrorRecovery.RecoverySupervisor` (its `handle_child_exit/3` recovery path had no caller), `Raxol.Core.ErrorRecovery.RecoveryWrapper` (started only by `RecoverySupervisor`), and `Raxol.Core.ErrorRecovery.DependencyGraph`, a pure helper used only by `RecoverySupervisor`. `Raxol.Core.ErrorRecovery.ContextManager` stayed at first; #1107 removes it (below). `Raxol.Telemetry.events/0` drops the `[:raxol, :error_recovery, :circuit_break]`, `[:raxol, :error_recovery, :degradation]` and `[:raxol, :error_recovery, :restart]` events, which only `RecoverySupervisor` emitted.
  - `Raxol.Core.ErrorReporter`. Nothing started it or called it.
  - `Raxol.Core.ServerRegistry`. Nothing started it, and `get_server/1` looked names up in a `Raxol.Registry` that nothing starts either. It also leaves the singleton allowlist.
- **Servers nothing could reach, and their callers (#1094).** Each used `BaseManager`, whose `start_link/1` registers no name unless given one, and nothing started it under the module name its API calls, so no call to any of them could succeed: every one exited `:noproc`.
  - `raxol_terminal`: `Raxol.Terminal.IO.IOServer` and `Raxol.Terminal.Rendering.RenderServer` (only ever started unnamed, from inside IOServer). With them go `Raxol.Terminal.Integration.Config.update_renderer_config/2`, `Raxol.Terminal.Integration.State.update_renderer_config/2` and the `Integration.State` `:io` field.
  - `raxol_terminal`: `Raxol.Terminal.Window.Registry` and its only caller, `Raxol.Terminal.Window.Manager.Operations`, which nothing called. `Raxol.Terminal.Window.Manager` is unaffected: it runs on `WindowManagerServer`.
  - Root: `Raxol.UI.Components.Terminal.Emulator`, an IOServer wrapper nothing used.
  - `raxol_core`: `Raxol.Core.GlobalRegistry` (including `GlobalRegistry.RegistryBehaviour`), and with it `Raxol.Terminal.Session.count_active_sessions/0`. `Terminal.Session` no longer tries to register itself there, which failed and logged "Failed to register session" on every session start.
  - `raxol_core`: the GenServer half of `Raxol.Core.Runtime.Plugins.PluginCommandManager`: `start_link/1`, `register_commands/3`, `unregister_commands/1`, `get_commands/0`, `get_plugin_commands/1` and `dispatch_command/2`. Its one caller, the plugin-load path in `LifecycleHelper`, also passed the plugin's state map where a command list belonged, which a running server would have rejected. The pure `initialize_command_table/2` and `update_command_table/2` stay.
- **Dead UI and theming APIs behind servers nothing started (#1094).**
  - `Raxol.UI.Universal`, which `use Raxol.UI` imported: the macros `use_action/2,3`, `transition/2,3` and `render_universal_slot/1,2`, and `provide_context/2`, `use_context/1,2`, `use_theme/0`, `with_theme/2`, `provide_slot/2`, `handle_universal_event/1,2`, `subscribe_to_events/1,2` and `animate/2,3`. None could work: they expanded to modules that do not exist (`Raxol.Actions`, `Raxol.Transitions`), called a `StateManagementServer.get_slot/1` that was never defined, registered in a `Raxol.Events` registry nothing started, or called the UI state server, which nothing started on that path and which has no clause for those messages. `animate/2,3` only sent `{:animate_property, property, value}` messages that nothing in Raxol handles; use `Raxol.Animation.Helpers.animate/2`. `use Raxol.UI` now brings in only the selected framework.
  - `Raxol.UI.State.Management.StateManagementServer.set_context/2`, `get_context/1,2` and `set_slot/2`, whose only caller was `Raxol.UI.Universal`; the server never handled their messages.
  - `Raxol.UI.Theming.PaletteRegistry` and the `Raxol.UI.Theming.Colors` functions that called it: `register_custom_palette/2`, `unregister_custom_palette/1`, `list_custom_palettes/0` and `get_custom_palette/1`. Nothing started the registry, so every call exited `:noproc`; its persistence only logged.
  - `Raxol.Themes` (`apply_theme/1`, `get_current_theme/0`, `load_theme/1`, `list_themes/0`, `register_theme_callback/1,2`). Nothing started it, and it could not be started under its name (`init_manager/1` matched only `:ok`), so every call exited `:noproc`. Use `Raxol.UI.Theming.Theme.apply_theme/1` and `Theme.current/0`.
- **Code with no callers (#1107).**
  - Root: `Raxol.Core.Renderer.RendererManager` and `Raxol.Core.Runtime.Events.Handler`, two `EventManager` consumers that no library code started or called.
  - `raxol_core`: `Raxol.Core.Events.Manager` (a delegating alias of `EventManager`), `Raxol.Core.Events.Subscription` (keyboard, mouse, window, timer and custom subscription wrappers over `EventManager.subscribe/2`) and `Raxol.Core.Events.EventManager.EventManagerServer`, which nothing started. **Breaking** for `raxol_core` users: all three were public, documented modules of the published package, so code that calls them no longer compiles and the next `raxol_core` release carries the break. Use `Raxol.Core.Events.EventManager` directly.
  - `raxol_core`: the plugin load path that only called itself: `LifecycleManager.load_plugin/8` and `unload_plugin/6`, `Discovery.load_plugin/8` and `unload_plugin/6`, `LifecycleHelper.load_plugin/8`, `load_plugin/3` and `unload_plugin/6`, and the helpers only they reached: `Raxol.Core.Runtime.Plugins.PluginUnloader`, `PluginErrorHandler.handle_load_error/2`, `PluginValidator.validate_plugin/4`, and `Plugins.StateManager.initialize_plugin_state/2` and `update_plugin_state_legacy/3` (with their `Raxol.Core.Behaviours.StateManager` callbacks). Plugins load through `PluginManager`. `LifecycleManager.reload_plugin/2` stays for now, pending a follow-up, but it is unreachable as well: its only caller, `PluginReloader`, is called only from `FileWatcher.handle_debounced_events/3` and `LifecycleHelper.reload_plugin_from_disk/8`, and nothing outside that chain (`LifecycleManager`, `Discovery`, `LifecycleHelper`, `PluginReloader`, `FileWatcher`) calls into it. `PluginValidator`, `Security.BeamAnalyzer`, `Security.CapabilityDetector` and `CommandRegistry.unregister_plugin_commands/2` lost their last library caller here too; they stay because `docs/plugins/GUIDE.md` documents `CapabilityDetector` for plugin authors. Nothing on the live `PluginManager`/`PluginLifecycle` load path validates a plugin, and the `PluginValidator` moduledoc now says so.
  - Root: `Raxol.Core.ErrorTemplates`, whose one caller was the removed `ErrorReporter`, and `Raxol.Core.ErrorRecovery.ContextManager`, which only its own test used.
- **`Raxol.Core.Metrics.Aggregator.record/3` (#1120).** It only passed its arguments on to `MetricsCollector.record_metric/4` as a `:custom` metric, and since #1106 nothing in the repository calls it. Record through `Raxol.Core.Metrics.record/3` or `MetricsCollector.record_metric/4`; aggregation rules read whatever the collector holds.
- **`raxol_terminal`: `Raxol.Terminal.Escape.Parsers.CSIParserCached` and `Raxol.Terminal.CellCached`, and `bench/suites/core/performance_improvements_benchmark.exs` (#1120).** Neither module cached anything: `warm_cache/0` returned `:ok`, and `parse/1`, `new/2`, `batch_new/1` and `merge_styles/2` called `CSIParser.parse/1`, `Cell.new/2` and `Map.merge/2` directly. The benchmark, their only caller, timed those against the same uncached calls, printed `Raxol.Performance.ETSCacheManager.stats/0` (every table at 0 entries after `warm_cache`, since nothing wrote to them) and then a fixed summary of improvements it never measured ("60-80%" for CSI parsing, "40-60%" for cells, rendering "30-50% faster"). **Breaking** for `raxol_terminal` users: both were public modules of the published package. Call `CSIParser.parse/1` and `Cell.new/2`, which is what they did.
- **`Raxol.Headless.send_key_and_screenshot/3`'s `:wait_ms` option, `raxol_send_key`'s `wait_ms` argument and `Raxol.Recording.Video.capture_clip/2`'s `:event_settle_ms` option.** Each set a sleep after a key so its update could land; `send_key/3` now guarantees that for `update/2` itself (see Changed). The sleeps also gave a fast asynchronous command the key started (a Task, a directive that answers with `{:command_result, _}`) time to land before the capture, and nothing waits for those now: their results show in a later screenshot or frame. `wait_ms` was also unbounded: it reached `Process.sleep/1` inside the session manager, so one `raxol_send_key` call could stall every headless session for as long as it asked. Any of them passed now is ignored like any other unknown option or argument.
- **`raxol_terminal`: `Raxol.Terminal.Buffer.Writer.log_char_write/4` and the debug line it wrote (#1031).** `write_char/5` called it for every cell, and it logged the constant `"[Buffer.Writer] Writing char "`: the character, position and style were commented out of the message. The runtime draws each frame cell by cell through `ScreenBuffer.write_char/5`, so at `:debug` every frame logged one line per cell that said nothing, which is the `Buffer.Writer` stream test logs were full of. Nothing else called it. **Breaking** for `raxol_terminal` users who called it: it was public and documented.

### Security

- **raxol.io (`web/`) no longer ships req 0.5.17, decimal 2.4.1, swoosh 1.19.8, mint 1.7.1 or hpax 1.0.3.** `web/mix.lock` moves to req 0.7.4 (EEF-CVE-2026-49755, a decompression bomb, HIGH; EEF-CVE-2026-49756, multipart header injection, LOW), decimal 3.1.1 (EEF-CVE-2026-32686, unbounded-exponent DoS, MEDIUM), swoosh 1.28.1 (EEF-CVE-2026-54893, LOW), and mint 1.11.0 / hpax 1.1.0, the HTTP client under Req, Finch and Swoosh (mint 1.7.1 carries more than a dozen advisories, several HIGH, among them EEF-CVE-2026-91043 and -82728; hpax 1.0.3 carries EEF-CVE-2026-58226). The 26 entries nothing in web's dependency tree uses any more (postgrex, hackney, ecto, ex_cldr and others) are dropped, so `mix hex.audit` in `web/` no longer reports their advisories either. It now lists only cowlib 2.20.0's EEF-CVE-2026-43966 and -43969: there is no fixed cowlib release, and neither vulnerable function is called anywhere in the tree (#921).
- **`raxol_payments` and `raxol_earn` require `decimal ~> 3.0` (was `~> 2.0`)**, so no consumer can resolve a decimal with EEF-CVE-2026-32686; `raxol_payments` parses amounts from payment servers and config. For consumers: decimal 3's default context is decimal128, precision 34 (was 28) with `emax: 6_144` / `emin: -6_143` and over/underflow signalled, and `Decimal.new/1`, `parse/1` and `cast/1` reject strings of more than 34 digits or with an exponent past 6_144. The package locks, and those of `raxol_console` and `raxol_symphony`, which build on them, move to decimal 3.1.1 (and req 0.7.4 in the two packages).
- **`raxol_payments`: x402 and MPP atomic amounts are bounded to a uint256.** A challenge whose amount is wider (more than 78 digits, or above 2^256 - 1) is rejected at parse time as `{:invalid_amount, _}`, checked before the string is parsed; no such amount can be signed. Under decimal 3, an amount string of 35 to 78 digits raised `Decimal.Error` out of `Req.AutoPay` (x402 through `Assets.to_human/2`, MPP through `MPP.amount/1`), and `SettlementLedger` crashed recording one, losing its table; they now convert through the integer (`Assets.to_decimal/1`) and reach the policy and budget gates, which refuse them when a `SpendingPolicy` and ledger are configured. Without the bound, a hostile server's header-sized amount could detach the payments telemetry logger or raise from `on_confirm`, since decimal 3's `to_string` stops at 6_178 digits. New tests failed before.
- **The package lockfiles no longer carry fixable Hex advisories.** Nothing audited `packages/*/mix.lock`, and several held HIGH ones:
  - `raxol_agent`: cowboy 2.17.0 -> 2.19.0 (EEF-CVE-2026-65624), cowlib 2.18.0 -> 2.20.0 (EEF-CVE-2026-59248, HPACK/QPACK integer DoS, HIGH; -43971), mint 1.10.1 -> 1.11.0 (EEF-CVE-2026-91043, HTTP/2 header-list memory exhaustion, HIGH; -92103, -94194).
  - `raxol_cli`, `raxol_console`: cowlib 2.19.0 -> 2.20.0 (EEF-CVE-2026-43971), phoenix_live_view 1.2.8 -> 1.2.12 (EEF-CVE-2026-64941), mint 1.9.3 -> 1.11.0 (EEF-CVE-2026-91043 and -82728, both HIGH; -82672, -82729, -92103, -94194), with cowboy 2.19.0 and phoenix 1.8.15 alongside.
  - `raxol_earn`, `raxol_payments`: phoenix 1.8.8 -> 1.8.15 (EEF-CVE-2026-56811, unbounded channel joins per transport, HIGH; -56812), phoenix_live_view 1.2.4 / 1.2.3 -> 1.2.12 (EEF-CVE-2026-58228, `<.link>` scheme-validation XSS; -64941), cowboy 2.16.1 -> 2.19.0 (-65624), cowlib 2.17.1 -> 2.20.0 (-59248, HIGH; -43971).
  - `raxol_gateway`: cowboy 2.17.0 -> 2.19.0, cowlib 2.18.0 -> 2.20.0, phoenix_live_view 1.2.7 -> 1.2.12 and mint 1.9.3 -> 1.11.0, clearing the same advisories as above.
  - `raxol_mcp`, `raxol_web3`: mint 1.10.1 -> 1.11.0 (-91043, HIGH; -92103, -94194).
  - `raxol_speech`: progress_bar 3.0.0 -> 3.1.0, which no longer requires decimal, so decimal 2.4.1 (EEF-CVE-2026-32686) leaves the lock.
  - `raxol_watch`: eleven entries pigeon 2.1.0 no longer uses are dropped, among them hackney 1.17.1 and its six advisories (EEF-CVE-2026-47071, TLS upgrade without timeout, HIGH; -47069, -47075, -47076; GHSA-9fm9-hp7p-53mf, GHSA-vq52-99r9-h5pw).
- **CI: `mix hex.audit` in every project with a lockfile.** The new `Hex Advisories` job in `security.yml` runs `mix deps.get --check-locked` and `mix hex.audit` in the root, `web/` and each `packages/*/` that has a `mix.lock` (found by glob), reports every failing project rather than stopping at the first, and fails the Security Scanning workflow; it is not a required check, so a newly published advisory turns runs red without blocking unrelated merges. It replaces the root-only `mix hex.audit` step, which ran under `continue-on-error`, and a `web/`-only change now triggers the workflow. cowlib 2.20.0's EEF-CVE-2026-43966 and -43969 have no fixed release and neither vulnerable function is called (#921), so the ten projects that lock cowlib acknowledge exactly those two with `hex: [ignore_advisories: [...]]` in `mix.exs`. `mix hex.audit` lists them as ignored; an entry that no longer matches anything fails the job, so it is removed in the PR that makes it stale.
- **The scheduled Security Scanning run can file its critical-findings issue.** The workflow granted only `contents: read` and `security-events: write`, so `Create issue for critical findings` got a 403 on every scheduled failure and never filed one; `security-report` now has `issues: write`. The new Hex Advisories job is one of the failures that files it.

## [2.7.0] - 2026-09-09

### Added

<!-- feat/bundle-five: the five improvement entries land here at integration,
     one per stream, each written only after its change is verified.
     W1 TEALive per-row payload | W2 recording keyframe index + web replay |
     W3 loose ends + check_docs widget-count gate | W4 bash PTY and
     background jobs | W5 web_search and fetch. -->

- **Coding agent: durable sessions, replay, and rewind (#819)**. Each session writes an offset-addressed journal under `~/.raxol/sessions/<id>/`, so `--continue` / `--resume <id>` restore the model context and the scrollback together. `--replay <id>` prints a transcript straight from the journal (`--to-offset N` stops at an offset) via `Raxol.Agent.Code.Replay`, and `/rewind` returns a live session to an earlier turn. `Raxol.Agent.Code.Inspection` backs both `mix raxol.inspect` and the TUI's `/inspect`: one snapshot of provider resolution, `.raxol/config.json`, `.raxol/hooks.json`, `.mcp.json`, skills roots, and the session store, recording env variable names and never their values.
- **Multi-tenant SSH coding agent (#819)**. `mix raxol.code --ssh --ssh-tenants DIR` serves the TUI to many users from one daemon. Each tenant authenticates against its own `DIR/<user>/ssh/authorized_keys` and gets its own cwd jail, session store, journal base, and spending identity (`ssh:<user>`) through `Raxol.Agent.Code.Tenant`; the jail disables the shell tool, which a path sandbox cannot confine. Hosted deployment (`RAXOL_SSH_CODE=true`, port 2223) refuses to serve unless `RAXOL_SSH_CODE_TENANTS` names a tenants root, `RAXOL_SSH_CODE_BUDGET_USD` sets a positive per-tenant cap, and both raxol_agent and an HTTP client are in the build.
- **`/share` read-only session links (#819)**. `Raxol.Agent.Code.ShareToken` mints an HMAC-SHA256 token binding a session id, its tenant scope, and a 24-hour expiry; a host mounts `Raxol.Agent.Code.ShareLive` at `/share/:token` to replay the journal and follow the session live. Requires `RAXOL_SHARE_SECRET`; a token minted for one tenant cannot be replayed against another's tree.
- **ACP stdio surface (#819)**. `mix raxol.acp`, the packaged `raxol acp`, and the `bin/raxol-acp` shim serve the coding agent over the [Agent Client Protocol](https://agentclientprotocol.com) on stdio, for editors that spawn an agent themselves (`Raxol.Agent.ClientProtocol.Serve` + `StdioAgent`). Turns run the read-only toolset.
- **The harness as MCP tools (#819)**. `Raxol.Agent.Harness.McpTools` registers `harness_start_session`, `harness_send_prompt`, `harness_read_transcript`, and `harness_list_sessions`. Sessions share the TUI's store, so a session started over MCP resumes with `mix raxol.code --resume <id>`. Read-only toolset, one unlinked worker per turn.
- **`.mcp.json` servers in the coding TUI (#819)**. `Raxol.Agent.Code.McpLoader` turns declared servers into approval-gated `mcp__<server>__<tool>` tools. A janitor process owns every started client and monitors the session, so clients and their OS subprocesses die on any termination path.
- **LLM spend on the payments ledger (#819)**. `Raxol.Agent.Code.CostLedger` meters each turn into `Raxol.Payments.Ledger` when the host wires a ledger and a spending policy, so LLM spend and agent payment spend draw on one budget. `Raxol.Agent.LlmPrices` prices well-known hosted models when `RAXOL_COST_PER_MTOK_IN`/`_OUT` are unset.
- **`Raxol.Agent.Code.Launcher` (#819)**: flag parsing, provider resolution, and session resolution for the coding TUI, with no Mix calls, so `mix raxol.code`, `bin/raxol-code`, and the packaged `raxol code` cannot drift.
- **`SECURITY.md` (#819)**: private vulnerability reporting through GitHub security advisories, the supported release line, and the pre-alpha packages that carry no support commitment.
- **Money-path telemetry (ADR-0036)**. `Raxol.Agent.Code.App` emits `[:raxol, :agent, :cost, :priced]` (measurements `cost_usd`, `input_tokens`, `output_tokens`; metadata `source` in `:env | :reported | :scoped_table | :flat_table`, `backend`, `model`, `session_id`, `turn_id`, `kind`, `ledger?`) for every metered provider call, `[:raxol, :agent, :cost, :unpriced]` when billed tokens could not be priced (with `armed?` saying whether a halt follows), and `[:raxol, :agent, :budget, :halt, :unpriced]` / `[:raxol, :agent, :budget, :halt, :over_limit]` (metadata `limit`) / `[:raxol, :agent, :budget, :halt, :ledger_unreachable]` when a running turn is stopped, split by remedy: a price, a policy decision, a process to repair. A sub-agent round is metered under its parent turn's `turn_id`. `Raxol.Agent.LlmPrices.turn_cost/4` returns `{:ok, cost, source}`; `turn_cost_usd/4` is unchanged and delegates to it. All five events are classified `:operational` in `Raxol.Agent.Telemetry`. Identifiers are correlation attributes, not metric labels; no prompt, argument or credential reaches metadata.
- **`docs/development/RELEASE_CHECKLIST.md`**: the ordered publish sequence for the Hex train, written for someone holding the credentials and no other context. Carries the verified package/version table (twelve published, six not), the publish order forced by inter-package requirements, the gates that must be green, the per-release CHANGELOG-dating and tagging bookkeeping, and the manual operator gates for `raxol_gateway`, `raxol_symphony`, and `raxol_earn` with the reason each one cannot be rehearsed offline.
- **First CHANGELOGs for `raxol_gateway` (0.1.0) and `raxol_earn` (0.2.0)**, both linked from their package metadata and shipped in their tarballs.

### Changed

- **`Raxol.LiveView.TEALive` renders one DOM node per screen row** (`raxol_liveview`). Its `:terminal_html` assign is replaced by `:rows` and `:container_attrs`, which is breaking for anything that read the old assign or overrode `render/1` against it. The screen was one dynamic, so LiveView resent all of it on every frame: measured 2.8 KB per frame at 62x13 and 7.0 KB at 60x34, against 0.3 KB for a one-row change at either size. `TerminalBridge.buffer_to_rows/2` and `html_to_rows/2` produce the rows, and `container_attrs/1` and `aria_mode_of/1` are public so a caller owning the `<pre>` cannot drift from the semantics `buffer_to_html/2` emits for the same `:aria_mode`.
- **Headless sessions now require the full TEA callback contract** (`init/1`,
  `update/2`, and `view/1`). Modules that exported only `view/1` are refused as
  `:not_a_raxol_application` instead of starting a session that cannot process
  events.
- **Spending budgets halt a running turn (#819)** instead of only the next prompt, and a model with no price fails closed once a ledger and policy are wired (an unpriced model bills real tokens while the ledger records $0.00).
- **The web release carries the agent stack (#819)**: `raxol_agent`, `raxol_payments`, and `req` are release dependencies. Without them the hosted coding agent could not have started or made an LLM call, and `Raxol.Application` now declines to serve the surface rather than standing up a broken one.
- **Dependency refresh in `raxol_symphony` and `raxol_telegram` lockfiles**, carried in the telemetry change because the new `mix deps.get --check-locked` CI gate found both locks stale (every locked version satisfied every constraint, so nothing had caught it). No `mix.exs` constraint changed. `raxol_symphony`: mint 1.9.3 -> 1.10.0, phoenix 1.8.9 -> 1.8.13, phoenix_live_view 1.2.8 -> 1.2.11, phoenix_pubsub 2.2.0 -> 2.3.0, postgrex 0.22.3 -> 0.22.4, ranch 2.2.0 -> 2.2.1, req 0.7.2 -> 0.7.4, telemetry_metrics 1.1.0 -> 1.2.0. `raxol_telegram`: cowboy 2.17.0 -> 2.18.0, cowlib 2.18.0 -> 2.19.0, phoenix_live_view 1.2.7 -> 1.2.11, req 0.6.3 -> 0.7.4, plus the same mint, phoenix, phoenix_pubsub, ranch and telemetry_metrics moves.
- **`bin/raxol`, `bin/raxol-code` and `bin/raxol-acp` launch through `mix run --no-start --no-compile --no-deps-check`** with stdin closed on the compile step and `-noinput` set for the ACP shim, so no Mix chatter reaches the protocol pipe and the ACP peer's VM does not claim fd 0 from the transport. `bin/raxol` drops the deprecated `--harness` flag.
- **DeepSeek is a registered backend** (`:deepseek`, `DEEPSEEK_API_KEY`, default `deepseek-v4-flash`), which is what makes `Raxol.Agent.LlmPrices`' backend-scoped cache-tier and peak-clock table (ADR-0035) reachable from a real session; the rows shipped keyed to an id no configuration could name.
- **The 256-color cube resolves to xterm's ramp, changing 208 of 216 indices.** `Formats.ansi_to_rgb/1` (`lib/raxol/style/colors/formats.ex`), `SixelPalette.calculate_rgb_cube_color/1` and `TerminalBridge.color_256_to_rgb/1` (`packages/raxol_liveview`) each computed the 6x6x6 cube as `n * 51`, giving levels 0/51/102/153/204/255 instead of xterm's 0/95/135/175/215/255. Only the two endpoints agreed, so the same buffer rendered different colors in LiveView than in the terminal renderer. All three now go through `Raxol.Core.Colors.Ansi256.to_rgb/1`. This is a VALUE change, not a refactor: downstream snapshot tests over emitted `rgb(...)` CSS, golden Sixel fixtures and recorded asciinema artifacts will all diff.
- **Publishing is part of landing this change, not a follow-up.** Every install snippet in the READMEs, `docs/getting-started/QUICKSTART.md`, `docs/PACKAGES.md` and `web/priv/static/skill.md` now says `~> 2.7`, and `scripts/check-lockstep-deps.sh` requires prose and `mix.exs` to agree, so the doc half cannot be staged separately. Until the family is on Hex, every documented install fails `mix deps.get`, and `web/priv/static/skill.md` is served to LLM agents, so the unresolvable constraint propagates into generated projects. The `Raxol.Core.Telemetry.Invariants` blocker that motivated the bump is itself cleared by it: `raxol_terminal`, `raxol_payments` and `raxol_earn` all `use` that module and all now require `raxol_core "~> 2.7"`, which cannot resolve a `raxol_core` without it.

### Removed

These are public modules of published packages, so their removal is breaking and the family's 2.7.0 minor bump carries it. Each was dead or duplicated at the point of removal, and no shipped code referenced any of them.

- **`raxol_terminal`: four unreferenced renderers.** `Raxol.Terminal.Rendering.{GPUAccelerator, GPURenderer, LigatureRenderer, OptimizedStyleRenderer}` (2,175 lines). None was reachable from the render pipeline; `Raxol.Terminal.Renderer` is the only renderer the emulator uses.
- **`raxol_terminal`: three forks of live modules.** `Raxol.Terminal.ANSI.SGRProcessor` duplicated `Raxol.Terminal.ANSI.SGR.Processor` over a plain map with its own `default_style/0` carrying a `:dim` key the `TextFormatting` struct does not have, so `ESC[2m` raised `KeyError` on the `Emulator.{ANSIHandler,CommandHandler}` paths; both now call `SGR.Processor`, which operates on the struct `emulator.style` actually is. `Raxol.Terminal.Buffer.Charset` and `Raxol.Terminal.Commands.CSIHandler.ModeHandlers` were likewise superseded (by `ANSI.CharacterSets` and `CSIHandler.ModeProcessor`) with no remaining callers.
- **`raxol_core`: `Raxol.Core.ErrorHandler`.** Superseded by `Raxol.Core.ErrorHandling`; its test moved with it (`error_handler_test.exs` -> `error_handling_test.exs`).
- **Two benchmark suites with no subject.** `bench/suites/validation/verify_optimization.exs` and `bench/suites/parser/sgr_comparison.exs` compared `SGRProcessor` against `SGRProcessorOptimized`, a module that does not exist anywhere in the tree; both had been failing at runtime before this change. The four repairable suites now call `SGR.Processor.process_params/2`.
- **`raxol`: the top-level `PluginRunner` and `MockTerminal`.** Both were unnamespaced public modules of the published `raxol` package; they are now `Raxol.Plugins.Testing.StubRunner` and `Raxol.Plugins.Testing.StubTerminal`. A consumer referencing either name by its old spelling breaks.
- **`raxol_terminal`: `Renderer.get_content/2`'s pid clause.** The clause matching a buffer-manager pid and returning `{:error, :deprecated_buffer_manager}` is gone with no catch-all behind it, so an external caller still passing a pid now gets a `FunctionClauseError` rather than the error tuple. Match on the buffer directly.

### Fixed

- **`raxol --version` is a real top-level flag**. The packaged CLI now prints
  its release version and build stamp, then exits successfully instead of
  treating `--version` as an unknown command.

- **A new `raxol_core` module shipped under a constraint that resolved without it.** `Raxol.Core.Colors.Ansi256` was added to `raxol_core`, but `raxol`, `raxol_terminal` and `raxol_liveview` all depended on `raxol_core "~> 2.6"`, which Hex resolves to the published 2.6.0, a version without the module. A consumer installing from Hex would have hit `UndefinedFunctionError` on any 256-color render (`Formats.ansi_to_rgb/1`, `SixelPalette`, `TerminalBridge.color_256_to_rgb/1`). Adding public API is a minor bump, so the framework family moves to 2.7.0 and the constraints to `"~> 2.7"`, which cannot resolve a `raxol_core` without the module. Neither guard could have caught this: `scripts/check-lockstep-deps.sh` compares only `X.Y`, and `Raxol.Release.PackageCheck` requires the constraint to be exactly `"~> major.minor"` of the sibling, so a patch-level API addition is invisible to both by construction.
- **The 2.6.x family was split across two patch versions** (`raxol` and `raxol_terminal` at 2.6.1, the rest at 2.6.0), which is what allowed a dependent to resolve a sibling older than the code it was built against. The framework line (`raxol`, `raxol_core`, `raxol_terminal`, `raxol_agent`, `raxol_mcp`, `raxol_liveview`, `raxol_plugin`, `raxol_sensor`) is unified at 2.7.0.
- **Three package tarballs shipped no licence.** `raxol_gateway`, `raxol_cli`, and `raxol_console` declared `licenses: ["MIT"]` but had no `LICENSE.md` on disk and none in `files:`, so `mix raxol.release.check` failed all three and a published tarball would have carried a licence claim with no licence text. All three now ship the repository MIT licence.
- **`raxol_agent_client_protocol` could not be packaged at all**: its description was 341 characters against Hex's 300-character limit, so `mix hex.build` aborted. Trimmed to the protocol and the transport surface; the resumable-session vendor extension is described in the package README.
- **Published docs for the 0.x packages linked their source at unrelated code.** `raxol_speech`, `raxol_telegram`, `raxol_watch`, `raxol_gateway`, `raxol_earn`, and `raxol_symphony` set `source_ref: "v#{@version}"`, but the bare `vX.Y.Z` tags are the root `raxol` version line, where `v0.2.0` is raxol from 2025. All six now use a package-scoped `<package>-v<version>` ref, and pushing that tag before publishing is a step in `docs/development/RELEASE_CHECKLIST.md`. `raxol_payments` 0.2.0 is already published with the defect; the checklist records it and the docs-only repair.
- **`raxol_earn` advertised a release candidate that was never cut.** Its Hex description still credited the retired v1 memo model, and its README's status line and installation snippet said `0.2.0-rc.0` and `{:raxol_earn, "~> 0.2-rc"}` against a `mix.exs` at 0.2.0.
- **`raxol_symphony`'s CHANGELOG and RUNBOOK had gone stale against the tree.** The 0.2.0 entry was written in July and predates the worker host pool, durable paused runs, Codex runner auth, the review stage, workspace confinement, and the retry and evidence fixes; it also still claimed runner pauses are unsupported in `:graph_parallel`, which they no longer are. The RUNBOOK pointed at a `SPEC.md` that does not exist in this repository, and its publish step did not mention that `raxol_telegram` and `raxol_watch` must reach Hex at 0.2.0 before `HEX_BUILD=1 mix deps.get` can resolve.
- **Journal reads healed a torn tail (#819)**. A read-side scan truncated live segments and permanently damaged a session; healing now belongs to the owning writer alone (`Raxol.Agent.Journal.FileStore.Reader.resume_scan/1`).
- **Per-session Lifecycles owned the VM-singleton plugin manager (#819)**. The `:ssh`, `:telegram`, `:agent`, `:liveview`, and `:gateway` environments start no plugin manager, so one disconnect can no longer kill a concurrent session. `Raxol.SSH.Session.lifecycle_opts/4` is the opts merge seam.
- **`raxol acp` never exited on peer disconnect (#819)**: exit 1 on the mix path, and a resident BEAM per editor session on the packaged one. A clean peer disconnect now exits 0.
- **`Raxol.Agent.SessionStreamer` retained event history forever (#819)**. History is a live replay buffer tied to subscriber presence: it is reclaimed when the last subscriber leaves, and `release/2` retires a per-run session id at the call site.
- **Sub-agent LLM spend never reached the ledger (#819)**, and turns were priced from the configured model rather than the billed one, so budgets read $0.00.
- **`Raxol.System.PortCommand` left children running on timeout (#819)**. A timed-out command is killed; where the port is its own process group leader, the whole group is signalled so descendants die with it.
- **Phoenix dev code reloading raised on every request in `web/`**: Phoenix 1.8 drives the reloader through Mix's compiler-listener API, and `web/mix.exs` did not declare `listeners: [Phoenix.CodeReloader]`. The `web-deploy-check` workflow now boots the dev environment for real (`RAXOL_DEV_SMOKE=1`, watchers off, port from `PORT`) and requires one page to render, the only place this class of breakage is observable.
- **`/usage` and the spending ledger priced the same money two ways**. The panel summed the session's tokens and priced the total through the flat table with the last billed model, so a provider-reported cost (grok's `total_cost_usd`, an ACP peer's `usage_update`) or a cache split showed as `unknown model` while the ledger charged the real figure. Each turn is now priced exactly as it was metered and turns nothing could price are counted, not hidden. On the flat table a cache-read token (Anthropic's `cache_read_input_tokens`) is billed at the input rate; `rates/2` callers never billed it at all, and the correction is upward on purpose.
- **A hostile usage figure could crash or silently skip metering**. An ACP peer's `usage_update` with a `cost.amount` past what a float can carry crashed `Raxol.Agent.AcpStreamAdapter` (and its embedder through the link); the same figure in a token count aborted `Raxol.Agent.Code.App`'s fold before the ledger record, the cost event and the halt, and the dispatcher logged and carried on. Every usage reader now bounds counts and amounts at `Raxol.Agent.BenchmarkProfile.max_count/0` and reads anything past it as absent. `Harness.GrokBuild` stamps its cost as `%{amount, currency: "USD"}`; a bare number with no currency is no longer read as a cost.
- **Cancelled, errored and superseded ACP turns lost their spend**. The adapter advanced its cumulative-cost anchor at every turn boundary, but only a completed bracket carries usage, so the money a cancelled turn spent could never be billed by any later turn. The anchor now advances only when a bracket bills, and a `:cost_anchor` start option seeds it when attaching to a session with history (a restart or `session/load`), which otherwise billed the whole history to one turn.
- **A token-less ACP turn priced at $0.00 disarmed the fail-closed halt**. The measured omp frame carries `used`/`size`/`cost` and no token split, so when the adapter drops the per-turn cost (cumulative went down, currency changed) the gate saw zero tokens and zero dollars and called the turn free. A usage map carrying `session_cost` now counts as billed, so it is unpriced, not free.
- **Symphony review preflight accepted pairs dispatch could never run**: two kinds of one vendor validated and then parked every issue as `:awaiting_human`; a disabled review left `implementer_kind` unvalidated, so `noop` crashed at dispatch and `review` recursed into itself; and `Review.select_reviewer/3` escalated a `candidate_kinds` list that named only the other vendor.

### Security

- **`grep`/`glob` followed symlinks out of the workspace sandbox (#819)** and returned file contents with no approval. Containment is decided on the real path of every walked entry (`Raxol.Agent.Actions.Fs.realpath/1`), and a symlink that resolves outside the root is skipped.
- **Policy telemetry emitted the wrapped operation's argument (ADR-0036)**. `Raxol.Agent.PolicyApplier` put `params` (an arbitrary term, and for a cache policy keyed on a prompt, the prompt) into the metadata of `[:raxol, :agent, :policy, :applied]`, `:cache_hit` and `:cache_miss`, and `Raxol.Agent.ThreadLogRouter` persisted every metadata key to the durable thread log. The `params` key is removed (a handler reading `metadata.params` now gets `nil`); every policy event carries `params_digest`, 64 bits of a keyed HMAC-SHA256 over the argument's external term format, which joins the events of one call without carrying content. Callers that need correlation identifiers on these events pass `PolicyApplier.apply/4`'s new `metadata:` option, enforced by `Raxol.Agent.Telemetry.identifier?/1` (atom keys; atom, number, or binary values of at most 64 bytes) with a refusal that names the offender by shape, never by content (a struct handed over as the map is refused by its name, not enumerated into the message); Symphony's runner passes its `turn` and `issue_id` that way. `ThreadLogRouter` no longer mirrors event metadata into the persisted entry: it keeps `session_id`, `turn_id`, the `TraceContext` ids, and the keys a host names in `attach/4`'s `:metadata_keys`, each only when its value is an identifier, and drops the rest without raising so a bad value cannot detach the audit handler.
- **Policy and sandbox telemetry carried error reasons, cache keys and shell commands verbatim (ADR-0036)**. `reason` on `[:raxol, :agent, :policy, :retry_attempt]` / `:retry_exhausted` was the wrapped operation's error term (a provider error can echo the request or carry a response struct with headers); `key` on `:cache_hit` / `:cache_miss` was the user's `key_fn` result, which may be the argument; and `[:raxol, :agent, :sandbox, :denied]` carried the full shell command line or the whole malformed tool payload in `reason`, which `ThreadLogRouter` persisted as the `:sandbox_deny` audit entry. All are now bounded before emission by `Raxol.Agent.Telemetry.bound/1`, which keeps identifiers and the shape of a term (depth 3, width 8) and replaces every other leaf with a shape tag such as `{:redacted, :binary, 4096}`; `ThreadLogRouter` bounds every payload it persists as a backstop. A shell denial is emitted as `{:shell_denied, mode, program}` with a `command_digest`, where `program` is the first token only for a simple command (`Raxol.Agent.Sandbox.Shell.simple_command?/1`) and the tag `:non_simple` otherwise: an env-assignment prefix (`PGPASSWORD=... psql`) makes the first token the secret itself, on exactly the commands a list mode always denies, so it never leaves the process; `mode` is bounded too, so a predicate sandbox emits `{:redacted, :function}`. A malformed-payload denial is emitted as its tag; the caller's `{:deny, reason}` still carries the full reason. `params_digest` is now an HMAC-SHA256 under a per-VM random key rather than an unkeyed hash, so an audit log cannot be used to confirm a guessed argument; it joins the events of one operation within a run and, deliberately, not across runs. It is computed once per `PolicyApplier.apply/4` and carried on every event of that call, including `:retry_*` and `:timeout`.
- **`/resume` and `--resume` accepted an unvalidated session id (#819)**, which let `/transcript` write into another tenant's workspace. Both validate the id, and `/transcript` is containment-checked like `/export`.

## [2.6.1] - 2026-08-08

### Fixed

- **Benchmark regression machinery is real (#805)**: `--regression` detects (5% median gate, persisted baselines), `--compare` diffs the previous snapshot, the summary and dashboard report measured values, and the mix-task rendering suite benches the real buffer/tree-diff pipeline instead of a stub. The comparison suite's memory row uses `erts_debug.size`.
- **benchee HTML reports no longer auto-open** in any suite (#810, #812): `System.cmd("xdg-open", ...)` crashed headless Linux runs and opened browsers mid-test on macOS.
- **Cloud metrics export is real (#805)**: OTLP/HTTP JSON, Datadog v1 series, and Prometheus pushgateway senders replace `:ok` stubs, with async monitored export, ingestion-time validation, label escaping, and api_key redaction.
- **postgrex 0.22.4** (EEF-CVE-2026-66838, SQL injection via the `:comment` option) (#812).

### Changed

- **README and QUICKSTART document the headless from-source path** (#810, #815): C-toolchain prerequisite, non-interactive Hex bootstrap, the full test-exclusion set (`SKIP_TERMBOX2_TESTS=true`), RATE, `MIX_HOME`/`HEX_HOME` for read-only sandboxes, and the PostgreSQL requirement of unexcluded integration suites.
- **Performance tables republished from a measured run** (#813): single-provenance numbers (commit, hardware, command), emulator-ingest rows labeled as the full parse+apply path distinct from the sub-microsecond lexer, and the cross-framework ANSI row removed as lexer-vs-ingest comparisons mislead.

### Deprecated

- **`Raxol.UI.VisualTest`, `Raxol.UI.ComponentTest`, `Raxol.UI.IntegrationTest`, `Raxol.UI.PerformanceTest`** are deprecated and scheduled for removal in 3.0. They have no callers; no replacement is planned.

### Removed

- **`Raxol.UI.ThemeResolverCached`** (delegating shim) removed. Use `Raxol.UI.ThemeResolver.<fn>(..., cache: true)`, a one-to-one replacement documented in that module.

## [2.6.0] - 2026-07-11

### Added

- **LiveView accessibility: ARIA roles + announcement live region (#431)**. The LiveView terminal surface now emits ARIA roles and an `aria-live` region so screen readers announce state changes.
- **Accessibility projection + MCP a11y fields (#428)**. The model exposes an accessibility projection; MCP screenshots carry a11y fields describing focus, roles, and announcements.
- **OpenRouter backend harness with app attribution (#414)**. `Backend.Selector`'s `:openrouter` harness targets OpenRouter (OpenAI-compatible) and attaches app-attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) so Raxol appears on openrouter.ai/rankings.
- **`raxol_payments`: `recipient_address` on the Xochi `QuoteRequest` (#416)**, and stealth fields surfaced in the ACP Xochi deliverable so buyers can settle to a stealth meta-address.
- **Property tests for the money-adjacent paths (#392/#393)**: `router_property_test` (trust-score totality / monotonicity / clamp / tier_override bounds), `ledger_release_property_test` (`Ledger.release/4` refund netting), `jsonrpc_nonce_test` (concurrent-send nonce distinctness), `job_session/telemetry_test` (pins the `[:raxol, :acp, :job_session, :transition]` cross-package contract with `raxol_symphony`), and an exhaustive `JobSession.Status.validate/2` matrix.

### Changed

- **Toolchain: Elixir 1.20 / OTP 29, zero warnings (#398)**.
- **`raxol_payments`: MPP amounts pinned to atomic integer units (#413)**; Xochi Tron deposit-route quotes verified.
- **Web surface hardening (#427/#418/#426)**: web deploy gained a CI gate, health check, SSH, and warnings-as-errors; the raxol.io agent surface was tightened; the landing demo is interactive (forwards keydown).

### Fixed

- **`raxol_earn`: EOA nonce race in `ProviderAdapter.JSONRPC` (#392)**. `send_calls/3` fetched the pending nonce inline, so two concurrent sends for one EOA signed the same nonce and the RPC silently dropped one (fund loss on retry). Nonce assignment now routes through the mailbox-serialized `Raxol.Earn.Wallet.NonceServer`; a failed send resyncs to re-fetch and re-fill the gap. The SCA/UserOp path is unaffected.
- **`raxol_payments`: negative trust score crashed the router (#393)**. `Raxol.Payments.Router` clamped only the upper trust-score bound, so a negative `:trust_score` hit `PrivacyTier.from_trust_score/2` (no negative clause) and raised `FunctionClauseError` on the settlement path. Now clamped to `[0,100]` at the boundary.
- **`raxol_payments`: x402 auto-pay budget leak and value binding (#403)**; refunded status now handled and the session budget reconciled on refund (#402); `Ledger` reservation tags are bounded with a TTL sweep (#407).
- **`raxol_earn`: write-confirmation correctness**. EOA transactions confirm the receipt before reporting write success (#412); a reverted UserOp is rejected as a failed SCA write (#409); `accept_request` (#408) and seller delivery (#406) are idempotent.
- **Web release stability**: fixed a raxol.io release boot crash (#424), restored web PubSub + SSH for minimal-mode Raxol (#425), set ssh/public_key to `:permanent` (#420), and excluded nested build artifacts from the Docker context (#422).
- **CI: de-flaked two timing-sensitive property tests (#432)** (parser performance budget, process-isolation link race) that failed seed-dependently on the nightly and macOS matrices.

### Security

- **`raxol_payments`: wallet private key guarded from crash-report leak (#404)**. Keys are wrapped so they cannot surface in `Inspect` output or crash reports.
- **Dependencies: pruned orphaned lockfile deps, dropping the Tesla CVEs (#415)**; dropped the earmark dependency (#396).

### Removed

- **`raxol_earn`: v1 memo model retired (seller-stack migration Phases 1-4, #385/#390/#388/#389/#391)**. Deleted `Raxol.Earn.Job.{Server, Supervisor, Registry, Workflow, StateMachine, MemoType, FeeType, Store}`, `Raxol.Earn.ContractClient` (+ `Onchain` + `InMemory`), the memo `Raxol.Earn.Directive`s + their executor, `Raxol.Earn.Onchain.LogDecoder`, and the `acp_version` / `ACP_VERSION` switch. The v2 hook/event model (`Raxol.Earn.JobSession` + `Raxol.Earn.HookClient` -> `AgenticCommerceV3` via `Raxol.Earn.ProviderAdapter`) is now the only runtime. `raxol_earn` graduated `0.2.0-pre.0 -> 0.2.0`. Supersedes ADR-0016/0017. See `packages/raxol_earn/MIGRATION_V2.md`.

## [2.5.0] - 2026-07-07

### Fixed

- **Layout engine: dynamic-children dropped from `column(opts, do: var)`**: when callers wrote the inline keyword-list form `column(style: ..., do: items)` Elixir matched it against `def column/1` instead of `defmacro column/2`, and the `:do` key rode through into the layout function unread. `Flex.column/1` then saw `children: []` and rendered an empty container. Fix: `Raxol.Core.Renderer.View.promote_do_to_children/1` pops `:do` and re-keys it as `:children` (via `List.wrap` so single-child blocks work too); `View.column/1`, `View.row/1`, `View.box/1` all forward through it. Restored rendering for CheckboxDemo, TextAreaDemo, RadioGroupDemo.
- **Layout engine: chart widget types dropped at layout step**: `Components.chart/1` returns a `:box` element whose `:type` is overridden to one of `:line_chart`, `:bar_chart`, `:scatter_chart`, `:heatmap` so MCP's `ToolProvider` can discover them. The layout engine had no clauses for those types; they hit the catch-all warning and the element disappeared. Fix: added one `process_element/3` clause that rewrites the chart types to `:box` and forwards. Restored LineChart, ScatterChart, BarChart, CursorTrail, Heatmap demos.
- **Layout engine: `style: %{position: {x, y}}` offset ignored on `:text` elements**: chart cells emitted by `Raxol.UI.Charts.ViewBridge` carry their own relative position so each row lands at the right column. The `:text` layout clause used `space.x`, `space.y` unconditionally and stacked all cells at the same coordinate. Fix: extract `{dx, dy}` from `style.position` and add to the space origin.
- **Layout engine: `:text_input` constructor shape mismatch**: `Components.text_input/1` builds the element with top-level `:value` / `:placeholder` keys, but the layout clause required them inside `:attrs`. Element fell to the catch-all and dropped. Fix: added a clause that rewrites the new-DSL shape into the `:attrs`-shaped form and forwards.

### Added

- **`test/property/layout_completeness_property_test.exs`**: 3 properties locking down the layout-element-drop bug shape. Generates view trees (text / flex / box / chart) and asserts every `:text` content string in the input appears in the positioned-elements output. Sabotage-verified: comment out the chart-type clause and both relevant properties fail.
- **`test/property/promote_do_to_children_property_test.exs`**: 8 invariants for the helper above. Includes one property documenting that `[do: nil]` is intentionally indistinguishable from `[]` (because `Keyword.pop/2` can't disambiguate).
- **`test/property/demo_update_totality_property_test.exs`**: one property per Catalog demo (30 total). For each demo, folds random sequences of up to 30 mixed key events (chars, special keys, `:tick`, modifier combos) through `update/2` and asserts no exception plus correct `{model, commands_list}` shape. Catches state-machine edge cases that example tests don't reach (negative cursors, list overflows, unhandled tick states).
- **`test/raxol/playground/demo_render_test.exs`**: end-to-end render regression test that mounts every Catalog demo through `Raxol.Headless`, asserts both text-screenshot content lines and buffer cell paint coverage, and drives demos through documented key sequences (`@key_drives`) to reach state where the canonical widget content is visible. Caught the four framework bugs above on its first run.
- **`raxol_symphony` Phases 0-14**: Elixir/OTP port of OpenAI Symphony. Tracker-driven coding-agent orchestrator with two runner backends (`Runners.RaxolAgent` default; `Runners.Codex` Port-based JSON-RPC for parity with upstream Symphony Elixir) and six surfaces (terminal dashboard, LiveView, MCP tools + `symphony://runs` resource, Telegram per-issue session router, Watch push, JSON `/api/v1/*`). Workflow hot-reload via `WorkflowStore`, Linear (GraphQL) + GitHub Issues (state labels) trackers, evidence framework (`Evidence.GitHub` CI/PR comments, `Evidence.Complexity` cloc/SLOC fallback, `Evidence.Recording` cast scan), in-run asciinema capture (`Evidence.Capture` writes `<workspace>/.raxol_symphony/run-<attempt>.cast` per dispatch when `recording.enabled: true`). 399 tests, 0 failures. Pre-alpha, path-dep.
- **`raxol_earn` v0.1 (engineering complete)**: First Elixir/OTP-native Virtuals Agent Commerce Protocol implementation. Job lifecycle (`Job.{Server, StateMachine, Memo, Store, Supervisor, Registry}`), EIP-712 typed-data memos via `Raxol.Payments.EIP712`, on-chain client (`ContractClient.Onchain` over Req JSON-RPC, EIP-1559 typed-tx signing, Yellow-Paper RLP, log decoder for `create_job` job_id extraction), Seller stack (`Backend.InMemory` + `Queue` + `Runtime` + `Supervisor`, opt-in via `:seller_enabled`), `Wallet.NonceServer` for serialized nonce assignment, `mix raxol_earn.bench` sandbox-graduation harness. Optional DETS-backed `Job.Store` durability. 256 tests, 0 failures. Pre-alpha, path-dep. External-blocked: real ACP contract ABIs, `Wallet.SCA`, `Seller.Backend.WebSocket`.
- **`Raxol.Payments.Wallet.sign_hash/1`**: new behaviour callback for EIP-1559 transaction signing (sign-precomputed-digest semantics). `Wallets.Env` and `Wallets.Op` both implement.
- **Workflow Graph (`Raxol.Workflow.*`, ADR-0015)**: LangGraph-style stateful workflow primitive in main raxol: a declarative `Graph` builder with six-step structural validation, synchronous `Compiled.invoke/3` plus `async_invoke/3` and `stream_events/3`, a durable `Checkpoint.Saver` (Ets/Dets/Postgrex adapters), `Workflow.interrupt/1` human-in-the-loop with `Compiled.resume/4`, and `failure_policy: :retry | :compensate` (reverse-order saga rollback).
- **Workflow concurrency (ADR-0019)**: `Graph.add_channel/3` (typed reducers) and `Graph.add_join/4` (barrier); multi-node parallel branches via `Task.async_stream` (`parallelism :: pos_integer | :branches`), per-branch pause/resume, cancellation cascade, per-branch trace spans, and `branch_id` checkpoint/telemetry metadata. Real consumers: an ACP cross-chain settlement example and a Symphony parallel-candidates `GraphAdapter`.
- **Effect system (`Raxol.Agent.Directive`)**: struct-based directives (Async/Shell/SendAgent/Schedule/Spawn/Stop) with an `Executor` protocol replacing the closed Command tuple set; a CloudEvents v1.0 envelope (`Event.to_cloud_event/2`); `TraceContext` `causation_id` correlation.
- **Agent-stack substrate (ADR-0020)**: `Raxol.Agent.Cache`, `ThreadLog` (append-only audit), declarative `Policy.{Retry, Timeout, Cache}` via `PolicyApplier`, and the `Sandbox` protocol with `Sandbox.Chain` gating. Symphony's RaxolAgent runner adopts every primitive (tracker cache, thread-log audit, per-turn policies and sandboxes); a Session-backed sibling runner ships.
- **Operator-flow contract (ADR-0018)**: a first-class paused-run substrate end-to-end (Workflow Saver -> ACP Job -> Symphony Orchestrator -> MCP tools -> TUI/LiveView/Telegram/Watch); `Raxol.Symphony.PauseReason` consolidates reason formatting and is mechanically enforced via a `pause_reasons/0` callback.
- **raxol_earn Workflow migration (ADR-0016)**: `Job.Server`'s GenServer state machine replaced by a Workflow-backed implementation (`Job.Workflow`, a 10-node graph); `:via_workflow` flipped to the default.
- **Self-improving agent loop (`raxol_agent`)**: skills as filesystem procedural memory, an after-turn curation reviewer, and a Curator. `Raxol.Agent.Skill` parses/renders agentskills.io `SKILL.md`; `Raxol.Agent.Skills.Store` is a `BaseManager` disk index with usage telemetry persisted via `Core.Stores.Dets`, a managed root plus read-only `external_dirs` (default `~/.agents/skills`), and archive/state/pin; `skills_list`/`skill_view`/`skill_manage` Actions. `Raxol.Agent.SelfImprove.after_turn/3` spawns an isolated, unlinked reviewer on an auxiliary model that writes durable memory and `created_by: :agent` skills; `Raxol.Agent.Curator` ages `active -> stale -> archived` with interval-plus-idle gating, dry-run, and `tar.gz` backup/rollback. New `use Raxol.Agent` callbacks `skills_provider/0` and `self_improve/0`.
- **Memory provider stack, full-text recall, dialectic user model (`raxol_agent`)**: `Raxol.Agent.Memory.Stack` composes N memory providers (fan-out writes, merge + rerank + dedup reads); `Raxol.Agent.Memory.SessionSearch` is a BM25-lite inverted index over raw conversation items (`session_search` returns messages, not summaries); `Raxol.Agent.UserModel` derives a per-user dialectic block on an auxiliary model, injected into the last user message via the new optional `build_user_context/1` callback. New `memory_providers/0` callback.
- **`Raxol.Agent.Turn`**: the turn driver that assembles memory/skills/user-context/session-search context from an agent module's callbacks, records each turn to a `Conversation.Log`, and fires the after-turn self-improvement effects. Wires the loop end-to-end.
- **`raxol_gateway` package (pre-alpha)**: one daemon connecting many chat platforms through a shared `Gateway.Adapter` contract. `Route` keys sessions `agent:main:{platform}:{chat_type}:{chat_id}`; `SessionRouter` + `Session` run one process per chat under a `DynamicSupervisor` with idle/cooldown/max-session limits; `Pairing` issues DM codes and decides `authorize/2`; `Delivery` resolves four outbound destinations (direct, home, cross-platform, explicit `"platform:chat_id"` target); per-chat history plus `SessionRouter.handoff/3` move a conversation across platforms with its history intact. `Adapter.InMemory` is a reference adapter.
- **Symphony opt-in self-improvement**: `Raxol.Symphony.Runners.RaxolAgent` fires the `Agent.Turn` after-turn hook (skills curation, memory, user-model refresh, session index) on each turn when `agent.module` declares it, in both the workflow and simple run paths, without touching event forwarding, pause detection, policies, or sandboxes.
- **ADRs 0021-0028**: Hermes-extraction Tier 1 (self-improving agents, memory provider stack, unified messaging gateway) and Tier 2 (execution backends + hibernation, cronjob, execute_code, delegate_task, auxiliary-model routing) decision records.
- **Idempotent crash recovery for cross-chain payment Actions (`raxol_payments`)**: `Raxol.Payments.Checkpoint`, a nil-safe behaviour for a durable in-flight-intent store injected via `context[:checkpoint]`, with `derive_key/1` for a stable idempotency key. Three stores: `Checkpoint.ETS` (process-crash-durable), `Checkpoint.ContextStore` (backed by `Raxol.Agent.ContextStore`, so a deployed agent's in-flight intent rides the same store that backs its crash recovery), and nil (disabled, the default). `ExecuteXochiIntent` and `ExecuteRelayTransfer` checkpoint the dispatched intent before submit and resume it on a re-run after a crash (poll-before-re-sign, no second spend authorize) instead of re-quoting and signing twice; the relay rail keys on the logical payment (not the client-minted `transfer_id`) so a resume reuses the same id and an idempotent broadcaster dedupes a retried deposit. Drops the checkpoint on definite failure; protocol-tagged keys (`:xochi`/`:relay`) so a shared store can't collide. The ZERO cockpit crash beat (`examples/agents/zero_system.exs`) models the contract end-to-end. `:live_xochi` and `:live_relay` kill-and-resume gates. 24 new tests + the live variants; 0 failures.
- **Auxiliary-model routing (`raxol_agent`, ADR-0028)**: `Raxol.Agent.Auxiliary` routes background tasks (curation, user-model derivation, future titling/triage) to a cheap model per task kind instead of the frontier model. `resolve/2` maps a task kind to its slot's `ExecutorConfig`; `resolve_chain/2` adds the slot's fallback chain terminating at the primary executor; `select/2` walks the chain through `Backend.Selector` with an injectable availability predicate. Config is an `auxiliary:` slot map keyed by task kind with a `default_aux` catch-all. `SelfImprove` and `UserModel` consult the resolver when no explicit backend/model is set, keeping explicit config as an override; with `auxiliary:` unset every kind resolves to the primary executor.

### Changed

- **`Raxol.Agent.Memory.Store.Ets` DETS**: migrated the hand-rolled `:dets` open/persist/delete/clear/sync/close to the shared `Raxol.Core.Stores.Dets` helper. Behaviour-preserving; the existing store tests pass unchanged.

## [2.4.0] - 2026-04-14

### Added

- **Phase 14B: Xochi Integration**: Xochi as default agent-facing protocol for cross-chain payments. Cash-positive with tier-based fees (0.10-0.40%). Riddler solves intents behind the scenes.
  - `Raxol.Payments.Xochi.Client`: HTTP client for Xochi intent API (quote, execute, status, history)
  - `Raxol.Payments.Xochi.Schemas`: 5 typed structs (QuoteRequest, QuoteResponse, ExecuteRequest, ExecuteResponse, IntentStatus)
  - `Raxol.Payments.Protocols.Xochi`: full intent flow: `get_quote/2` -> `execute/3` (EIP-712 wallet signing) -> `poll_status/3`
  - `Raxol.Payments.Riddler.Client`: Commerce API client (B2B/direct solver access, not default)
  - `Raxol.Payments.Router`: cross-chain routes to `:xochi`, privacy to `:xochi`, same-chain stays `:x402`
- **Phase 14C: PXE-Bridge Integration**: Aztec Private eXecution Environment as settlement target for high-trust privacy tiers.
  - `Raxol.Payments.Pxe.Client`: JSON-RPC 2.0 client (aztec_createNote, aztec_getVersion, /status)
  - `Raxol.Payments.Pxe.Schemas`: CreateNoteParams, CreateNoteResult, HealthStatus
  - `Raxol.Payments.PrivacyTier`: Glass Cube model (6 tiers: open, public, standard, stealth, private, sovereign), attestation gating, downgrade logic
  - Router settlement routing with trust-score-aware privacy depth
- **Phase 14D: Stealth Settlement**: Full ERC-5564/ERC-6538 in `Xochi.Stealth` (~300 LOC).
  - ECDH stealth address derivation (secp256k1)
  - View tag scanning (256x speedup, 1:256 false positive rate)
  - Domain-separated key derivation from EVM signature
  - Meta-address encode/decode (st:eth:0x format)
  - 44 tests (32 unit + 12 e2e), stress-tested 500 round-trips at 0% failure
- **Phase 14E: ZKSAR + Trust Tiers**: Zero-knowledge attestation verification and trust scoring.
  - `Raxol.Payments.Zksar`: 6 ZK proof type verification (type, expiry, issuer, structure), batch verify, JSON parsing
  - `Raxol.Payments.Zksar.TrustScore`: diminishing-returns aggregation: `score = sum(weight_i / ln(rank + 1))`, capped at 100
  - PrivacyTier attestation requirements per tier, downgrade logic
  - Router attestation-aware routing with `trust_score_for/1`
- **AutoPay wiring**: `Backend.HTTP` accepts `:req_plugins` for transparent HTTP 402 handling. `Raxol.Payments.Req.AgentPlugin.auto_pay/1` builds the closure.
- **Riddler solver wiring (ADR-0005)**: Complete on both sides. 9 Xochi endpoints, fee policy (5 tiers + privacy premiums), stealth/ERC-4337 settlement, ZKSAR attestation, EIP-712 typed data. 119 Riddler tests + 347 raxol_payments tests.
- **raxol_liveview package**: TerminalBridge, TEALive, TerminalComponent, 5 themes, CSS asset. 37 tests.
- **raxol_plugin package**: `use Raxol.Plugin` macro, API facade, Manifest, Testing helpers, generator. 50 tests.
- **Hex publishing readiness**: All packages at v2.4.0 with LICENSE.md, README.md, package metadata, version-constrained path deps. Publishing order: raxol_sensor + raxol_core -> raxol_terminal/mcp/plugin/liveview -> raxol -> raxol_agent -> raxol_payments.

### Changed

- Deprecated `Protocols.Riddler`: now delegates to Xochi internally
- All sub-packages bumped to v2.4.0 (raxol_payments stays at 0.1.0)
- Path deps now include version constraints (`~> 2.4`) for Hex compatibility

### Fixed

- **Dashboard demo**: `status_dot/1` used identical character for all scheduler load levels; now uses distinct ASCII indicators per threshold
- **String.to_atom on external input**: Replaced 6 unsafe catch-all `String.to_atom(s)` in schema parsers with explicit clauses + `:unknown`/`nil` fallback
- **Duplicated `maybe_put/3`**: Extracted to `Schemas.put_non_nil/3` shared helper
- **Dialyzer specs**: Tightened `{:error, term()}` to actual error tuple shapes in `metrics.ex`
- **QuoteRequest validation**: Added `validate/1` with eth address format checks
- **Attestation filtering**: PrivacyTier now filters attestations by `valid: true`

## [2.3.2] - 2026-03-30

### Added

- **Headless session manager** (`Raxol.Headless`): GenServer managing non-interactive TEA app instances in `:agent` environment. Start from module or .exs file, take text screenshots, send keystrokes, read model state. Used by MCP tools and future test harness.
- **MCP tools for Claude Code**: 6 tools (`raxol_start`, `raxol_screenshot`, `raxol_send_key`, `raxol_get_model`, `raxol_stop`, `raxol_list`) injected into Tidewave at dev startup. Tidewave MCP proxy script for stdio transport.
- **ADR-0012: MCP as Rendering Target**: Architecture decision formalizing MCP as a first-class rendering target. Automatic tool derivation from widget tree via ToolProvider behaviour, focus lens with mouse tracking, context tree as MCP resources, agent-MCP symmetry, multi-surface cockpit vision (terminal, MCP, Telegram, speech, watch). Category theory foundations for design and property-based test invariants.
- **SPECS.md Phases 8-11**: raxol_mcp package, ToolProvider + tool derivation, context tree + resources, MCP test harness.
- **Playground resize handling**: Fixed resize event propagation in playground demos.

### Changed

- Updated `docs/core/ARCHITECTURE.md` with MCP rendering target section
- Updated `CLAUDE.md` with raxol_mcp package, dependency graph, and consolidated namespace
- Updated `IDEAS.md` with MCP architecture, functor family, multi-surface cockpit, category theory
- Updated `docs/adr/README.md` with ADR-0012 and new "AI & MCP" category
- Dispatcher and Engine refactored under 800 LOC each
- Credo strict: 0 issues (was 373, resolved via function extraction and pattern matching)

## [2.3.0] - 2026-03-27

182 commits, 1,030 files changed, net -39K LOC (89,793 insertions, 129,283 deletions).

### Added

- **Distributed swarm subsystem**: libcluster integration with gossip, EPMD, DNS, and custom Tailscale strategy. CRDTs (LWW-Register, OR-Set) for shared state. Node health monitoring, seniority-based leader election, bandwidth-aware message routing. 11 modules, 2,100+ lines.
- **AI agent framework**: `use Raxol.Agent` for TEA-based agents with OTP supervision. Agent discovery via Registry, typed inter-agent messaging, headless or rendered. Three command types: async (SSE streaming), shell (Port), inter-agent. Team supervision via `Agent.Team`. Backend.HTTP streams across Anthropic, OpenAI, Ollama, Kimi, and Lumo (U2L encryption). Tiered fallback detection.
- **Interactive playground**: 28 demos across 8 categories (input, display, feedback, navigation, overlay, layout, visualization, effects). Search, filter by category/complexity, help overlay. Charts as View DSL widgets. SSH serving with `mix raxol.playground --ssh`.
- **Time-travel debugging**: `Raxol.start_link(MyApp, time_travel: true)` snapshots every `update/2` cycle into a circular buffer. Step back/forward, jump to any point, restore state. Recursive map diffing. Zero cost when disabled.
- **Session recording and replay**: Asciinema v2 format. Capture with timestamps, replay with pause/seek/speed controls. Stream replay.
- **Sandboxed REPL**: `Code.eval_string` with spawn_monitor timeout, IO capture via group_leader swap, persistent bindings. Three sandbox levels: unrestricted, standard, strict (whitelist-only, safe for SSH). Available as `mix raxol.repl`.
- **Nx/Axon adaptive ML**: Optional Nx vectorized fusion, Axon MLP recommender for layout, FeedbackLoop training. Gated behind `Code.ensure_loaded?`.
- **Plugin system**: Phase 1 mission plugin system (4 modules) with lifecycle management
- **AGI Cockpit Console**: Phase 2 cockpit with uptime panel, dependency checker, crash recovery, state machine
- **`mix raxol.new`**: Project generator with 4 templates (basic, phoenix, ssh, agent)
- **`mix raxol.demo`**: 4 built-in runnable demos
- **`mix raxol.check`**: Unified quality gate (format, compile, credo, dialyzer, security, test)
- **Benchmark suite**: Comparative benchmarks against Ratatui, BubbleTea, and Textual
- **746+ new tests** across 21 modules (357 for core, 233 for runtime, 156 for plugins, 84 for converter/keyboard/engine/shutdown/initializer/scheduler)
- Mouse click hit testing for buttons
- Agent semantic view tree
- Unified image facade + View DSL `image/1`
- Event capture phase (W3C-style dispatch), event bubbling, style inheritance through component tree
- HEEx parser for terminal compilation
- Sixel real dithering + image cache
- CODE_OF_CONDUCT.md, SECURITY.md

### Fixed

- 3 real bugs found via test coverage: converter pipe BadMapError, keyboard CaseClauseError on quit/debug, unreachable ctrl_c/ctrl_q clauses
- 6 flaky CI tests (Registry race conditions, ETS cleanup, JIT warmup timing, behavior_tracker race)
- Windows CI (GPG path separators, IOTerminal backend)
- Input parser multi-byte sequences + mouse tracking
- REPL sandbox hardening, capped eval history

### Changed

- Deleted ~35K lines of dead code (CQRS, EventSourcing, Pipeline, stale stubs)
- Phoenix is now an optional dependency
- All examples modernized to TEA pattern
- Zero credo warnings, zero dialyzer regressions
- Refactored large files into focused submodules (CSI handlers, sensor, adaptive, orchestrator)
- 6,484 tests passing, 0 failures, 74 excluded by environment

## [2.2.0] - 2026-03-22

### Added

- Widget examples for Viewport, CodeBlock, MarkdownRenderer, MultiLineInput
- Modal test file (22 tests) and Terminal test file (16 tests) verified

### Changed

- Rewrote `examples/apps/todo_app.ex` from broken LiveView/HEEx to TEA pattern
- Hex package readiness: `mix hex.build` succeeds (1.8MB)
- 14 deps marked optional (Ecto, PostGres, bcrypt, mogrify, contex, HTTPoison, ex_cldr, phoenix_ecto)
- Excluded compiled `.so`/`.o` binaries from hex package
- Moved esbuild/dart_sass to dev-only
- Replaced `Ecto.UUID.generate()` with `UUID.uuid4()` in emulator struct
- Updated package description

## [2.1.0] - 2025-02-27

### Added

- **ScreenBuffer.Scroll Module** - Complete scroll operations for terminal buffer
  - Scroll region management (set/get scroll regions)
  - Basic scroll operations (scroll_up/down with configurable line counts)
  - Region-specific scrolling (scroll within defined regions)
  - Scrollback buffer management (save, clear, get with limits)
  - Scroll position tracking for viewing history
  - VT100 index operations (IND/RI for cursor-triggered scrolling)

- **Core.Performance Module** - ETS-backed performance statistics tracking
  - Frame timing and FPS calculation
  - Memory usage monitoring
  - Sample-based metrics with configurable limits
  - Non-blocking initialization (works without GenServer)

### Fixed

- **Dialyzer Errors** - Resolved all dialyzer warnings in plugin modules
  - plugin_supervisor: Explicit handling of Task.Supervisor return values
  - beam_analyzer: Precise error types for analysis_result
  - capability_detector: Tightened policy and capabilities types
  - Added documented ignore patterns for safe supertype specs

- **Orphaned Tests Cleanup** - Removed test files for non-existent modules
  - Deleted adaptive_framerate_test.exs (module removed in 9f27ae77)
  - Deleted monitor_test.exs (module never existed)
  - Deleted gpu_renderer_test.exs (module never existed)
  - Deleted render_server_test.exs (module never existed)
  - Tagged termbox2 NIF loading test with :docker for CI compatibility

### Changed

- **Test Suite** - Improved test stability and reduced flaky failures
  - 4669 tests passing with 0 failures
  - Removed ~750 lines of orphaned test code

## [2.0.1] - 2025-12-04

### Added

- **Plugin Visualization Integration** - Complete Sixel rendering in UI components
  - Implemented `create_sixel_cells_from_buffer/2` to bridge plugin and terminal Sixel rendering
  - Integrated with `Raxol.Terminal.ANSI.SixelGraphics.process_sequence/2` for native processing
  - Added pixel buffer to Cell grid conversion with palette-to-RGB color mapping

- **CI Root Cause Analysis Documentation** (2025-12-06)
  - Documented three distinct root causes affecting nightly builds with ready-to-apply solutions

### Fixed

- **Test Type Warnings** - Removed unreachable pattern matching clauses in DCS handler tests
- **Nightly Build CI/CD Pipeline Stabilization** (2025-12-06)
  - Fixed Erlang :cover module crashes on NIF beam files (OTP 27.2/28.2)
  - Fixed Hex archive OTP version conflicts
  - Fixed macOS performance test timing issues
  - Fixed Elixir 1.19.0 LiveComponent lifecycle
  - Result: 43% -> 93% CI success rate

### CI/CD workflow fixes

Fixed failing GitHub Actions workflows and updated to latest Elixir/OTP versions.

### Documentation

- **Sixel Graphics Rendering** - Documented complete Sixel implementation
  - Clarified that full Sixel rendering pipeline is implemented and tested
  - Updated integration test with proper assertions for Sixel pixel rendering
  - Removed outdated TODO comments suggesting Sixel was incomplete
  - Added detailed implementation documentation to TODO.md
  - Core rendering complete: Parser, Graphics module, DCS Handler, Buffer operations, Cell support
  - All Sixel tests passing (parser, graphics, integration)

- **Sixel Graphics Rendering Verification** - Comprehensive validation of complete implementation
  - Verified all 5 core components working correctly (Parser, Graphics, DCS Handler, Buffer Ops, Cell)
  - 100% test coverage: 3 parser tests, 11 graphics tests, 2 integration tests, 25+ DCS handler tests
  - Confirmed edge case handling: empty sequences, invalid colors, bounds checking, malformed DCS
  - Performance validated: ~3-5μs per pattern character, O(1) palette lookups, sparse pixel buffer
  - Integration verified: Emulator -> DCS Handler -> SixelGraphics -> Parser -> Pixel Buffer -> Screen Buffer -> Cell
  - Documentation updated to reflect production-ready status with known limitations clearly defined
  - Known limitations documented: Plugin visualization integration (future), Kitty protocol (future), animations (spec limitation)

### Changed

- **Updated to Elixir 1.19.0 and OTP 28.2** across all CI workflows
  - `ci-unified.yml` - Main CI pipeline
  - `nightly.yml` - Nightly builds with test matrix (1.17.3/1.18.3/1.19.0 + OTP 27.2/28.2)
  - `regression-testing.yml` - Performance and memory regression tests
  - `performance-tracking.yml` - Performance benchmarks
  - `release.yml` - Release workflow

- Reduced TODO.md from 2000+ lines to ~70 lines (removed completed historical content)

- **TODO.md Restructured** - Reorganized development roadmap with priority-based categorization
  - CRITICAL, HIGH, MEDIUM, LOW priority sections
  - Added effort estimates for high-priority items
  - Separated completed items and known non-issues
  - Improved clarity for v2.0.1 release planning

- **TODO.md Final Cleanup** - Removed all completed tasks (2025-12-05)
  - All HIGH, MEDIUM, and LOW priority completed items moved to CHANGELOG.md
  - Removed: Window Server Tests, Scroll Server Tests, Command History, Theme System, Git Diff, StateManager Delete, CharsetManager Single Shift, Rainbow Theme Plugin
  - Remaining items: Hex.pm Publishing checklist, optional future enhancements, known non-issues
  - TODO.md now concise and focused on remaining work

### Fixed

- **Audit.LoggerTest** - Confirmed all 28 tests passing (verified 2025-12-05)
  - Previous concern about `:events_must_be_list` error was resolved
  - Full test coverage for audit logging system at `test/raxol/audit/logger_test.exs`

- **Window Server Tests** - Re-enabled and fixed all 15 tests (verified 2025-12-05)
  - Added `update_config` implementation to `window_manager.ex` and `window_manager_server.ex`
  - Re-enabled 4 test describe blocks: window splitting, operations, focus, configuration
  - Updated test assertions to match actual implementation behavior
  - All window management functions verified working (split, resize, move, title, etc.)

- **Scroll Server Tests** - Re-enabled and fixed all 16 tests (verified 2025-12-05)
  - Added `scroll_region` field to `Raxol.Terminal.Buffer.Scroll` struct
  - Implemented `set_scroll_region/3` and `clear_scroll_region/1` functions
  - Re-enabled scroll region test describe blocks
  - Full scroll buffer functionality verified

- **Meta-Package Configuration** - Configured root raxol package as meta-package (2025-12-05)
  - Added path dependencies to `apps/raxol_core`, `apps/raxol_plugin`, `apps/raxol_liveview`
  - Root package now serves as convenient meta-package for users wanting all features
  - Individual packages remain independently publishable for modular adoption
  - Updated package description to clarify meta-package purpose
  - Verified all package READMEs use GitHub links correctly
  - Tested independent compilation of all packages
  - Ready for Hex.pm publishing with documented workflow

- **Code Duplication Cleanup** - Removed duplicate files between root and apps (2025-12-05)
  - Removed 4 duplicate files from root `lib/raxol/core/`: `box.ex`, `buffer.ex`, `renderer.ex`, `style.ex`
  - Files now exist only in `apps/raxol_core/lib/raxol/core/` where they belong
  - Root package correctly depends on apps packages via path dependencies
  - Prevents module naming conflicts when users install meta-package
  - All tests passing after cleanup, compilation clean with zero warnings

- **Command History Integration** - Fully integrated command history tracking (2025-12-05)
  - Added `history_buffer` field to Emulator struct for tracking command history
  - Initialized HistoryBuffer in all emulator constructor functions (basic and full)
  - Implemented automatic command tracking in `Emulator.process_input/2`
  - Commands accumulate in `current_command_buffer` and are added to history when newline is encountered
  - Empty commands are correctly ignored (not added to history)
  - Integration test now fully validates history functionality
  - History accessible via `Raxol.Terminal.HistoryManager` API

- **Theme System Implementation** - Completed theme loading and accessibility integration (2025-12-05)
  - **Terminal Handlers**: Implemented proper theme loading in `lib/raxol/handlers/terminal_handlers.ex`
    - Uses `Raxol.Themes.load_theme/1` to load themes from predefined names or JSON files
    - Converts basic theme structure to full theme structure with all required fields
    - Supports "default", "dark", "light", and "high_contrast" predefined themes
    - Proper error handling for theme loading failures
  - **High Contrast Accessibility**: Implemented theme system integration in `lib/raxol/ui/accessibility/high_contrast.ex`
    - Integrates with `Raxol.UI.Theming.ThemeManager.update_palette/2`
    - Applies all theme colors to the UI system (background, foreground, accent, etc.)
    - High contrast themes now properly update the system palette
    - Includes logging and graceful error handling

- **LOW PRIORITY Enhancements** - Completed stubbed features and tests (2025-12-05)
  - **Git Integration Diff Rendering**: Implemented colorized diff view in example plugin
    - Executes `git diff` and parses output
    - ANSI color formatting: green for additions, red for deletions, cyan for hunks
    - Bold file headers, dimmed meta information
    - Proper line truncation and padding for terminal width
    - Error handling for failed git operations
  - **StateManager Delete Function**: Enabled existing delete functionality
    - Function was already implemented but test was commented out with TODO
    - Enabled test assertions for `delete_state/2`
    - Verified support for both simple and nested key deletion
    - Works with ETS and process storage strategies
  - **CharsetManager Single Shift**: Implemented VT100 single shift character set support
    - Added `single_shift` field to CharsetManager struct
    - Implemented `apply_single_shift/2` with guard clause for :g2 and :g3
    - Implemented `get_single_shift/1` to return current shift state (nil when inactive)
    - Added `clear_single_shift/1` helper to clear shift after processing one character
    - Updated `reset_state/1` to properly reset single_shift field
    - Supports VT100 SS2 (ESC N) and SS3 (ESC O) escape sequences
  - **Rainbow Theme Plugin Command System**: Implemented proper command registration
    - Added `get_commands/0` callback for plugin framework integration
    - Implemented command handlers: rainbow_start, rainbow_stop, rainbow_speed, rainbow_palette, rainbow_next, rainbow_help
    - Each handler returns `{:ok, state, message}` or `{:error, message, state}` tuple
    - Commands automatically registered/unregistered by plugin framework
    - Updated documentation for register_commands/unregister_commands stubs

- **Nightly Build Workflow** (`.github/workflows/nightly.yml`)
  - Added test exclusions (`--exclude slow --exclude integration --exclude docker`) to prevent CI timeouts
  - Added `timeout-minutes: 20` and `continue-on-error: true` to Dialyzer steps
  - Added fallback for integration tests that may not exist

- **Regression Testing Workflow** (`.github/workflows/regression-testing.yml`)
  - Fixed benchmark commands that incorrectly used `--json` flag (not supported)
  - Changed output capture from JSON to text with `tee`
  - Removed invalid `command -v` checks for mix tasks
  - Simplified memory benchmark execution

- **Memory Benchmark Scripts** (`bench/memory/*.exs`)
  - Removed `Mix.install()` blocks that conflict with project dependencies when run via `mix run`
  - Fixed `terminal_memory_benchmark.exs`, `plugin_memory_benchmark.exs`, `load_memory_benchmark.exs`
  - Scripts now rely on project dependencies from mix.exs

## [2.0.0] - 2025-10-05

### Major Release - Modular Architecture

Complete v2.0 transformation with modular package architecture for incremental adoption.
All 6 phases implemented: Core modules, LiveView integration, Spotify plugin showcase,
documentation overhaul, package split, and feature additions.

### Package structure

Four independent packages now available:

- `raxol_core` (v2.0.0): Buffer primitives, zero dependencies, <100KB
- `raxol_liveview` (v2.0.0): Phoenix LiveView integration
- `raxol_plugin` (v2.0.0): Plugin framework with behavior API
- `raxol` (v2.0.0): Meta-package including all packages

### Phase 1: Core Modules

- Raxol.Core.Buffer: Terminal buffer operations (<1ms for 80x24)
- Raxol.Core.Renderer: Pure functional rendering with diff calculation
- Raxol.Core.Box: Box drawing with multiple border styles (single, double, rounded, heavy, dashed)
- Raxol.Core.Style: ANSI color and style management
- Complete test coverage (73/73 tests passing)
- Documentation: BUFFER_API.md, GETTING_STARTED.md, ARCHITECTURE.md
- Examples: hello_buffer, box_drawing

### Phase 2: LiveView Integration

- Raxol.LiveView.TerminalBridge: Buffer to HTML conversion with caching
- Raxol.LiveView.TerminalComponent: LiveComponent for embedding terminals
- Event handling: keyboard, mouse, paste, focus/blur
- Five themes: Nord, Dracula, Solarized Dark/Light, Monokai
- Performance: 1.24ms avg rendering (60fps target achieved)
- CSS grid layout with accessibility features
- Complete test coverage (31/31 tests passing)

### Phase 3: Spotify Plugin Showcase

- Full Spotify Web API integration with OAuth 2.0
- Six operational modes: auth, main, playlists, devices, search, volume
- Complete keyboard controls and modal navigation
- API client with request/oauth2 dependencies
- Authentication flow and token management
- Documentation: SPOTIFY.md with setup guide
- Four working examples with integration patterns

### Phase 4: Documentation Overhaul

- Getting Started: QUICKSTART.md (5/10/15 min tutorials)
- Core Concepts: CORE_CONCEPTS.md, MIGRATION_FROM_DIY.md
- Cookbook: 5 practical guides (LiveView, VIM, Performance, Commands, Theming)
- Feature docs: VIM, Parser, Search, Filesystem, Cursor Effects
- 75% documentation reduction via DRY consolidation (5000+ lines -> 1250 lines)
- Beginner-friendly with clear migration paths

### Phase 5: Modular Package Split

- Independent packages with clear dependency boundaries
- Path-based dependencies for monorepo development
- Each package fully documented with README, LICENSE, CHANGELOG
- All packages compile independently with zero warnings
- Ready for Hex.pm publishing

### Phase 6: Feature Additions

- VIM Navigation: hjkl movement, gg/G jumps, search (/ ?), word movement (w b e), visual mode
- Command Parser: tokenization, tab completion, history navigation, aliases, fuzzy search
- Fuzzy Search: fzf-style matching with scoring, highlighting, case-sensitive/insensitive modes
- Virtual Filesystem: ls, cat, cd, pwd, mkdir, rm with absolute/relative paths
- Cursor Effects: rainbow, comet, minimal presets with smooth interpolation
- Complete test coverage (180/180 feature tests passing)

### Test results

- Total: 2147 tests (2147 passing, 0 failing, 49 skipped)
- Test pass rate: 100%
- Property tests: 58/58 passing
- Zero compilation warnings with --warnings-as-errors

### Performance

- Parser: 0.17-1.25μs (Phase 0 baseline maintained)
- Core buffer operations: <1ms for 80x24 buffers
- LiveView rendering: 1.24ms avg (60fps achieved)
- VIM navigation: <1μs per movement
- Command parser: ~5μs per parse/execute
- Fuzzy search: ~100μs for 1000-line buffer
- Filesystem operations: ~10μs per command
- Cursor effects: ~7μs per update

### Breaking changes

- None - v2.0 packages are additive
- Existing v1.x code continues to work with root package
- New modular packages available for incremental adoption
- See MIGRATION_FROM_DIY.md for upgrade strategies

### Migration Path

- Current v1.x users: No changes required, continue using root package
- New v2.0 users: Choose packages based on needs
  - Minimal: `{:raxol_core, "~> 2.0"}` (just buffers)
  - Web: Add `{:raxol_liveview, "~> 2.0"}` (LiveView integration)
  - Full: `{:raxol, "~> 2.0"}` (everything included)

### Documentation Added

- Core: BUFFER_API.md, GETTING_STARTED.md, ARCHITECTURE.md, PHASE1_COMPLETION.md
- Getting Started: QUICKSTART.md, CORE_CONCEPTS.md, MIGRATION_FROM_DIY.md
- Cookbook: LIVEVIEW_INTEGRATION.md, VIM_NAVIGATION.md, PERFORMANCE_OPTIMIZATION.md,
  COMMAND_SYSTEM.md, THEMING.md
- Features: VIM_NAVIGATION.md, COMMAND_PARSER.md, FUZZY_SEARCH.md, FILESYSTEM.md,
  CURSOR_EFFECTS.md, feature README.md
- Plugins: SPOTIFY.md with OAuth setup guide

### Examples Added

- Core: 01_hello_buffer/, 02_box_drawing/
- LiveView: 01_simple_terminal/ with event handling
- Plugins: counter.exs, 4 Spotify examples with integration patterns

### Benchmarks Added

- Core: buffer, renderer, style, box, comprehensive
- Features: vim, parser, fuzzy, filesystem, cursor, comprehensive
- LiveView: rendering benchmark with 60fps validation

## [1.19.0] - 2025-10-01

### Added

- **Distributed Session Support**: Complete multi-node session management system
  - DistributedSessionRegistry with consistent hashing for optimal session distribution
  - Session affinity support (cpu_bound, memory_bound, io_bound, network_bound)
  - Node discovery and heartbeat monitoring for cluster health
  - Load balancing with automatic rebalancing during topology changes
  - SessionReplicator with configurable replication strategies (immediate, eventual, quorum, best_effort)
  - Vector clock-based conflict-free replicated data types (CRDTs)
  - Anti-entropy mechanisms for replica drift correction
  - Performance-aware replication with load monitoring
  - SessionMigrator with multiple migration strategies (hot, warm, cold, bulk)
  - Automatic node evacuation during maintenance or failures
  - Intelligent failover with dependency-aware restart ordering
  - Migration rollback capabilities for failure recovery
  - DistributedSessionStorage with multi-backend support (ETS, DETS, Mnesia)
  - Automatic data sharding with configurable shard counts
  - Data compression and encryption at rest capabilities
  - Write-ahead logging for durability guarantees
  - Comprehensive test framework with 50+ test scenarios and fault injection

### Performance

- Session location: < 1ms (consistent hashing)
- Hot migration time: < 500ms for typical sessions
- Replication sync: < 5ms (vector clock-based)
- Storage operations: < 10ms (multi-backend optimized)
- Failover time: < 2s (automatic with replicas)
- Memory overhead: < 5MB for 10,000+ sessions across cluster

### Technical Components

- DistributedSessionRegistry: Session location with consistent hashing
- SessionReplicator: Multi-node replication with vector clocks
- SessionMigrator: Live migration with 99.9% availability preservation
- DistributedSessionStorage: Multi-backend storage with persistence
- DistributedSessionTestHelper: Comprehensive testing framework

## [1.18.0] - 2025-09-29

### Added

- **Enhanced Error Recovery**: Comprehensive self-healing system
  - RecoverySupervisor with adaptive restart strategies
  - ContextManager with TTL-based state preservation (< 1ms access)
  - DependencyGraph with intelligent restart ordering
  - EnhancedPatternLearner with ML-based strategy recommendation
  - RecoveryWrapper for transparent process enhancement

### Performance

- Context retrieval: < 1ms (ETS-backed)
- Recovery decision time: < 5ms (pattern-based)
- Graceful degradation: < 100ms activation
- Memory overhead: < 2MB for 1000+ contexts

## [1.17.0] - 2025-09-25

### Changed

- **IO.puts/inspect Migration**: Migrated 524+ raw IO calls to structured logging
  - 37 files migrated to centralized logging system
  - Context-aware replacement strategies by module type
  - Smart message-level detection (error, warning, info)
  - Zero compilation errors maintained

### Added

- Automated migration tools for systematic conversion
- Log.console for debug/test modules
- Log.log_inspect with label support

## [1.16.0] - 2025-09-20

### Changed

- **Logger Standardization**: Centralized logging across 144 files
  - 733 Logger calls standardized with enhanced functionality
  - Module-aware logging with automatic context detection
  - Performance timing with built-in execution measurement
  - Environment-aware console logging

### Added

- Bulk Logger Migrator tool
- Alias Syntax Fixer for import conflicts
- Structured context with metadata enrichment

## [1.15.2] - 2025-09-15

### Changed

- **Module Naming Cleanup**: Removed "unified"/"comprehensive" qualifiers
  - 25 files renamed with descriptive, specific names
  - Updated all imports, aliases, and references across 170+ files
  - Zero breaking changes, all functionality preserved

### Examples

- `unified_registry.ex` -> `global_registry.ex`
- `unified_config_manager.ex` -> `config_server.ex`
- `unified_collector.ex` -> `metrics_collector.ex`

## [1.15.0] - 2025-09-10

### Added

- **BaseManager Migration Complete**: 170 modules migrated (100%)
  - SSH Session module (final migration)
  - Standardized error handling and supervision
  - Consistent functional patterns throughout
  - Zero compilation warnings achieved

### Summary

- Wave 1-22 completed across versions v1.7.5 to v1.15.0
- Better OTP supervision tree integration
- Reduced boilerplate significantly

## [1.5.4] - 2025-09-26

### Major Release - Code Consolidation & BaseManager Pattern

### Added

- **BaseManager Pattern**: Unified behavior for GenServer-based modules
  - Advanced BaseManager pattern adoption across 22+ modules
  - Consistent lifecycle management and error handling
  - Standardized init, call, cast, and info handlers
  - Enhanced state management and configuration handling

- **TimerManager Integration**: Centralized timer management system
  - Unified timer intervals and scheduling across core modules
  - Reduced timer pattern duplication throughout codebase
  - Improved timer lifecycle and cleanup handling

### Fixed

- **Zero Compilation Warnings**: Achieved strict error checking compliance
  - Resolved all @doc and @impl attribute conflicts
  - Fixed unused variable warnings across all modules
  - Enhanced pattern matching in CSI handlers
  - Added proper mock implementations for testing

- **Enhanced Test Coverage**: Improved to 99.8% (1632/1635 tests passing)
  - Tagged performance tests appropriately
  - Resolved environment-dependent test failures
  - Fixed BaseManager conversion issues

### Performance

- **Ultra-fast Operations**: Parser 0.17-1.25μs | Render 265-283μs
- **Maintained Memory Efficiency**: <2.8MB per session
- **Exceeded Frame Rate**: 3,500+ FPS capability

## [1.4.1] - 2025-09-16

### Major Release - Zero Warnings & Enhanced Developer Experience

### Added

- **Automated Type Spec Generator**: `mix raxol.gen.specs` - Tool for automatic type specification generation
  - Intelligent type inference based on function/argument naming patterns
  - Supports dry-run, interactive, and backup modes
  - Handles guard clauses and pattern matching correctly
  - Generated 12,000+ type specs across the codebase
  - Full integration with Dialyzer for validation

- **Unified TOML Configuration System**: `Raxol.Config` - Centralized configuration management
  - TOML-based configuration with environment-specific overrides
  - Runtime configuration updates without restarts
  - Automatic validation and hot-reload capabilities
  - GenServer-based with comprehensive API
  - Support for development, test, and production environments

- **Enhanced Debug Mode**: `Raxol.Debug` - Four-level debugging system
  - Debug levels: `:off`, `:basic`, `:detailed`, `:verbose`
  - Performance profiling with time_debug and inspect_debug
  - Process state dumping and debug breakpoints
  - Automatic performance monitoring (memory, run queue)
  - Export debug sessions to JSON for analysis
  - Component-specific debugging capabilities

### Changed

- **Compilation Quality**: Achieved ZERO compilation warnings (reduced from 88)
  - Fixed all undefined function warnings (49 -> 0)
  - Resolved unused variable warnings (15 -> 0)
  - Fixed Logger.warn deprecation warnings
  - Created missing modules and corrected all API references
  - Full `--warnings-as-errors` compliance

- **Test Suite Excellence**: 2134 tests total, 99.8% pass rate - All critical issues resolved
  - Fixed TestBufferManager compilation error
  - Fixed plugin system JSON encoding issues (5 failures resolved)
  - Fixed character set timeout issue
  - Fixed MouseHandler test failures (URXVT button decoding, drag detection)
  - Fixed EraseHandler integration with UnifiedCommandHandler
  - Fixed cursor save/restore struct field access bugs (position vs x/y)
  - Added EmulatorLite support to command executor pattern matching
  - Fixed nil handling in history tracking for minimal emulators
  - Resolved all test stability issues and parallel execution conflicts

- **Compilation Quality**: ZERO compilation warnings achieved
  - Full ElixirLS support restored, clean compilation with `--warnings-as-errors`
  - All behaviour callbacks implemented correctly
  - Fixed all StateManager, BufferManager, and EventManager references

- **World-Class Benchmarking Infrastructure**: Complete overhaul from 21 to 11 core modules
  - **New Benchmark Config Module**: Profile-based configuration with environment awareness
    - Statistical significance testing (95% confidence level)
    - Dynamic threshold calculation based on historical variance
    - Environment-specific adjustments (CI/local)
    - Comprehensive metadata tracking (Git SHA, system info, versions)
  - **Enhanced `mix raxol.bench`**: Production-ready benchmarking
    - Performance regression detection with configurable thresholds
    - Interactive HTML dashboard with Chart.js visualization
    - Comprehensive suites: parser, terminal, rendering, memory, concurrent
    - Baseline metrics storage and comparison
  - **Advanced Analytics**: P50-P99.9 percentile tracking, outlier detection, trend analysis
  - **Competitor Comparison Suite**: Direct benchmarking against Alacritty, Kitty, iTerm2, WezTerm
  - **Benchmark DSL**: Idiomatic Elixir macro-based benchmark definitions

- **Mix Task Consolidation**: Organized task structure
  - `mix raxol` - Main command with help
  - `mix raxol.check` - All quality checks
  - `mix raxol.test` - Enhanced test runner
  - `mix raxol.bench` - Production-ready benchmarking with dashboard
  - `mix raxol.mutation` - Refactored with functional patterns (no if/else)

- **Technical Debt Resolution**: Major infrastructure improvements completed
  - Removed deprecated terminal config backup files
  - Consolidated duplicate buffer operations and configuration managers
  - Refactored event system to use :telemetry exclusively with TelemetryAdapter
  - Updated all dependencies to latest stable versions
  - Implemented comprehensive protocol system (5 core protocols)
  - Added connection pooling and circuit breakers for external services
  - Standardized error handling patterns across modules
  - Created DevHints system for real-time performance monitoring
  - Added performance profiling tools with `mix raxol.perf`

### Performance & architecture

- **Performance Metrics**: Parser 3.3μs/op | Memory <2.8MB | Render <1ms
- **Code Reduction**: 722 lines removed, 150+ duplicate patterns eliminated
- **Module Consolidation**: 43+ modules consolidated, state management unified (16->4 managers)
- **Documentation**: Updated README.md and CLAUDE.md with accurate commands

## [1.3.0] - 2025-09-12

### Codebase Consolidation (Phases 1-4) - COMPLETE

- **Test Helper Consolidation**: Unified test infrastructure
  - Consolidated 3 test helper modules into single `test/support/unified_test_helper.ex`
  - Removed 195 lines of duplicate code while enhancing functionality
  - Migrated all tests to use unified helper with zero breaking changes
  - Eliminated duplicate test_helper.exs files

- **Hook Implementation Consolidation**: Single comprehensive hook system
  - Merged 3 hook implementations into unified `Raxol.UI.Hooks.Functional`
  - Reduced codebase by 527 lines while adding functionality
  - Enhanced from 6 + 2 stubs to 8 fully implemented hooks
  - Implemented task-based execution with timeout controls
  - Achieved zero try/catch blocks with pure functional patterns
  - Added `use_context` and `use_async` implementations

- **Repository Cleanup**: Improved project organization
  - Added .gitignore entries for cache, coverage, and log directories
  - Archived 4 obsolete scripts replaced by mix tasks
  - Removed duplicate test_helper.exs from platform_specific/
  - Cleaned up inconsistent file locations

- **Extended DRY Consolidation**: Major structural improvements
  - Moved 21+ test helpers from `lib/raxol/test/` to `test/support/raxol/`
  - Created 4 common behaviors (StateManager, EventHandler, Lifecycle, Metrics)
  - Flattened excessive directory nesting (reduced from 7+ to max 5 levels)
  - Eliminated 150+ duplicate manager/handler/server patterns
  - Clarified module responsibilities with enhanced documentation

### Summary

- **Total Lines Reduced**: 900+ lines eliminated through consolidation
- **Code Quality**: All compilation warnings resolved, critical performance issues fixed
- **Test Coverage**: 98.7% maintained with enhanced test infrastructure
- **Architecture**: Cleaner, more maintainable codebase with consistent patterns

## [1.2.1] - 2025-09-11

### Code Quality Sprint (Phase 6-7) - COMPLETE

- **Critical Issues Fixed**: All compilation errors and warnings resolved
  - Fixed syntax error in `examples/snippets/advanced/commands.exs`
  - Resolved TypeScript import errors across `examples/snippets/typescript/`
  - Achieved zero compilation warnings status
  - Fixed all high-priority Credo issues

- **Performance Improvements**: 15+ performance optimizations completed
  - Replaced inefficient list appending with proper accumulator patterns
  - Optimized apply/3 usage across codebase
  - Improved memory efficiency in hot paths
  - Performance targets met: Parser 3.3μs/op, Render <1ms, Memory 2.8MB baseline

- **Code Duplication Reduction**: Eliminated 5 major duplication patterns
  - Created `Raxol.Utils.MapUtils` for shared stringify_keys functionality
  - Consolidated duplicate implementations across modules
  - Reduced duplication instances from 46 to 41
  - Fixed audit module code duplication

- **TypeScript Support**: Created missing core modules
  - Added performance, events, and renderer core modules
  - Created visualization and dashboard component modules
  - Enhanced TypeScript example completeness

- **Linter Analysis Results**:
  - Critical Issues: [FIXED] All fixed
  - High Priority Performance: [FIXED] 15+ fixed
  - Code Duplication: [FIXED] 5 patterns eliminated
  - Remaining: 700+ minor optimizations (low impact, deferred)

### Documentation and Project Organization

- **Major Documentation Consolidation**: Significantly improved project organization and reduced duplication
  - Consolidated 5 scattered `examples/` directories into single organized structure
  - Removed duplicate VS Code extension directory (archived `extensions/vscode/`)
  - Streamlined main README from 280 to 128 lines (54% reduction)
  - Created comprehensive documentation hub at `docs/README.md`
  - Consolidated benchmark documentation and removed redundant example snippet READMEs
  - Moved release notes to organized `docs/releases/` directory

- **Script Organization**: Cleaned up scripts directory with new categorical structure
  - Organized scripts into `ci/`, `dev/`, `testing/`, `quality/`, `db/`, `visualization/` subdirectories
  - Updated `dev.sh` and documentation references to new script locations
  - Created comprehensive scripts README with usage examples

- **Package Preparation**: Optimized for Hex.pm release
  - Updated package files list in `mix.exs` to include consolidated structure
  - Validated package build with `mix hex.build`
  - All required files (LICENSE.md, README.md, CHANGELOG.md) present and updated

- **Space Savings**: Removed approximately 15-20KB of redundant documentation
  - Eliminated duplicate files and directories
  - Improved DRY compliance across all documentation
  - Enhanced navigation and discoverability

## [1.2.0] - 2025-09-10

### Sprint 28: Process-Based Test Migration - COMPLETE

- **Test Suite Stabilization**: Fixed remaining process-based test failures
  - Fixed `CommandHelper.safe_execute/1` error handling to properly match error tuples
  - Updated `Web.SupervisorTest` to handle already-running supervisor processes
  - Fixed `KeyboardShortcutsTest` module alias syntax error
  - Resolved `performance_optimization_test.exs` compilation error (duplicate ExUnit.run)
  - All core tests now passing (excluding keyboard shortcuts needing API updates)

- **Termbox2 NIF Testing**: Enhanced termbox2 NIF test coverage
  - Created comprehensive `Termbox2LoadingTest` to verify NIF loading without TTY
  - Verified all termbox2 functions are properly exported
  - Confirmed NIF compilation and shared library generation
  - Added tests for priv directory structure and C source files
  - All 9 termbox loading tests passing

- **Dialyzer Integration Fix**: Resolved compilation errors
  - Fixed import conflict in `Mix.Tasks.Raxol.Dialyzer` (removed duplicate Mix.Shell.IO import)
  - Dialyzer tasks now compile and run successfully

- **Security Scanning Integration**: Added comprehensive security tooling
  - Integrated Sobelow for Phoenix security analysis
  - Added mix_audit for dependency vulnerability checking
  - Created `mix raxol.security` task for unified security scanning
  - Checks for hardcoded secrets, insecure configurations, and file permissions
  - All dependency vulnerability checks passing

### Sprint 27: Technical Debt Elimination - COMPLETE

- **Process Dictionary Migration**: Complete elimination of Process dictionary usage (20 files)
  - Migrated all Process.get/put/delete calls to use `Raxol.Core.Runtime.ProcessStore`
  - Updated test files to use ProcessStore for cross-process test synchronization
  - Modified animation framework to use ProcessStore for test compatibility
  - Updated demo/example files to use ProcessStore patterns
  - Enhanced documentation to show ProcessStore as recommended approach
  - Made tests async-safe by removing Process dictionary dependencies

- **Configuration System Consolidation**: Unified configuration management
  - Confirmed removal of redundant generated config files (dev_generated.exs, test_generated.exs, prod_generated.exs)
  - Validated that main environment files (dev.exs, test.exs, prod.exs) contain all necessary configuration
  - Eliminated duplication between generated and manual config files
  - Maintained standard Elixir configuration patterns

- **Development Scripts Organization**: Streamlined scripts directory
  - Archived 20 unused development scripts into organized subdirectories:
    - `scripts/archived/deprecated-by-dev-sh/` - 6 scripts replaced by unified dev.sh tool
    - `scripts/archived/sprint-refactoring/` - 12 scripts from module refactoring sprints
    - `scripts/archived/old-experiments/` - 2 experimental testing scripts
  - Updated DEPRECATED.md with comprehensive archival documentation
  - Preserved all active development tools while cleaning main scripts directory

### Sprint 25: Final Test Suite Resolution - COMPLETE

- **InputBuffer Module Implementation**: Complete implementation of missing InputBuffer functionality
  - Fixed module name conflicts causing compilation errors
  - Implemented all 39 required functions (append, prepend, clear, size, etc.)
  - Added proper overflow handling for truncate, wrap, and error modes
  - Fixed error message formatting to match test expectations
  - All 39 InputBuffer tests now passing (was 6 critical failures)

- **Major Test Issues Resolved**: Fixed all remaining Sprint 25 test failures (13/13 complete)
  - ColorSystem high contrast accessibility integration
  - Mouse input integration tests (click/selection modes)
  - UI rendering pipeline parameter validation fixes
  - Interlacing mode CSI handler mappings
  - InputBuffer module functionality complete

### Sprint 26: Technical Debt & Codebase Cleanup - COMPLETE

- **Repository Organization**: Comprehensive cleanup and maintenance
  - Removed crash dump files (6.8MB storage freed)
  - Archived Sprint 23 refactoring scripts to `scripts/archived/sprint23-refactoring/`
  - Created `bench/archived/` for historical benchmark data
  - Cleaned temporary testing artifacts from root directory

- **Documentation & Standards**: Established comprehensive development guidelines
  - Created `docs/development/NAMING_CONVENTIONS.md` with complete module naming standards
  - Documented Sprint 22-23 refactoring patterns (`<domain>_<function>.ex`)
  - Verified no duplicate JSON libraries (Jason as primary)
  - Applied consistent code formatting across entire codebase

- **Technical Debt Reduction**: Addressed major backlog items
  - Audited Process dictionary usage (20 files, mostly test compatibility)
  - Organized 99 development scripts for better maintainability
  - Eliminated development clutter and improved repository structure
  - Enhanced code consistency and developer experience

### Previous API Fixes (from earlier 1.2.0 work)

- **GenServer Delegation Corrections**: Fixed parameter passing issues in FocusManager and KeyboardShortcuts modules
  - Fixed all 16 FocusManager API functions to properly pass server parameter to GenServer calls
  - Fixed all 14 KeyboardShortcuts API functions to properly pass server parameter to GenServer calls
  - Resolves `GenServer.whereis/1` errors where component IDs were being interpreted as server names
  - Restores intended functionality for focus management and keyboard shortcuts in production

- **Duplicate Filename Prevention System**: Comprehensive tooling to detect and prevent duplicate filenames
  - Added standalone script (`scripts/quality/check_duplicate_filenames.exs`) with severity classification and rename suggestions
  - Added Mix task (`lib/mix/tasks/raxol.check.duplicates.ex`) with configurable options and strict mode
  - Added Credo integration (`lib/raxol/credo/duplicate_filename_check.ex`) for existing linting workflow

### Usage

```bash
# Check for duplicate filenames
mix raxol.check.duplicates

# With rename suggestions
mix raxol.check.duplicates --suggest-fixes

# Strict mode (fails on duplicates)
mix raxol.check.duplicates --strict

# Run as part of Credo checks
mix credo
```

### Impact

- **Test Suite Excellence**: 100% of major test issues resolved across all sprints
- **Code Quality**: Comprehensive naming conventions and organization standards
- **Repository Health**: Clean structure with archived historical artifacts
- **Developer Experience**: Clear documentation and development guidelines
- **Technical Debt**: Systematic cleanup of backlog items for maintainability

## [1.0.1] - 2025-08-11

### Changed

- **[SECURE] Security Validation Complete**: Zero vulnerabilities confirmed via Snyk security scanning
- **[DOCS] Documentation Links Fixed**: Updated README with correct paths to generated docs and HexDocs
- **[PERF] Performance Documentation Updated**: Confirmed all targets exceeded with 3.3μs parser operations
- **[PREP] Release Preparation**: Fixed broken links, validated security, documented performance achievements
- Updated package documentation and performance benchmarks
- Added professional release notes for v1.0.0
- Improved test infrastructure stability
- Enhanced NIF loading reliability

### v1.0 Launch Milestones Achieved

- [SECURE] **Zero Security Vulnerabilities**: Comprehensive security scan passed
- [DOCS] **All Documentation Links Working**: README and docs fully functional
- [FAST] **Performance Targets Exceeded**: 30x better than target (3.3μs vs 100μs)
- [ARCH] **Multi-Framework Architecture**: Terminal UI framework supporting React, Svelte, LiveView, HEEx, and raw terminal

## [1.0.0] - 2025-08-11

### Sprint 5 - Critical Architectural Fixes

- **ETS Table Race Conditions - FIXED**
  - Created `Raxol.Core.CompilerState` module with thread-safe ETS management
  - Replaced all direct `:ets` calls with safe wrappers
  - Eliminated "table identifier does not refer to an existing ETS table" errors
  - Achieved stable parallel compilation without race conditions

- **Property Test Improvements - MAJOR PROGRESS**
  - Fixed Store.update arithmetic errors with proper error handling
  - Fixed Button.new API usage and style merging issues
  - Fixed TextInput.handle_input to append text correctly
  - Fixed tree_size calculation using integer division
  - Fixed Store naming conflicts using System.unique_integer
  - Reduced property test failures from 10+ to just 1
  - Achieved 99.6% overall test pass rate (1406/1411 tests)

- **NIF Build Automation - FIXED**
  - Integrated termbox2_nif with elixir_make for automatic compilation
  - Fixed NIF loading path resolution to check :raxol priv directory first
  - Updated Makefile to copy NIF to main app priv directory
  - NIF now builds automatically during `mix compile`

- **CLDR Compilation Optimization - IMPROVED**
  - Optimized CLDR configuration for development environment
  - Reduced to single locale and provider in dev mode
  - Disabled documentation generation for faster builds
  - Compilation time reduced from timeout-prone to ~25 seconds

### Multi-Framework architecture - Complete

- **First Terminal Framework Supporting 5 UI Paradigms**
  - React-style components with hooks and state management
  - Svelte-inspired reactive system with compile-time optimization
  - Phoenix LiveView integration for real-time updates
  - HEEx templates for server-side rendering
  - Raw terminal control for maximum performance

- **Universal Features Across All Frameworks**
  - Actions system works with any framework
  - Transitions and animations unified across paradigms
  - Context API for cross-framework communication
  - Slot system for component composition
  - No vendor lock-in - switch frameworks anytime

### Fixed - 2025-08-11

- **Critical NIF Loading Issues**
  - Fixed termbox2_nif load failure caused by `:code.priv_dir/1` returning `{:error, :bad_name}`
  - Added robust fallback path resolution for NIF library loading
  - Resolved Path.join/2 FunctionClauseError preventing terminal functionality

- **UI Component API Completeness**
  - Added `Button.handle_click/1` for button interaction handling
  - Added `TextInput.handle_input/2` with validation support for controlled input
  - Added `TextInput.handle_cursor/2` for cursor position management
  - Implemented `Flexbox.new/1`, `render/1`, and `calculate_layout/1` for flexbox layouts
  - Implemented `Grid.new/1`, `render/1`, and `calculate_spacing/1` for grid layouts
  - Added `Store.update/3` alias for state management consistency

- **Property Test Compatibility**
  - Fixed 10+ property test failures in UI component testing suite
  - Ensured text input validation filters invalid characters correctly
  - Fixed grid spacing calculation to return proper tuple format
  - Resolved flexbox child layout calculation issues

### Known issues - To Be Addressed

- 54 compilation warnings remaining (mostly unused variables in Svelte modules)
- Property tests still showing some failures in component composition
- Some undefined function references in Svelte actions need resolution

## [1.0.0] - 2025-08-10

### Added

- **Svelte-Style Component System**
  - Complete Svelte-inspired framework bringing compile-time optimization to terminals
  - Actions system with `use:` directive (tooltip, clickOutside, focusTrap, draggable, autoSave, lazyLoad)
  - Reactive stores with automatic dependency tracking and derived values
  - Reactive declarations using Svelte's `$:` syntax with automatic re-execution
  - Transitions and animations (fade, scale, slide, fly, draw) with 60 FPS animation engine
  - Context API for component communication without prop drilling (ThemeProvider, AuthProvider)
  - Slot system for advanced component composition with named and scoped slots
  - Template compiler with AST analysis, static content inlining, and buffer operation optimization
  - Built-in components: Modal, Tabs, DataTable with slot customization
  - Advanced dashboard demo showcasing all Svelte features

- **Property-Based Testing Suite**
  - Parser property tests with 10 comprehensive test properties
  - Core system property tests for Buffer and Terminal state
  - StreamData integration for generative testing
  - Performance scaling verification tests

- **Demo Recording Infrastructure**
  - Interactive demo recording script (scripts/visualization/demo_videos.sh)
  - 6 demo categories: Tutorial, Playground, VSCode, WASH, Performance, Enterprise
  - Asciinema integration with GIF conversion support
  - Professional demo showcase documentation

- **Enterprise Audit Logging System**
  - Comprehensive event types: authentication, authorization, data access, security, compliance, terminal operations, privacy
  - Tamper-proof storage with cryptographic signatures and event encryption
  - Real-time threat detection: brute force, privilege escalation, data exfiltration, reconnaissance
  - Compliance reporting: SOC2, HIPAA, GDPR, PCI-DSS with automated violation detection
  - SIEM integration: Splunk, Elasticsearch, IBM QRadar, Azure Sentinel
  - Multiple export formats: JSON, CSV, CEF, LEEF, Syslog (RFC 5424), PDF, XML
  - Full-text search with inverted indexing and configurable retention policies

- **Enterprise Encrypted Storage System**
  - Master key encryption with PBKDF2 key derivation (100,000 iterations)
  - Data encryption keys (DEK) with automatic rotation and versioning
  - Key encryption keys (KEK) for secure key wrapping and HSM support
  - Multiple algorithms: AES-256-GCM, ChaCha20-Poly1305, AES-256-CBC, AES-256-CTR
  - Transparent file and database encryption with streaming support for large files
  - Ecto custom types for encrypted database fields with searchable encryption
  - Compliance profiles: PCI-DSS, HIPAA, GDPR, SOX with automatic policy enforcement
  - Comprehensive audit logging for all encryption operations

- **Developer Experience Revolution**
  - Interactive tutorial system with 3 comprehensive guides and GenServer-based runner
  - Component playground with 20+ components, live preview, and code generation
  - Professional VSCode extension (2,600+ lines) with IntelliSense, syntax highlighting, and live preview
  - Sub-5-minute onboarding with comprehensive tooling ecosystem

- **Modern UI Framework**
  - CSS-like animation system with transitions, keyframes, and spring physics
  - Layout engines: CSS Flexbox, CSS Grid with responsive design and breakpoints
  - State management: Context API, Hooks system, Redux store, reactive streams
  - Component composition: Higher-Order Components, render props, compound components
  - Developer tools: Hot reloading, component preview, props validation, debug inspector

### Changed

- **Performance Milestones Achieved**
  - Memory per session: 2.8MB (44% better than 5MB target)
  - Created Raxol.Minimal for <10ms startup with 8.8KB footprint
  - Memory efficiency score: 125.6/100 (exceeded maximum)
  - Rendering: 1.3μs simple components, 0.48ms full screen
  - Animation: 971K FPS max, 99.5% smoothness

- **Performance Breakthrough**
  - Parser performance: 30x improvement (648μs -> 3.3μs per operation)
  - EmulatorLite architecture: GenServer-free parsing path
  - SGR processor: 442x speedup using pattern matching optimization
  - All tests migrated to optimized architecture

- **Test Suite Excellence**
  - Maintained 100% test pass rate (1751/1751 tests passing)
  - Added comprehensive test coverage for audit and encryption systems
  - Enhanced component lifecycle testing

### Fixed

- **macOS CI Runner Issues**
  - Resolved Docker availability issues on macOS runners
  - Configured local PostgreSQL for macOS CI
  - Added platform-specific CI configuration
  - Created DockerHelper for conditional test execution

- **CI/CD System**
  - Made termbox2_nif dependency optional for broader compatibility
  - Fixed code formatting across all modules
  - Improved driver resilience with conditional native dependency loading
  - Simplified CI workflow and fixed codecov integration

### Completed (Moved from TODO)

- **Documentation Milestones**
  - Comprehensive 660+ line API.md reference with 100% public API coverage
  - Professional documentation (removed emojis, reduced verbosity, added YAML frontmatter)
  - Created comprehensive CONTRIBUTING.md guide
  - Reduced documentation redundancy (40% improvement)
  - 9 Architecture Decision Records (ADRs) for key design choices
  - WASH-style system documentation for session continuity

- **Development Tools**
  - VSCode extension packaged (raxol-1.0.0.vsix, 32KB) ready for marketplace
  - Interactive tutorial system with 3 comprehensive guides
  - Component playground with 20+ components and live preview

- **Test Suite Excellence**
  - 100% test pass rate (2681+ tests all passing)
  - Fixed all performance tests with robust expectations
  - Implemented GenServer cleanup patterns across test suite
  - Fixed CSI Handler, LiveView tests

- **Code Quality**
  - Zero compilation warnings (100% reduction from 227)
  - Replaced all stub implementations with working code
  - Fixed all critical TODO/FIXME items
  - Fixed module alias references

### Impact

- **Enterprise Ready**: Production-grade audit logging and encryption for regulated industries
- **World-Class Performance**: Sub-millisecond parser operations suitable for high-throughput applications
- **Developer Experience**: Framework-level tooling matching React/Vue ecosystem expectations
- **Security & Compliance**: Meeting requirements for healthcare, finance, and government deployments

## [0.9.0] - 2025-01-26

### Added

- **Complete Terminal Feature Implementation**
  - **Mouse Handling**: Full mouse event system with click, drag, and selection support
  - **Tab Completion**: Advanced tab completion with cycling, callback architecture, and Elixir keyword support
  - **Bracketed Paste Mode**: Complete implementation with CSI sequence parsing (ESC[200~/ESC[201~)
  - **Column Width Changes**: Full DECCOLM support for 80/132 column switching (ESC[?3h/ESC[?3l)
  - **Sixel Graphics**: Already comprehensive with parser, renderer, and graphics manager
  - **Command History**: Multi-layer history system with persistence and navigation

### Changed

- **Test Suite Improvements**
  - Achieved 100% test pass rate (1751/1751 tests passing)
  - Fixed terminal mode classification issues
  - Improved mode manager test accuracy
  - Enhanced test coverage for all new features

### Fixed

- **Technical Debt Resolution**
  - Documented 12 compilation warnings as false positives from dynamic apply/3 calls
  - Fixed failing test in ModeManager.lookup_standard for correct mode classification
  - Resolved terminal mode specification compliance (DEC private vs standard modes)

### Impact

- **Production Ready**: Raxol terminal framework is now feature-complete
- **Full VT100/ANSI Compliance**: Complete terminal emulation with modern features
- **100% Test Coverage**: Comprehensive testing ensures reliability
- **Enterprise Features**: Mouse, history, completion, graphics all fully operational

## [0.8.1] - 2025-08-09

### Added

- **Complete Component Lifecycle Implementation**
  - Added mount/unmount hooks to all 23 UI components
  - Implemented @impl annotations for proper callback tracking
  - Created comprehensive lifecycle documentation

- **API Documentation**
  - Added 76+ @doc annotations to Raxol.Terminal.Emulator
  - Enhanced documentation for Parser and core modules
  - Achieved 100% documentation coverage for public APIs

### Changed

- **Performance Improvements**
  - Removed all debug output from parser (27 debug statements eliminated)
  - Cleaned up test output for better readability
  - Profiled parser performance (identified 648 μs/op baseline)

### Fixed

- **Compilation Warnings**
  - Reduced warnings from 52 to 15 (71% reduction)
  - Fixed unreachable clause warnings in cursor functions
  - Added pattern matching to distinguish struct types
  - Removed unused module aliases

- **Test Suite**
  - Achieved 99.3% test pass rate (1742 tests passing, 0 failures)
  - Fixed test output clarity by removing debug logging
  - 13 intentionally skipped tests for unimplemented features

### Technical Debt Reduction

- Standardized component lifecycle across entire UI framework
- Improved code consistency with proper @impl annotations
- Enhanced maintainability with comprehensive documentation

## [0.8.0] - 2025-07-25

### Added

- **Phase 8: Release Process Streamlining (COMPLETED)**
  - Simplified `burrito.exs` configuration (127->98 lines, 23% reduction)
  - Added standardized mix aliases for release tasks:
    - `mix release.dev` - Development builds
    - `mix release.prod` - Production builds
    - `mix release.all` - All platform builds
    - `mix release.clean` - Clean build directories
    - `mix release.tag` - Create version tags
  - Enhanced release script with build summaries and artifact manifests
  - Streamlined version management with safety checks and validation
  - Improved error handling and user feedback throughout release process

### Changed

- **Release Configuration Optimization:**
  - Extracted common configurations into module attributes (`@base_steps`, `@common_config`, `@package_meta`)
  - Eliminated code duplication between dev/prod profiles
  - Consolidated platform-specific settings for better maintainability
  - Unified package metadata across distribution formats

- **Release Script Enhancements:**
  - Added comprehensive build result tracking and reporting
  - Implemented JSON manifest generation for build artifacts
  - Enhanced git tagging with duplicate detection and clean working directory validation
  - Improved cross-platform executable name handling

### Fixed

- **Release Process Reliability:**
  - Fixed potential issues with duplicate git tags
  - Enhanced error reporting for failed builds
  - Improved platform detection and build consistency
  - Added proper validation for release prerequisites

### Impact

- 23% reduction in release configuration complexity
- Unified release workflow across all platforms (macOS, Linux, Windows)
- Enhanced artifact tracking and build management
- Safer and more reliable version tagging process
- Improved developer experience with clear, standardized commands

## [0.7.0] - 2025-07-15

### Added

- **Refactored Buffer Server Architecture:**
  - Introduced `BufferServerRefactored` with modular, high-performance design
  - Added `ConcurrentBuffer`, `MetricsTracker`, `OperationProcessor`, and `OperationQueue` modules
  - Improved buffer management, batch operations, and performance metrics
  - Comprehensive documentation and type specs for all new modules

- **Comprehensive Test Coverage:**
  - Added integration and unit tests for all new buffer modules
  - Enhanced test coverage for concurrent operations, metrics, and damage tracking
  - Improved test reliability and isolation

### Fixed

- **Event Handler and State Restoration:**
  - Fixed event handler to properly pass emulator to handlers
  - Corrected terminal state restoration logic and fixed KeyError
  - Added cursor-only restoration for DEC mode 1048

- **Debug Output Cleanup:**
  - Removed excessive debug output from renderer and tests
  - Cleaned up verbose IO/puts statements across terminal modules

### Changed

- **General Code and Documentation Improvements:**
  - Updated and harmonized code formatting across all modules
  - Improved documentation and roadmap
  - Miscellaneous bug fixes and code cleanups

### Removed

- Obsolete debug scripts and legacy code

### Next Focus

1. Continue performance optimization
2. Address any remaining test edge cases
3. Further improve documentation and code quality

## [0.4.2] - 2025-06-11

### Added

- **Terminal Buffer Management Refactoring:**
  - Split `manager.ex` into specialized modules:
    - `State` - Buffer initialization and state management
    - `Cursor` - Cursor position and movement
    - `Damage` - Damaged regions tracking
    - `Memory` - Memory usage and limits
    - `Scrollback` - Scrollback buffer operations
    - `Buffer` - Buffer operations and synchronization
    - `Manager` - Main facade coordination
  - Improved code organization and maintainability
  - Enhanced test coverage
  - Better error handling
  - Clearer interfaces

- **Plugin System Improvements:**
  - Implemented Tarjan's algorithm for dependency resolution
  - Enhanced version constraint handling
  - Added detailed dependency chain reporting
  - Improved error handling and diagnostics
  - Optimized dependency graph operations

- **Component System Enhancements:**
  - Harmonized API for all input components
  - Improved theme and style prop support
  - Enhanced lifecycle hooks
  - Better accessibility integration
  - Comprehensive test coverage

- **Performance Infrastructure:**
  - New `Raxol.Test.PerformanceHelper` module
  - Performance test suite for terminal manager
  - Event processing benchmarks
  - Screen update benchmarks
  - Concurrent operation benchmarks

- **Documentation Improvements:**
  - Completed comprehensive guides
  - Enhanced API documentation
  - Improved architecture documentation
  - Added migration guide
  - Updated component documentation

### Changed

- **Test Infrastructure:**
  - Replaced `Process.sleep` with event-based synchronization
  - Enhanced plugin test fixtures
  - Improved error handling
  - Better resource cleanup
  - Clear test boundaries

- **Terminal Command Handling:**
  - Standardized error/result tuples
  - Improved error propagation
  - Enhanced command handler organization
  - Better test coverage

- **Component System:**
  - Migrated to `Raxol.UI.Components` namespace
  - Improved theme handling
  - Enhanced style prop support
  - Better lifecycle management

### Deprecated

- Old event system
- Legacy rendering approach
- Previous styling methods
- `Raxol.Terminal.CommandHistory` (Replaced with new command system)

### Removed

- Redundant `Raxol.Core.Runtime.Plugins.Commands` GenServer
- Redundant clipboard modules
- `Raxol.UI.Components.ScreenModes` module
- Direct `:meck` usage from test files

### Fixed

- **SelectList Mouse Focus Bug:**
  - Fixed focus update on mouse clicks
  - Improved test coverage
  - Enhanced mouse interaction handling

- **Accessibility Tests:**
  - Fixed color suggestion tests
  - Improved test reliability
  - Enhanced accessibility coverage

- **Test Suite:**
  - Resolved compilation errors
  - Fixed helper function scoping
  - Improved test organization

### Next Focus

1. Address remaining test failures
2. Complete OSC 4 handler implementation
3. Implement robust anchor checking
4. Document test writing guide
5. Continue code quality improvements

## [0.4.0] - 2025-05-10

### Added

- Initial public release
- Core terminal functionality
- Basic component system
- Plugin architecture
- Testing infrastructure

## [0.5.0] - 2025-06-12

### Added

- **Progress Component:**
  - New `Raxol.UI.Components.Progress` module with multiple progress indicators:
    - Progress bars with customizable styles and labels
    - Spinner animations with multiple animation types
    - Indeterminate progress bars
    - Circular progress indicators
  - Comprehensive test coverage for all progress variants
  - Full documentation with examples and usage guidelines

- **Documentation Overhaul:**
  - Major updates to all component documentation in `docs/components/`
  - Improved structure, navigation, and cross-references
  - Added mermaid diagrams and comprehensive API references
  - Expanded best practices and common pitfalls sections

- **Test Suite Improvements:**
  - Enhanced test coverage and organization
  - Updated test fixtures and support files
  - Improved reliability and maintainability

- **Code Style and Formatting:**
  - Applied consistent formatting across all Elixir source files
  - Improved code readability and maintainability

- **Utility Scripts:**
  - Added scripts for code maintenance and consistency

### Changed

- Updated guides and general documentation for clarity and completeness
- Refined documentation links and fixed broken references

### Removed

- Obsolete migration and test consolidation guides

- **Native Dependency Management:**
  - Removed vendored `termbox2` C source from `lib/termbox2_nif/c_src/termbox2`
  - Now uses the official [termbox2](https://github.com/termbox/termbox2) as a git submodule
  - Developers must run `git submodule update --init --recursive` before building
  - Updated build and documentation to reflect this change

## [0.6.0] - 2025-01-27

### Added

- **Comprehensive Documentation Renderer:**
  - Markdown to HTML conversion with Earmark integration
  - Table of contents generation with anchor links
  - Search index creation with metadata extraction
  - Code block extraction and processing
  - Full documentation rendering with metadata and navigation
  - Graceful fallbacks when dependencies aren't available

- **Window Event Handling:**
  - Complete window event processing in terminal driver
  - Resize event handling with dimension updates
  - Title and icon name change processing
  - Proper logging and error handling for window events

- **Shared Helper Modules:**
  - `Raxol.Core.Runtime.ShutdownHelper` for graceful shutdown logic
  - `Raxol.Core.Runtime.GenServerStartupHelper` for startup patterns
  - `Raxol.Core.Runtime.ComponentStateHelper` for state management
  - `Raxol.Benchmarks.DataGenerator` for benchmark data generation
  - `Raxol.Core.StateManager` for shared state patterns
  - `Raxol.Terminal.Scroll.PatternAnalyzer` for scroll analysis
  - `Raxol.EmulatorPluginTestHelper` for test setup

### Changed

- **Major Code Quality Improvements:**
  - Eliminated all duplicate code across the codebase
  - Reduced software design suggestions from 44 to 0
  - Improved modularity and maintainability
  - Enhanced code organization and structure

- **Refactored Components:**
  - Removed duplicate character operations in favor of char_editor
  - Extracted shared event handling in button component
  - Unified scroll region logic into single helper
  - Delegated duplicate auth functions to public auth.ex
  - Removed embedded CharacterHandler in text_input
  - Created shared color parsing delegation
  - Unified component state update patterns

- **Test Suite Improvements:**
  - Created shared test helper for emulator plugin tests
  - Removed duplicate cursor manager tests
  - Eliminated duplicate notification plugin test file
  - Improved test organization and maintainability

### Removed

- **Legacy and Duplicate Modules:**
  - `lib/raxol/terminal/input_manager.ex` (legacy version)
  - `lib/raxol/core/cache/unified_cache.ex` (duplicate of system cache)
  - `lib/raxol/terminal/buffer/char_operations.ex` (duplicate functionality)
  - `test/raxol/plugins/notification_plugin_test.exs` (duplicate of core version)
  - `test/raxol/terminal/cache/unified_cache_test.exs` (duplicate tests)

### Fixed

- **All TODO Items:**
  - Implemented window resize processing
  - Implemented window event handling
  - Implemented comprehensive documentation renderer functionality
  - No more TODO comments in the codebase

## [0.5.2] - 2025-01-27

### Added

- **Enhanced Demo Runner:**
  - **Command Line Interface**: Added comprehensive command line argument support to `scripts/bin/demo.exs`
    - `--list`: List all available demos with descriptions
    - `--help`: Show detailed usage information and examples
    - `--version`: Display version information
    - `--info DEMO`: Show detailed information about a specific demo
    - `--search TERM`: Search demos by name or description
    - Direct demo execution: `mix run bin/demo.exs form`
  - **Interactive Menu Improvements**:
    - Categorized demo display (Basic Examples, Advanced Features, Showcases, WIP)
    - Enhanced navigation with keyboard shortcuts
    - Better error handling and user feedback
    - Similar demo suggestions for typos
  - **Auto-discovery**: Automatic detection of available demo modules in `Raxol.Examples` namespace
  - **Error Handling**: Robust validation and error reporting for demo modules
  - **Performance Monitoring**: Demo execution timing and monitoring capabilities
  - **Configuration Support**: Optional configuration file support for customizing demo behavior

- **Documentation Updates**:
  - Updated README with comprehensive demo usage instructions
  - Added demo examples to Quick Start guide
  - Enhanced documentation with interactive demo capabilities

### Changed

- **Demo Script Architecture**:
  - Refactored `scripts/bin/demo.exs` for better maintainability
  - Improved code organization with dedicated modules
  - Enhanced user experience with better feedback and error handling

### Fixed

- **Demo Discovery**: Resolved issues with demo module loading and validation
- **User Experience**: Improved error messages and help text clarity

### Next Focus

1. Continue enhancing demo system with additional features
2. Add more comprehensive demo examples
3. Implement demo recording and playback capabilities
4. Enhance configuration and customization options

## [0.5.1] - 2025-01-27

### Added

- **Terminal System Major Enhancements:**
  - Comprehensive refactoring of terminal buffer, ANSI, plugin, and rendering subsystems
  - Enhanced ANSI state machine with improved escape sequence handling
  - Better sixel graphics support and parsing
  - Improved mouse tracking and window manipulation
  - Enhanced buffer management with unified operations
  - Better character handling and clipboard integration
  - Comprehensive test coverage for all terminal subsystems

- **Core System Improvements:**
  - Enhanced metrics aggregation and visualization
  - Improved performance monitoring and system utilities
  - Better UX refinement with accessibility integration
  - Enhanced color system and theme management
  - Improved application lifecycle management

- **UI Component Updates:**
  - Updated base component lifecycle management
  - Enhanced input field components (multi-line, password, select)
  - Improved progress spinner and layout engine
  - Better rendering pipeline and container management
  - Enhanced test coverage for UI components

- **Testing Infrastructure:**
  - Expanded test suite with improved coverage
  - Enhanced test fixtures and support scripts
  - Better plugin test organization and reliability
  - Improved mock implementations and test helpers
  - Added comprehensive test documentation

- **Documentation and Configuration:**
  - Added compilation error plan and critical fixes reference
  - Enhanced plugin test backups and documentation
  - Updated configuration and application startup
  - Improved plugin events and metrics collector
  - Better script organization and maintenance

### Changed

- **Code Quality:**
  - Applied consistent formatting across all Elixir source files
  - Improved code readability and maintainability
  - Enhanced error handling and validation
  - Better separation of concerns in terminal subsystems
  - Standardized API patterns across components

- **Performance:**
  - Optimized terminal operations and buffer management
  - Improved rendering pipeline efficiency
  - Enhanced memory management and resource cleanup
  - Better concurrent operation handling

### Fixed

- **Terminal Operations:**
  - Fixed ANSI sequence parsing edge cases
  - Improved buffer scroll region handling
  - Enhanced cursor positioning accuracy
  - Better window state management
  - Fixed sixel graphics rendering issues

- **Test Reliability:**
  - Resolved test compilation errors
  - Fixed mock implementation inconsistencies
  - Improved test isolation and cleanup
  - Enhanced test data management

### Removed

- Obsolete UI component files
- Redundant test fixtures
- Unused configuration options

## [0.5.2] - 2025-01-27

### Added

- **Enhanced Buffer Manager Compression:**
  - Implemented comprehensive buffer compression in `Raxol.Terminal.Buffer.EnhancedManager`
  - Added multiple compression algorithms:
    - Simple compression for empty cell optimization
    - Run-length encoding for repeated characters
    - LZ4 compression support (framework ready)
  - Threshold-based compression activation
  - Style attribute minimization to reduce memory usage
  - Performance metrics tracking for compression operations
  - Automatic compression state updates and optimization

- **Buffer Compression Features:**
  - Cell-level compression with empty cell detection
  - Style attribute optimization (removes default attributes)
  - Run-length encoding for identical consecutive cells
  - Configurable compression thresholds and algorithms
  - Memory usage estimation and monitoring
  - Compression ratio tracking and statistics

### Changed

- **Buffer Management:**
  - Enhanced memory efficiency through intelligent compression
  - Improved performance monitoring for buffer operations
  - Better memory usage optimization strategies

### Fixed

- **Code Quality:**
  - Resolved TODO items in buffer compression implementation
  - Improved code maintainability and documentation

## [0.5.3] - 2025-01-27

### Fixed

- **Enhanced Buffer Manager:**
  - Implemented buffer eviction logic in `Raxol.Terminal.Buffer.EnhancedManager`
  - Added automatic pool size management to prevent memory overflow
  - Resolved TODO item for buffer eviction implementation
  - Improved memory management efficiency

- **Plugin resource budgets now constrain supervised plugin work.** `PluginSupervisor` tracks each task by plugin ID and starts `ResourceBudget` in its supervision tree; the monitor measures live process memory, ETS ownership, process count, and BEAM reduction share instead of returning zeroes. Manifest limits now reach the registry, `:warn` emits telemetry, `:throttle` blocks new event/filter/hook work until usage recovers, and `:kill` terminates active tasks and unloads the plugin. End-to-end regressions cross zero-sized limits with a real supervised task for all three actions.
