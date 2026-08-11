# `:integration` tests hit an external Postgres database via the
# `PausedSaver.Postgrex` adapter. They are opt-in: set
# `RAXOL_SYMPHONY_PG_URL` and run with `mix test --include integration`.
ExUnit.start(exclude: [:integration])

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
