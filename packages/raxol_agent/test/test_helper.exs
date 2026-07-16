# Journals (Raxol.Agent.Journal.FileStore, opened per live Agent.Session via the
# EmitBridge sink) default to ~/.raxol/sessions. Redirect them to a throwaway
# tmp dir for the whole test run so tests never write into the real home dir.
unless System.get_env("RAXOL_SESSIONS_DIR") do
  sessions_dir =
    Path.join(
      System.tmp_dir!(),
      "raxol_agent_test_sessions_#{System.unique_integer([:positive])}"
    )

  File.mkdir_p!(sessions_dir)
  System.put_env("RAXOL_SESSIONS_DIR", sessions_dir)
  System.at_exit(fn _ -> File.rm_rf(sessions_dir) end)
end

# The invariant suite's fault-injection harness lives under test/invariants/
# (not test/support/, which elixirc_paths compiles) — load it explicitly.
Code.require_file("invariants/support/fault_journal.ex", __DIR__)

# Red-suite support (permanent failing-first contours) lives under test/raxol/…/red/
# support/ (also outside test/support/) — load it explicitly, same idiom.
Code.require_file("raxol/agent/red/support/u10_compaction.ex", __DIR__)

# :pending_unit — Tier 2 invariant skeletons, visible in the suite but inert
# until their units (U4–U9) land. :mutation — negative-control checklists
# (meta-invariant m4), run on demand, never in regular CI. :harness_red —
# permanent failing-first red contours authored against not-yet-implemented
# seams (they fail by construction; run with `--only harness_red`). Their
# CI-green control companions are NOT tagged and run every pass.
ExUnit.start(exclude: [:slow, :integration, :docker, :pending_unit, :mutation, :harness_red])
