# `:integration` tests hit an external Postgres database via the
# `PausedSaver.Postgrex` adapter. They are opt-in: set
# `RAXOL_SYMPHONY_PG_URL` and run with `mix test --include integration`.
#
# `:needs_file_watcher` marks the two tests that assert a LIVE file watcher.
# `file_system`'s Linux backend shells out to `inotifywait`, so on a host
# without inotify-tools it declines to start and there is nothing for them to
# observe. Detected rather than hardcoded per platform, so a Linux box that DOES
# have the tools still runs them -- and so the exclusion can never quietly cover
# a watcher that broke for some other reason.
#
# The store coming up at all is asserted separately and unconditionally: that is
# the part a missing package must not break, and it did.
watcher_available? =
  Code.ensure_loaded?(FileSystem) and
    (match?({:unix, :darwin}, :os.type()) or System.find_executable("inotifywait") != nil)

excluded = if watcher_available?, do: [:integration], else: [:integration, :needs_file_watcher]

unless watcher_available? do
  IO.puts("[raxol_symphony] no file_system backend available -- skipping :needs_file_watcher")
end

ExUnit.start(exclude: excluded)

# Session journals are durable by design, and `Raxol.Agent.Journal.FileStore`
# defaults its base to ~/.raxol/sessions. Without this override every run of
# this suite left ~170 real session directories in the developer's home (they
# had accumulated to 3339 dirs / 39MB before anyone noticed). Tests get a tmp
# base instead; nothing here asserts on the real one.
System.put_env(
  "RAXOL_SESSIONS_DIR",
  Path.join(System.tmp_dir!(), "raxol-symphony-test-sessions")
)

# raxol_earn is pulled in as a test-only dep to exercise the canonical
# auto-resume integration (see test/raxol/symphony/integration/
# acp_resume_e2e_test.exs). raxol_earn's Application starts the
# JobSession supervisor tree automatically when the dep is loaded, so
# no extra wiring is needed here.
