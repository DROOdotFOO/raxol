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

# :pending_unit — Tier 2 invariant skeletons, visible in the suite but inert
# until their units (U4–U9) land. :mutation — negative-control checklists
# (meta-invariant m4), run on demand, never in regular CI.
# :harness_red — permanent failing-first (RED) suites authored against the
# frozen freeze contracts BEFORE their unit's implementation lands (U9-R, ...).
# Excluded from CI so they stay red-but-green-CI; drop the exclusion when the
# unit lands and the suite must go green unchanged. Their negative-control
# ("*_controls_test.exs") counterparts are NOT tagged and DO run in CI.
red_excludes = [
  :slow,
  :integration,
  :docker,
  :pending_unit,
  :mutation,
  :harness_red
]

ExUnit.start(exclude: red_excludes)
