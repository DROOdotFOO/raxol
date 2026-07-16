defmodule T0.RingB.Drivers.Wezterm do
  @moduledoc """
  WezTerm driver — `wezterm cli` (verified 2026-07-16, wezterm
  20240203-110809-5046fc22):

    * `wezterm cli spawn --new-window -- bash -l` prints the new pane id
      on stdout; `--new-window` avoids colliding with any pre-existing
      wezterm window/pane the user already has open.
    * `wezterm cli send-text --pane-id N --no-paste "text\\n"` == typing
      `text` + Enter; the SAME command with no trailing `\\n` types `text`
      with no Enter — used for `mark_cursor/2` (cursor-column inference),
      exactly like iTerm2's `write text ... newline no`.
    * `wezterm cli get-text --pane-id N --start-line -N` returns
      scrollback + screen with no large trailing blank-padding tail
      (unlike iTerm2's `contents`) — still run through
      `T0.RingB.Capture.viewport/2` for uniformity, but empirically
      cleaner.
    * `wezterm cli list --format json` includes `cursor_x`/`cursor_y`
      per pane (0-based, `cursor_y` relative to `top_row`) — a REAL
      cursor-position API, so `get_cursor/1` does not need marker
      injection on this driver (kept anyway via `mark_cursor/2` as a
      cross-check / for parity with the other drivers' C3 path).
    * `wezterm cli` has **no resize subcommand** (checked its own
      `--help` output) — `resize/3` is `{:error, :unsupported}` here;
      C4 is not attempted on this driver (documented residual, not a
      guess).
    * `wezterm cli kill-pane --pane-id N` cleanly ends the pane with no
      GUI confirmation dialog (unlike closing an Terminal.app/iTerm2
      window with a live foreground job) — `close/1` uses this
      directly rather than closing the whole OS window.

  Every `wezterm cli` invocation below (`spawn_session/1`,
  `send_text/2` behind `run_command/2`/`mark_cursor/2`, `get_text/2`
  behind `get_visible/1`/`get_scrollback/1`, `get_cursor/1`) is bounded
  by `T0.RingB.Guard.with_timeout/2` (RB review FIX-NOW #1) — a hung
  `wezterm cli` round trip (daemon wedged, IPC socket stuck) can no
  longer hang the whole matrix run indefinitely; `close/1` and
  `still_open?/1` were already guarded one layer up, in
  `T0.RingB.Guard.safe_teardown/3`.
  """

  @behaviour T0.RingB.Driver
  alias T0.RingB.Guard

  @settle_ms 2200
  @cmd_timeout_ms 5_000

  @impl true
  def name, do: :wezterm

  @impl true
  def capture_method, do: "native_gettext"

  @impl true
  def available?, do: not is_nil(System.find_executable("wezterm"))

  @impl true
  def spawn_session(_opts \\ []) do
    case guarded_cmd(
           "wezterm",
           ["cli", "spawn", "--new-window", "--", "bash", "-l"]
         ) do
      {:ok, out} ->
        pane_id = out |> String.trim() |> String.split("\n") |> List.last()
        Process.sleep(@settle_ms)
        {:ok, %{pane_id: pane_id}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  @impl true
  def run_command(%{pane_id: pid}, cmd), do: send_text(pid, cmd <> "\n")

  @impl true
  def mark_cursor(%{pane_id: pid}, text), do: send_text(pid, text)

  @impl true
  def get_scrollback(session), do: get_text(session, "-2000")

  @impl true
  def get_visible(session), do: get_text(session, "-2000")

  @impl true
  def get_cursor(%{pane_id: pid}) do
    case guarded_cmd("wezterm", ["cli", "list", "--format", "json"]) do
      {:ok, out} ->
        case Jason.decode(out) do
          {:ok, panes} ->
            case Enum.find(panes, &(to_string(&1["pane_id"]) == pid)) do
              %{"cursor_y" => y, "cursor_x" => x} -> {:ok, {y + 1, x + 1}}
              _ -> {:error, :unsupported}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  @impl true
  # `wezterm cli` has no resize subcommand (confirmed via --help) — the
  # window/pane size is fixed once spawned from this API.
  def resize(_session, _cols, _rows), do: {:error, :unsupported}

  @impl true
  def close(%{pane_id: pid}) do
    _ =
      System.cmd("wezterm", ["cli", "kill-pane", "--pane-id", pid],
        stderr_to_stdout: true
      )

    :ok
  rescue
    _ -> :ok
  end

  @impl true
  # `kill-pane` is a direct CLI call with no GUI confirmation dialog of
  # any kind — this is a plain existence check, not a modal-detection
  # safety net (unlike the AppleScript-driven drivers).
  def still_open?(%{pane_id: pid}) do
    case System.cmd("wezterm", ["cli", "list", "--format", "json"],
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, panes} -> Enum.any?(panes, &(to_string(&1["pane_id"]) == pid))
          {:error, _} -> false
        end

      _ ->
        false
    end
  rescue
    _ -> false
  end

  # --- internal --------------------------------------------------------------

  defp send_text(pane_id, text) do
    case guarded_cmd(
           "wezterm",
           ["cli", "send-text", "--pane-id", pane_id, "--no-paste", text]
         ) do
      {:ok, _out} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp get_text(%{pane_id: pid}, start_line) do
    guarded_cmd(
      "wezterm",
      ["cli", "get-text", "--pane-id", pid, "--start-line", start_line]
    )
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  # Bounds every `wezterm cli` call above at `@cmd_timeout_ms` (RB
  # review FIX-NOW #1) rather than the bare, unbounded `System.cmd/3`
  # this driver used before — see moduledoc. Delegates the actual
  # timeout/normalization logic to `Guard.run_cmd/4` (shared with
  # `T0.RingB.Drivers.Kitty`, to avoid duplicating it per driver).
  defp guarded_cmd(bin, args, opts \\ [stderr_to_stdout: false]) do
    Guard.run_cmd(bin, args, opts, @cmd_timeout_ms)
  end
end
