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
  """

  @behaviour T0.RingB.Driver

  @settle_ms 2200

  @impl true
  def name, do: :wezterm

  @impl true
  def capture_method, do: "native_gettext"

  @impl true
  def available?, do: not is_nil(System.find_executable("wezterm"))

  @impl true
  def spawn_session(_opts \\ []) do
    case System.cmd(
           "wezterm",
           ["cli", "spawn", "--new-window", "--", "bash", "-l"],
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        pane_id = out |> String.trim() |> String.split("\n") |> List.last()
        Process.sleep(@settle_ms)
        {:ok, %{pane_id: pane_id}}

      {out, code} ->
        {:error, {:exit, code, String.trim(out)}}
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
    case System.cmd("wezterm", ["cli", "list", "--format", "json"],
           stderr_to_stdout: false
         ) do
      {out, 0} ->
        case Jason.decode(out) do
          {:ok, panes} ->
            case Enum.find(panes, &(to_string(&1["pane_id"]) == pid)) do
              %{"cursor_y" => y, "cursor_x" => x} -> {:ok, {y + 1, x + 1}}
              _ -> {:error, :unsupported}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {out, code} ->
        {:error, {:exit, code, String.trim(out)}}
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
    case System.cmd(
           "wezterm",
           ["cli", "send-text", "--pane-id", pane_id, "--no-paste", text],
           stderr_to_stdout: false
         ) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end

  defp get_text(%{pane_id: pid}, start_line) do
    case System.cmd(
           "wezterm",
           ["cli", "get-text", "--pane-id", pid, "--start-line", start_line],
           stderr_to_stdout: false
         ) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:exit, code, String.trim(out)}}
    end
  rescue
    e -> {:error, {:raised, Exception.message(e)}}
  end
end
