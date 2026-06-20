ExUnit.start()

# Tests tagged :cli_signer spawn the riddler-permit2-erc3009 CLI. Skipped
# by default; enable with `mix test --include cli_signer` or by setting
# RIDDLER_CLI_DIR in the environment so the helper can find the CLI repo.
#
# Tests tagged :conformance read the shared EIP-712 fixture from the CLI
# repo. Same skip-by-default rules as :cli_signer.
# Each entry excludes a tag by default unless its enabling env var is set:
#
#   :cli_signer / :conformance -- spawn the riddler-permit2-erc3009 CLI or read
#     its shared EIP-712 fixture (RIDDLER_CLI_DIR / CONFORMANCE_FIXTURE_PATH).
#   :stealth_conformance -- match the stealth scheme against a reference SDK
#     fixture (STEALTH_VECTORS_PATH).
#   :live_xochi -- drive the full intent lifecycle against a real (testnet)
#     Xochi endpoint with a funded wallet (XOCHI_LIVE_URL).
gated_tags = [
  {[:cli_signer, :conformance],
   System.get_env("RIDDLER_CLI_DIR") ||
     System.get_env("CONFORMANCE_FIXTURE_PATH")},
  {[:stealth_conformance], System.get_env("STEALTH_VECTORS_PATH")},
  {[:live_xochi], System.get_env("XOCHI_LIVE_URL")},
  {[:live_relay], System.get_env("RELAY_LIVE_URL")},
  {[:live_property], System.get_env("XOCHI_LIVE_URL") || System.get_env("RELAY_LIVE_URL")}
]

excluded =
  Enum.flat_map(gated_tags, fn {tags, enabled} ->
    if enabled, do: [], else: tags
  end)

ExUnit.configure(exclude: excluded)
