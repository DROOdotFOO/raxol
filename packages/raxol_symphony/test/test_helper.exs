# `:integration` tests hit an external Postgres database via the
# `PausedSaver.Postgrex` adapter. They are opt-in: set
# `RAXOL_SYMPHONY_PG_URL` and run with `mix test --include integration`.
ExUnit.start(exclude: [:integration])

# raxol_earn is pulled in as a test-only dep to exercise the canonical
# auto-resume integration (see test/raxol/symphony/integration/
# acp_resume_e2e_test.exs). raxol_earn's Application starts the
# JobSession supervisor tree automatically when the dep is loaded, so
# no extra wiring is needed here.
