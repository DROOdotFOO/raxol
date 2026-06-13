ExUnit.start()

# Tests tagged :cli_signer spawn the riddler-permit2-erc3009 CLI. Skipped
# by default; enable with `mix test --include cli_signer` or by setting
# RIDDLER_CLI_DIR in the environment so the helper can find the CLI repo.
#
# Tests tagged :conformance read the shared EIP-712 fixture from the CLI
# repo. Same skip-by-default rules as :cli_signer.
unless System.get_env("RIDDLER_CLI_DIR") || System.get_env("CONFORMANCE_FIXTURE_PATH") do
  ExUnit.configure(exclude: [:cli_signer, :conformance])
end

