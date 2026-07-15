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
  path if a close still hangs — this task will not leave a modal dialog
  waiting on a human click.

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
