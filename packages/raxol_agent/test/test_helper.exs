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

# Bound every `op` shell-out for the whole run. The production default is 15s,
# sized so an interactive 1Password approval still fits -- but under test that
# is longer than the budget of any assertion waiting on the other side of it,
# so a LOCKED vault (which blocks `op` on its desktop authorization prompt)
# turns a passing test red on a machine state that has nothing to do with the
# code. `/inspect` was failing exactly this way.
#
# Set rather than defaulted: an unlocked vault answers in well under a second,
# so this only ever truncates a wait that was going to be answered by a human
# who is not there. Tests that drive the timeout itself override it locally.
unless System.get_env("RAXOL_OP_TIMEOUT_MS") do
  System.put_env("RAXOL_OP_TIMEOUT_MS", "2000")
end

# The invariant suite's fault-injection harness lives under test/invariants/
# (not test/support/, which elixirc_paths compiles) — load it explicitly.
Code.require_file("invariants/support/fault_journal.ex", __DIR__)

# Red-suite support (reference gates, dead injectors, shared contours) lives
# under test/raxol/agent/red/support/ — load it explicitly, same mechanic.
Code.require_file("raxol/agent/red/support/u8_gates.ex", __DIR__)
Code.require_file("raxol/agent/red/support/u10_compaction.ex", __DIR__)

# The U11-R red suite's oracle + generators live under test/raxol/agent/red/
# support (also outside elixirc_paths) — load them explicitly. Guard against a
# concurrent red PR having already required them.
for f <- [
      "raxol/agent/red/support/meta_oracle.ex",
      "raxol/agent/red/support/meta_journal_gen.ex"
    ] do
  mod =
    case f do
      "raxol/agent/red/support/meta_oracle.ex" -> Raxol.Agent.Red.MetaOracle
      _ -> Raxol.Agent.Red.MetaJournalGen
    end

  unless Code.ensure_loaded?(mod), do: Code.require_file(f, __DIR__)
end

# :pending_unit — Tier 2 invariant skeletons, visible in the suite but inert
# until their units (U4–U9) land. :mutation — negative-control checklists
# (meta-invariant m4), run on demand, never in regular CI.
#
# :harness_red — permanent failing-first red suites (test/raxol/agent/red/)
# authored BEFORE their units against the freeze contracts; excluded from every
# regular run so CI stays GREEN while the contract is pinned. A suite loses the
# tag (and joins CI green) the day its unit implements it. U11-R (meta family +
# provenance/taint) has graduated — U11-I implemented `Raxol.Agent.Meta` /
# `Raxol.Agent.Fingerprint`, so it now runs untagged in CI; the tag is kept in
# the exclude list for the next failing-first red. The negative CONTROLS for the
# same contours are NOT tagged :harness_red — they run in CI to prove each red
# has teeth (meta-invariant m4). (The former `:action_surface` marker on U8-R's
# §5.2 predicate block was retired: that predicate reads a structural
# `effect_class` supplied by the call map, needs no F2 `Raxol.Action` draft to
# exercise, and runs green — so the block is untagged, not deferred.)
ExUnit.start(
  exclude: [
    :slow,
    :integration,
    :docker,
    :pending_unit,
    :mutation,
    :harness_red,
    # :live_longcat hits the real LongCat API; run with
    # `LONGCAT_API_KEY=<key> mix test --only live_longcat`.
    :live_longcat,
    # :live_lsp drives a real language server (rust-analyzer) and indexes a
    # crate, so it is minutes and a toolchain rather than seconds; run with
    # `mix test --only live_lsp`.
    :live_lsp
  ]
)
