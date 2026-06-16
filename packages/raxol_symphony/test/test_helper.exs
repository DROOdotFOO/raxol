# `:integration` tests hit an external Postgres database via the
# `PausedSaver.Postgrex` adapter. They are opt-in: set
# `RAXOL_SYMPHONY_PG_URL` and run with `mix test --include integration`.
ExUnit.start(exclude: [:integration])

# raxol_acp is pulled in as a test-only dep to exercise the canonical
# auto-resume integration (see test/raxol/symphony/integration/
# acp_resume_e2e_test.exs). raxol_acp's Application starts the
# supervisor automatically when it's a runtime dep, but the
# InMemory contract client and the env-level :contract_client setting
# must be wired here. Matches the convention in
# packages/raxol_acp/test/test_helper.exs.
if Code.ensure_loaded?(Raxol.ACP.ContractClient.InMemory) do
  Application.put_env(:raxol_acp, :contract_client, Raxol.ACP.ContractClient.InMemory)
end
