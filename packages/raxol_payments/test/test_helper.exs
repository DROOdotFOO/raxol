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
#   :cli_signer -- spawn Riddler's e2e-signer CLI from RIDDLER_CHECKOUT_DIR.
#   :conformance -- read the pinned @xochi/spec EIP-712 fixture from the
#     verified package root in XOCHI_SPEC_DIR (required under CI).
#   :stealth_conformance -- match the stealth scheme against a reference SDK
#     fixture (STEALTH_VECTORS_PATH).
env_set? = fn name -> System.get_env(name) not in [nil, ""] end

gated_tags = [
  {[:cli_signer], env_set?.("RIDDLER_CHECKOUT_DIR")},
  {[:conformance], env_set?.("XOCHI_SPEC_DIR")},
  {[:stealth_conformance],
   System.get_env("STEALTH_VECTORS_PATH") ||
     File.exists?(Path.join(__DIR__, "fixtures/stealth_vectors.json"))}
]

gated_exclude =
  Enum.flat_map(gated_tags, fn {tags, enabled} ->
    if enabled, do: [], else: tags
  end)

ExUnit.configure(exclude: live_exclude ++ gated_exclude)
