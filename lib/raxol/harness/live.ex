defmodule Raxol.Harness.Live do
  @moduledoc """
  The U6 assembly: a live TEA harness session, wired end to end
  (`docs/proposals/in-flight/harness-tea-migration.md` §8 "U6 live
  wiring"). One call boots the whole stack against a real
  `Raxol.Harness.SessionLane`:

  ```
  Raxol.Harness.Live
    └─ SessionPump (:runtime_boot)          -- sole tty/stdin owner
         ├─ writes alt-screen enter FIRST   -- PumpContract §7 byte law
         └─ boots Lifecycle(environment: :harness) running HarnessApp
              ├─ Dispatcher ◀── DeliveryShim ◀── pump messages (U6-a)
              └─ Rendering Engine ◀── paint gate (U6-b), frames to tty
  ```

  `HarnessApp.update/2` folds the frozen `Raxol.Harness.PumpContract`
  vocabulary and returns `Raxol.Harness.Directive.{Lane,Editor}` structs
  addressed to the pump; the pump performs the lane mechanics and answers
  with the contract's result messages. Time-travel is one option away
  (`time_travel: true`) because `update/2` is a pure fold.

  This module is deliberately thin: it owns the three things that belong
  to the EMBEDDER, not to either side of the contract --

    * terminal geometry probing (`:io.columns/0` / `:io.rows/0`), which
      seeds both the pump and the Lifecycle;
    * the SIGWINCH watcher, translating window resizes into
      `SessionPump.notify_resize/3` (no termbox Driver runs in the
      `:harness` profile, so nothing else would);
    * the caller-facing handle (`%{pump, lifecycle}`) and `stop/1`.

  The pump owns everything else: stdin (its InlineDriver), the alt-screen
  bracket, the editor bracket, teardown. Session death is NOT teardown
  (PumpContract §8); `stop/1` is the only external teardown trigger.

  ## Options

    * `:lane` (required) — `{lane_module, session}` per
      `Raxol.Harness.SessionLane`.
    * `:width` / `:rows` — override the probed geometry.
    * `:greeting?` — render the boot greeting in the transcript
      (default `true`).
    * `:fold_defaults` — per-kind fold overrides for the projection.
    * `:sessions_dir` — journal root, passed to the app.
    * `:time_travel` — record every `update/2` cycle (default `false`).
    * `:io_writer` — the Engine's frame sink for tests/embedding
      (default: the tty backend).
    * `:sigwinch?` — install the SIGWINCH watcher (default `true`).
    * every `Raxol.Harness.SessionPump` pass-through: `:device`,
      `:inline_driver_opts`, `:editor_session`, `:editor_opts`,
      `:cadence_opts`, `:stall_opts`, `:steer_timeout_ms`, `:clock`,
      `:tick_ms`, `:notify`.
  """

  alias Raxol.Core.Runtime.Lifecycle
  alias Raxol.Harness.HarnessApp
  alias Raxol.Harness.SessionPump

  @typedoc "The caller-facing handle to a running live session."
  @type t :: %{pump: pid(), lifecycle: pid()}

  @passthrough [
    :device,
    :inline_driver,
    :inline_driver_opts,
    :editor_session,
    :editor_opts,
    :cadence_opts,
    :stall_opts,
    :steer_timeout_ms,
    :clock,
    :tick_ms,
    :notify
  ]

  @doc """
  Boots the stack, linked to the caller. Returns `{:ok, %{pump, lifecycle}}`
  once the Lifecycle is up and the pump has rewired its seams to it -- the
  synchronous reply is how the caller KNOWS the first frame can only land
  in the alternate screen.
  """
  @spec start_link(keyword()) :: {:ok, t()}
  def start_link(opts) do
    # The syntax registries live in Makeup's OTP app env — a bare embedder
    # boot (mix raxol.harness starts only logger/telemetry) leaves them
    # empty, so every diff span degrades to the plain fallback: no syntax
    # fg, and since `span_fg/4` fades only real hex token colors, no
    # insignificant-line fade either. One idempotent start fixes both.
    _ = Application.ensure_all_started(:makeup_elixir)

    {width, rows} = geometry(opts)
    caller = self()

    # The runtime_boot callback runs INSIDE the pump (SessionPump's U6
    # seam): by the time it is invoked, the alt-screen enter bytes are
    # already written, so the Engine started here can never paint into
    # the user's scrollback. It reports the lifecycle pid back because
    # the caller's handle needs it and only this callback knows it.
    boot = fn pump_pid ->
      lifecycle_opts =
        [
          environment: :harness,
          width: width,
          height: rows,
          pump: pump_pid,
          stream_open: true,
          greeting?: Keyword.get(opts, :greeting?, true),
          fold_defaults: Keyword.get(opts, :fold_defaults, %{}),
          sessions_dir: Keyword.get(opts, :sessions_dir),
          time_travel: Keyword.get(opts, :time_travel, false),
          # The Engine's frame sink (the :harness profile's device seam;
          # Initializer.maybe_add_opt drops a nil, so production keeps the
          # default tty backend). Tests and embedders inject it here.
          io_writer: Keyword.get(opts, :io_writer)
        ]

      case Raxol.start_link(HarnessApp, lifecycle_opts) do
        {:ok, lifecycle} ->
          pids = Lifecycle.child_pids(lifecycle)
          send(caller, {:harness_live_started, lifecycle})

          {:ok,
           %{
             dispatcher: pids.dispatcher,
             engine: pids.engine,
             lifecycle: lifecycle
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end

    pump_opts =
      opts
      |> Keyword.take(@passthrough)
      |> Keyword.put(:lane, Keyword.fetch!(opts, :lane))
      |> Keyword.put(:runtime_boot, boot)
      |> Keyword.put(:width, width)
      |> Keyword.put(:rows, rows)

    {:ok, pump} = SessionPump.start_link(pump_opts)

    lifecycle =
      receive do
        {:harness_live_started, lifecycle} -> lifecycle
      after
        # A boot that takes longer than this failed inside the pump (the
        # linked crash reaches us); the timeout exists so a wedged
        # Lifecycle start can never leave the caller blocked forever on
        # a half-entered alt screen -- the pump link still owns teardown.
        10_000 ->
          exit({:harness_live_boot_timeout, pump})
      end

    if Keyword.get(opts, :sigwinch?, true), do: start_sigwinch_watcher(pump)

    {:ok, %{pump: pump, lifecycle: lifecycle}}
  end

  @doc """
  Ends the session: asks the pump to run the frozen teardown sequence
  (PumpContract §8 -- paint gate, InlineDriver teardown, alt-screen leave
  as the LAST byte, Lifecycle stop). Returns immediately; the pump's
  `:notify` target observes `{:session_pump, pid, :halted}`.
  """
  @spec stop(t() | pid()) :: :ok
  def stop(%{pump: pump}), do: SessionPump.halt(pump)
  def stop(pump) when is_pid(pump), do: SessionPump.halt(pump)

  # -- geometry -------------------------------------------------------------

  # The probe is the embedder's job (the old live demo's `geometry/0`):
  # :io answers over any tty or pty, and the 80x24 fallback keeps
  # embedded/headless runs (no tty at all) bootable with an honest size.
  defp geometry(opts) do
    {probed_w, probed_r} = probe_geometry()

    {
      Keyword.get(opts, :width, probed_w),
      Keyword.get(opts, :rows, probed_r)
    }
  end

  defp probe_geometry do
    width =
      case :io.columns() do
        {:ok, cols} -> cols
        _ -> 80
      end

    rows =
      case :io.rows() do
        {:ok, rows} -> rows
        _ -> 24
      end

    {width, rows}
  end

  # -- SIGWINCH ---------------------------------------------------------------

  # No termbox Driver runs in the :harness profile, so nothing else would
  # translate a window resize into the pump's `%Event{type: :resize}`.
  # The handler itself is the terminal package's gen_event (prim_tty sends
  # SIGWINCH to :erl_signal_server, not to us); the watcher loop is a bare
  # process because it never replies and holds no state. A resize folds
  # through the Dispatcher resize path, so the Engine's size sync rides
  # it (PumpContract §3's one exception).
  defp start_sigwinch_watcher(pump) do
    watcher = spawn_link(fn -> sigwinch_loop(pump) end)

    handler_id = {Raxol.Terminal.Driver.SigwinchHandler, watcher}

    case :gen_event.add_handler(
           :erl_signal_server,
           handler_id,
           %{driver: watcher}
         ) do
      :ok ->
        :ok

      # OTP < 26 has no :sigwinch signal name, or the handler is already
      # installed by a sibling session: resize still works through the
      # editor bracket's re-probe, so degrade quietly rather than failing
      # the boot.
      {:error, _reason} ->
        :ok
    end
  end

  defp sigwinch_loop(pump) do
    receive do
      :sigwinch ->
        {width, rows} = probe_geometry()
        SessionPump.notify_resize(pump, width, rows)
        sigwinch_loop(pump)
    end
  end
end
