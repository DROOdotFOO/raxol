ExUnit.start()

# Configure the in-memory contract client for the test run. The test/support
# impl is the second real implementation of the ContractClient behaviour --
# not a mock; see Raxol.ACP.ContractClient for the rationale.
Application.put_env(:raxol_acp, :contract_client, Raxol.ACP.ContractClient.InMemory)

# Bring up the seller stack with the in-process backend. Tests that need
# specific Queue defaults (wallet, memo_opts, seller_address) overwrite
# the env and recycle the Queue in their own setup.
Application.put_env(:raxol_acp, :seller_enabled, true)
Application.put_env(:raxol_acp, :seller_backend, Raxol.ACP.Seller.Backend.InMemory)

# In :test the OTP application's :mod is not declared, so neither the
# supervisor nor the InMemory contract client auto-start. Bring them up
# explicitly for the test run.
{:ok, _} = Raxol.ACP.ContractClient.InMemory.start_link()
{:ok, _} = Raxol.ACP.Supervisor.start_link()
