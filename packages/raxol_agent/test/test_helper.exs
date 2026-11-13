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
# code. The provider diagnostic fails exactly this way.
#
# Set rather than defaulted: an unlocked vault answers in well under a second,
# so this only ever truncates a wait that was going to be answered by a human
# who is not there. Tests that drive the timeout itself override it locally.
unless System.get_env("RAXOL_OP_TIMEOUT_MS") do
  System.put_env("RAXOL_OP_TIMEOUT_MS", "2000")
end

# :unix_only / :skip_on_windows mirror the root suite's Windows exclusion
# (test/test_helper.exs); :windows_only is its mirror image, for tests of the
# `{:win32, _}` branches that only a Windows host can exercise for real.
os_excludes =
  case :os.type() do
    {:win32, _} -> [:unix_only, :skip_on_windows]
    _ -> [:windows_only]
  end

# :pending_unit — invariant skeletons, visible in the suite but never run.
# :mutation — negative-control checklists, run on demand, never in regular CI.
#
# :harness_red — a suite written before the code it pins carries this tag and
# stays out of regular runs until that code exists. No suite carries it at
# present.
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
    :live_longcat
    | os_excludes
  ]
)
