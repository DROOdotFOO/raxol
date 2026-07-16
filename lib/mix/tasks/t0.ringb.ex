defmodule Mix.Tasks.T0.Ringb do
  @shortdoc "Ring B: automated real-terminal device-control driver (T0 harness-UI)"

  @moduledoc """
  Drives real macOS GUI terminals (iTerm2, Terminal.app, WezTerm, kitty)
  through AppleScript/CLI device control, judges the T0 keystone claims
  (C1/C2/C3/C4/N06/N07) programmatically against each capture, writes the
  results into `scripts/harness/t0/t0-verdict.json` via
  `append_result.sh`, and prints the D-PA resolver's output.

  This retires the manual "Ring B" half of
  `docs/proposals/in-flight/t0-runbook.md` for every terminal with a
  scriptable capture API. Ghostty has neither a `get-text` CLI nor a
  `get text`/`contents`/`history` AppleScript command (confirmed via
  `sdef`) — it is recorded as a documented skip (screenshot residual),
  never guessed at.

      mix t0.ringb

  Opens and closes several real GUI windows over the course of the run
  (one per driver × claim) — this is expected. Every window this task
  opens is torn down through `T0.RingB.Guard.safe_teardown/3`, which
  kills the probe's own process before closing (avoiding the "terminate
  running processes?" confirmation dialog a live foreground job would
  otherwise trigger) and falls back to a bounded, non-blocking recovery
  path if a close still hangs. Every driver call this task makes
  (spawn, run-command, capture, resize, close) is itself bounded by
  `T0.RingB.Guard.with_timeout/2` (RB review FIX-NOW #1) — the
  enforced guarantee is that THIS RUN stays bounded, not that every OS
  process it ever touches is guaranteed reaped: force-killing a guarded
  task cannot reap an already-orphaned `osascript` subprocess (see
  `T0.RingB.Osa`'s moduledoc), and this task does not claim otherwise.

  Two things a human running this WATCHED (never unattended) needs to
  know honestly, not just implicitly:

    * The very first run on a machine that has never granted this
      harness Automation permission (Terminal/iTerm2/System Events) will
      pop a one-time macOS TCC authorization prompt outside this task's
      control — it must be clicked by a human before the run can
      proceed; every run after that grant is unattended.
    * The last-resort modal dismissal inside `T0.RingB.Guard` (reached
      only after kill-marker + close + a `still_open?/1` verification
      have ALL already failed) is APP-scoped, not sheet-scoped — it
      activates the whole application and sends a bare keystroke, which
      per the observed dialog is bound to "Terminate". A sheet-scoped
      version (targeting the exact confirmation dialog rather than
      whatever the app has frontmost) is DEFERRED to the next watched
      live matrix run, where it can be validated against a real modal
      before replacing this fallback; see `T0.RingB.Guard.
      dismiss_modal_best_effort/1`'s moduledoc for the full rationale.

  Requires a real macOS GUI session (Aqua) — not runnable headless/CI;
  see the `test/harness/ringb_*.exs` suite (`@moduletag :ring_b`,
  excluded from every default `mix test` invocation) for the same
  coverage as ExUnit assertions.
  """

  use Mix.Task

  # T0.RingB.Runner (and T0.RingB.Boot, which loads it) are loaded at
  # runtime via Code.require_file/2 (they live under
  # scripts/harness/t0/ringb/, not lib/ — not part of the compiled app)
  # — the compiler can't see them at compile time, so suppress the
  # undefined-function warning (same pattern this repo already uses for
  # cross-package references, see CLAUDE.md).
  @compile {:no_warn_undefined, [T0.RingB.Runner, T0.RingB.Boot]}

  @t0_root Path.expand("../../../scripts/harness/t0", __DIR__)

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Code.require_file("ringb/boot.ex", @t0_root)
    T0.RingB.Boot.require_all!(@t0_root)

    unless match?({:unix, :darwin}, :os.type()) do
      Mix.raise(
        "mix t0.ringb requires macOS (real GUI terminal device control)"
      )
    end

    Mix.shell().info(
      "== T0 Ring B: automated real-terminal device-control driver =="
    )

    %{results: results, resolver: resolver} = T0.RingB.Runner.run(@t0_root)

    print_results(results)
    print_resolver(resolver)
  end

  defp print_results(results) do
    Mix.shell().info("\n-- per-terminal-per-claim results --")

    Enum.each(results, fn
      %{skip: true} = row ->
        driver = Map.get(row, :driver, "?")
        claim = Map.get(row, :claim, "")
        Mix.shell().info("  #{driver} #{claim}: SKIP -- #{row.reason}")

      row ->
        Mix.shell().info(
          "  #{row.driver} #{row.claim}: #{row.verdict} (observable=#{inspect(row.observable)})"
        )
    end)
  end

  defp print_resolver(resolver) do
    Mix.shell().info("\n-- D-PA resolver output --")
    Mix.shell().info(Jason.encode!(resolver, pretty: true))
  end
end
