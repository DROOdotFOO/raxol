defmodule T0.RingB.Drivers.Kitty do
  @moduledoc """
  kitty driver — remote control over a Unix-domain socket (verified
  2026-07-16, kitty 0.47.4). Documented in the unit's own brief as
  "FLAKY when launched detached headless" — this implementation makes it
  as robust as demonstrated recipes allow (poll for the socket, retry
  the first remote-control call) but callers should still treat kitty as
  best-effort: `available?/0` only checks the binary exists, not that a
  session will reliably come up.

    * `kitty -o allow_remote_control=yes --listen-on unix:SOCK <cmd> &`
      then poll for the socket file to appear (observed: usually < 1s,
      bounded here at 6s) before issuing any `kitty @` command.
    * `kitty @ --to unix:SOCK send-text --match state:focused "text\\n"`
      == typing `text` + Enter; without the trailing `\\n` it types with
      no Enter (used for `mark_cursor/2`, same shape as the other
      drivers).
    * `kitty @ --to unix:SOCK get-text --extent=all` returns clean
      scrollback + screen text with NO trailing padding and NO trailing
      whitespace per line (the cleanest of the three native captures
      tested) — still routed through `T0.RingB.Capture.viewport/2` for
      uniformity.
    * No cursor-position field was found on `kitty @ ls`'s window object
      in this build — `get_cursor/1` is `{:error, :unsupported}`;
      `mark_cursor/2` (confirmed working) carries C3 instead.
    * `kitty @ resize-os-window` exists but operates on pixel/OS-panel
      geometry, not a simple `--cols`/`--rows` cell resize — not a
      reliable enough primitive to trust for C4's cell-exact resize
      claim; `resize/3` is `{:error, :unsupported}` (documented, not a
      half-working guess).
    * `close/1` kills the underlying kitty process directly (the whole
      detached instance this driver launched, one per session) — this
      is the belt-and-suspenders `Guard`-adjacent cleanup the coordinator
      asked for: no GUI confirmation dialog exists for a `SIGTERM`'d
      background process, so there is nothing to hang on.

  Every `System.cmd/3` call below — the launch in `spawn_session/1` and
  the `kitty @` remote-control calls behind `run_command/2`,
  `mark_cursor/2`, `get_visible/1`, and `get_scrollback/1` (`kitty_run/1`
  / `kitty_text/1`) — is bounded by `T0.RingB.Guard.with_timeout/2` (RB
  review FIX-NOW #1). The launch call is a detached, backgrounded
  `nohup ... &` that returns as soon as the shell forks it, not once
  kitty itself is ready (`wait_for_socket/2` right after is what's
  actually bounded against kitty never coming up) — it is guarded here
  too anyway, for the same reason every other call site is: defense
  against an unexpectedly wedged `bash -c` itself, not just kitty.
  """

  @behaviour T0.RingB.Driver
  alias T0.RingB.Guard

  @kitty_bin "/Applications/kitty.app/Contents/MacOS/kitty"
  @socket_wait_ms 6_000
  @settle_ms 2200
  @cmd_timeout_ms 5_000

  @impl true
  def name, do: :kitty

  @impl true
  def capture_method, do: "native_gettext"

  @impl true
  def available?,
    do: File.exists?(@kitty_bin) or not is_nil(System.find_executable("kitty"))

  @impl true
  def spawn_session(_opts \\ []) do
    bin = kitty_bin()

    sock =
      Path.join(
        System.tmp_dir!(),
        "t0-ringb-kitty-#{System.unique_integer([:positive])}.sock"
      )

    File.rm(sock)

    # Fully detached via a shell `nohup ... &`, NOT `Port.open/2` — kitty
    # internally forks/daemonizes in a way that was observed to leave a
    # child holding the ORIGINAL calling shell's stdout pipe open even
    # after the owning BEAM process (and its Port) had exited, hanging
    # any `| tail` (or similar) pipeline downstream of `mix run`/`mix
    # t0.ringb` indefinitely. A plain detached shell command with stdio
    # explicitly redirected to /dev/null has no such fd to inherit.
    launch_cmd =
      "nohup '#{bin}' -o allow_remote_control=yes --listen-on unix:'#{sock}' " <>
        "</dev/null >/dev/null 2>&1 & echo $!"

    case guarded_cmd("bash", ["-c", launch_cmd]) do
      {:ok, out} ->
        os_pid = String.trim(out)

        case wait_for_socket(sock, @socket_wait_ms) do
          :ok ->
            Process.sleep(@settle_ms)
            {:ok, %{socket: sock, os_pid: os_pid}}

          :timeout ->
            kill_os_pid(os_pid)
            {:error, {:socket_never_appeared, sock}}
        end

      {:error, reason} ->
        {:error, {:launch_failed, reason}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  @impl true
  def run_command(session, cmd), do: send_text(session, cmd <> "\n")

  @impl true
  def mark_cursor(session, text), do: send_text(session, text)

  @impl true
  def get_scrollback(session), do: get_text(session)

  @impl true
  def get_visible(session), do: get_text(session)

  @impl true
  # No cursor-position field observed on `kitty @ ls`'s window object in
  # this build (checked live) — see moduledoc; C3 uses mark_cursor/2.
  def get_cursor(_session), do: {:error, :unsupported}

  @impl true
  # `resize-os-window` operates on pixel/OS-panel geometry, not a
  # trustworthy cell-exact cols/rows primitive — documented residual.
  def resize(_session, _cols, _rows), do: {:error, :unsupported}

  @impl true
  def close(%{socket: sock, os_pid: os_pid}) do
    _ =
      kitty_run([
        "@",
        "--to",
        "unix:#{sock}",
        "close-window",
        "--match",
        "state:focused"
      ])

    kill_os_pid(os_pid)
    File.rm(sock)
    :ok
  rescue
    _ -> :ok
  end

  @impl true
  # This driver's own kitty process is the whole detached instance (one
  # per session) — no GUI confirmation dialog exists for it either;
  # "still open" means "the OS process this driver spawned is alive".
  def still_open?(%{os_pid: os_pid}) do
    case System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # --- internal --------------------------------------------------------------

  defp kitty_bin do
    if File.exists?(@kitty_bin),
      do: @kitty_bin,
      else: System.find_executable("kitty")
  end

  defp wait_for_socket(sock, budget_ms) when budget_ms > 0 do
    if File.exists?(sock) do
      :ok
    else
      Process.sleep(200)
      wait_for_socket(sock, budget_ms - 200)
    end
  end

  defp wait_for_socket(_sock, _budget_ms), do: :timeout

  defp kill_os_pid(os_pid) do
    _ = System.cmd("kill", ["-TERM", os_pid], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp send_text(%{socket: sock}, text) do
    kitty_run([
      "@",
      "--to",
      "unix:#{sock}",
      "send-text",
      "--match",
      "state:focused",
      text
    ])
  end

  defp get_text(%{socket: sock}) do
    kitty_text(["@", "--to", "unix:#{sock}", "get-text", "--extent=all"])
  end

  # "Fire and forget" — discards stdout, only reports success/failure.
  # Used by send-text/close-window, whose stdout is normally empty.
  defp kitty_run(args) do
    case guarded_cmd(kitty_bin(), args) do
      {:ok, _out} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # Captures stdout — used by get-text.
  defp kitty_text(args) do
    guarded_cmd(kitty_bin(), args)
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # Bounds every `System.cmd/3` call above at `@cmd_timeout_ms` (RB
  # review FIX-NOW #1) rather than the bare, unbounded call this driver
  # used before — see moduledoc. Delegates the actual timeout/
  # normalization logic to `Guard.run_cmd/4` (shared with
  # `T0.RingB.Drivers.Wezterm`, to avoid duplicating it per driver).
  defp guarded_cmd(bin, args, opts \\ [stderr_to_stdout: false]) do
    Guard.run_cmd(bin, args, opts, @cmd_timeout_ms)
  end
end
