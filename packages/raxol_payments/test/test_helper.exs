ExUnit.start()

# Tests tagged :cli_signer spawn the riddler-permit2-erc3009 CLI. Skipped
# by default; enable with `mix test --include cli_signer` or by setting
# RIDDLER_CLI_DIR in the environment so the helper can find the CLI repo.
unless System.get_env("RIDDLER_CLI_DIR") do
  ExUnit.configure(exclude: [:cli_signer])
end

