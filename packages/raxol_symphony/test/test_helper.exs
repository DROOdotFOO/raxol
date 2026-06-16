# `:integration` tests hit an external Postgres database via the
# `PausedSaver.Postgrex` adapter. They are opt-in: set
# `RAXOL_SYMPHONY_PG_URL` and run with `mix test --include integration`.
ExUnit.start(exclude: [:integration])
