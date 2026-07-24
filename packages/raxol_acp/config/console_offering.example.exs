import Config

# Example configuration for running the `custom_console_agent` offering as a
# seller, with M1 crash-recovery (checkpointing + boot resync) enabled and a
# Base Sepolia dry-run profile.
#
# This file is a REFERENCE, not loaded by the app. Copy the keys you need into
# your own `config/runtime.exs` (or a released config). Every key below is read
# defensively with a safe default, so an unset key just disables that feature --
# nothing here is required for the package's own test suite.
#
# See RUNBOOK.md for the end-to-end provisioning -> funding -> registration ->
# live-on-Sepolia flow that consumes this config.

# ---------------------------------------------------------------------------
# Seller stack (opt-in). Bring up Seller.Supervisor and route jobs to the
# console offering. `Seller.Supervisor` starts `Console.BenchSlots` automatically
# when `AgentOffering` is in `:offerings`.
# ---------------------------------------------------------------------------
config :raxol_acp,
  seller_enabled: true,
  offerings: [Raxol.ACP.Console.AgentOffering],
  # Socket.IO relayer for live jobs; use Backend.InMemory for local rehearsal.
  seller_backend: Raxol.ACP.Seller.Backend.WebSocket,
  # Chain the jobs live on. The Queue defaults to 8453 (Base mainnet); Sepolia
  # MUST be set explicitly.
  seller_chain_id: 84_532,
  seller_max_active_jobs: 100

# The signing adapter (SCA sponsored UserOps by default; Privy sidecar or plain
# JSONRPC EOA are the alternatives). Build it from a wallet whose key comes from
# `Raxol.Payments.Wallets.{Env, Op}` -- never a literal here.
#
#   config :raxol_acp,
#     seller_provider_adapter: Raxol.ACP.ProviderAdapter.SCA.new(...),
#     seller_acp_core_address: nil   # nil -> Chain.mainnet()/sepolia() default

# ---------------------------------------------------------------------------
# M1 durability: checkpoint store + fail-closed posture + boot/reconnect resync.
# ---------------------------------------------------------------------------
config :raxol_acp,
  # `nil` (off) | `{:ets, name}` (supervisor-owned named table, survives
  # Queue/session crashes but NOT a BEAM restart -- pair with the resync below)
  # | `{module, handle}` (any Raxol.Payments.Checkpoint impl for cross-restart
  # durability, e.g. a DETS-backed store).
  checkpoint: {:ets, :raxol_acp_checkpoint},
  # Release posture: refuse to sign a fund-adjacent write (setBudget/submit) with
  # no durable store configured. Leave false in dev; true in production.
  require_checkpoint: true,
  # Off-chain JobApi for (a) boot/reconnect resync via get_active_jobs and (b)
  # out-of-band deliverable posting after submit. Forwarded to JobApi.HTTP.new/1.
  # nil disables both (resync becomes a no-op).
  seller_job_api_opts: [
    auth: Raxol.ACP.Auth,
    server_url: "https://api-dev.acp.virtuals.io",
    chain_ids: [84_532]
  ]

# ---------------------------------------------------------------------------
# Console offering: wallet-funded inference, artifact hosting, and the bench.
# ---------------------------------------------------------------------------
config :raxol_acp,
  # Wallet-funded Virtuals compute (OpenAI-compatible). Defaults shown; override
  # api_key/model as needed. `{:system, "VAR"}` reads the key from the env.
  console_inference: [
    module: Raxol.ACP.Console.Inference.Compute,
    base_url: "https://compute.virtuals.io/v1",
    api_key: {:system, "VIRTUALS_API_KEY"},
    model: "moonshotai/kimi-k2-0905",
    receive_timeout: 120_000
  ],
  # Where generated package artifacts (tarball, transcript, report) are written.
  # `Local` needs a `:dir`; `:base_url` turns file paths into fetchable URLs.
  console_artifact_store: [
    module: Raxol.ACP.Console.ArtifactStore.Local,
    dir: "/var/lib/raxol_acp/console_artifacts",
    base_url: "https://artifacts.example.com/console"
  ],
  # Bench harness: one operator-provided wrapper per runtime that boots the
  # open-source runtime against the materialized package. `:cmd` is `{exe, args}`;
  # the wrapper reads RAXOL_BENCH_CHECK / RAXOL_BENCH_PKG_DIR / RAXOL_BENCH_PROMPT
  # / RAXOL_BENCH_TASK from its env and exits 0 on success.
  console_bench: [
    prompt: "Introduce yourself in one sentence.",
    hermes: [cmd: {"/opt/raxol/bench/hermes.sh", []}],
    openclaw: [cmd: {"/opt/raxol/bench/openclaw.sh", []}]
  ],
  # Bench-slot ledger (scarce-resource gate for bench_validated jobs).
  console_bench_slots: 1,
  console_bench_slot_ttl_ms: 2_700_000,
  # Light pre-escrow content policy: downcased substrings rejected in purpose/persona.
  console_deny_terms: [],
  # Accepted soul.md size window (bytes) for the static validator.
  console_soul_bytes: {50, 40_000}

# ---------------------------------------------------------------------------
# Base Sepolia network override. `chain_overrides` is keyed by NETWORK NAME
# (`:sepolia` / `:mainnet`), not chain id, and shallow-merges over the built-in
# `Raxol.ACP.Chain` config. Sepolia defaults to canonical Circle USDC
# (0x036CbD53842c5426634e7929541eC2318f3dCF7e); the Virtuals sandbox issues its
# own test USDC, so set that address here for funding checks. Leave this block
# out entirely to use the Circle default.
# ---------------------------------------------------------------------------
config :raxol_acp,
  chain_overrides: %{
    sepolia: %{
      # From the Virtuals dev/sandbox docs -- fill in the sandbox test-USDC token.
      usdc_address: System.get_env("RAXOL_ACP_SEPOLIA_USDC") || "0x<virtuals-test-usdc>"
    }
  }
