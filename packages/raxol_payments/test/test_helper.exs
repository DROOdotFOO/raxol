ExUnit.start()

# Fund-moving suites are ALWAYS excluded. They spend real mainnet USDC, so
# the presence of an endpoint/key in the environment must not be enough to
# run them -- an explicit `--include live_xochi` (or `--only`) is the sole
# opt-in, which is what scripts/run_live_gates.sh passes on every cell.
#
#   :live_xochi -- drives the full intent lifecycle (and the :live_xochi_matrix
#     / :live_xochi_preflight cells inside it) against a real Xochi endpoint
#     with a funded wallet.
#   :live_relay -- drives the EVM->Tron relay with a funded wallet.
#   :live_property -- property runs against the live quote endpoints.
live_exclude = [:live_xochi, :live_relay, :live_property]

# Each entry excludes a tag by default unless its enabling env var is set.
# These read fixtures or spawn a local CLI; none of them move funds.
#
#   :cli_signer / :conformance -- spawn the riddler-client CLI or read
#     its shared EIP-712 fixture (RIDDLER_CLI_DIR / CONFORMANCE_FIXTURE_PATH).
#   :stealth_conformance -- match the stealth scheme against a reference SDK
#     fixture (STEALTH_VECTORS_PATH).
gated_tags = [
  {[:cli_signer, :conformance],
   System.get_env("RIDDLER_CLI_DIR") ||
     System.get_env("CONFORMANCE_FIXTURE_PATH")},
  {[:stealth_conformance],
   System.get_env("STEALTH_VECTORS_PATH") ||
     File.exists?(Path.join(__DIR__, "fixtures/stealth_vectors.json"))}
]

gated_exclude =
  Enum.flat_map(gated_tags, fn {tags, enabled} ->
    if enabled, do: [], else: tags
  end)

ExUnit.configure(exclude: live_exclude ++ gated_exclude)
