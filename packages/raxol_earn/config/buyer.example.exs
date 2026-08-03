import Config

# Example configuration for running the ACP BUYER stack -- the autonomous client
# that discovers an offering, funds a job within spend limits, and evaluates the
# deliverable, with crash-safe idempotency (M3).
#
# This file is a REFERENCE, not loaded by the app. Copy the keys you need into
# your own `config/runtime.exs`. Every key is read defensively with a safe
# default, so an unset key just disables that feature.
#
# See RUNBOOK.md ("Buy side") for the offline rehearsal and the Sepolia dry-run
# in which the buyer is the real second wallet driving create -> fund -> complete.

# ---------------------------------------------------------------------------
# Buyer stack (opt-in). Bring up Buyer.Supervisor: Queue + Resync + Runtime.
# ---------------------------------------------------------------------------
config :raxol_earn,
  buyer_enabled: true,
  # This buyer's wallet (0x string). Surfaced in the handler/evaluate ctx and
  # used to filter our own jobs during resync.
  buyer_address: System.get_env("RAXOL_ACP_BUYER_ADDRESS"),
  # Chain the jobs live on. Defaults to 8453 (Base mainnet); Sepolia MUST be set.
  buyer_chain_id: 84_532,
  # ACP v2 core; defaults to Chain.mainnet/0 when unset.
  buyer_acp_core_address: nil,
  # Ledger agent id for spend accounting.
  buyer_agent_id: :raxol_buyer

# The signing adapter that writes createJob / fund / complete on-chain. Same
# `Raxol.Earn.ProviderAdapter` the seller uses (SCA sponsored UserOps, a Privy
# signer sidecar, or a plain JSONRPC EOA). Required to write -- with none, a
# purchase drops with `:no_provider_adapter`.
#
#     config :raxol_earn, buyer_provider_adapter: my_adapter

# ---------------------------------------------------------------------------
# Spend gating (fail closed in production). The buyer reserves the quoted amount
# atomically before any on-chain write; with no policy configured the gate
# refuses to spend in production (require_policy defaults to
# Raxol.Payments.Deployment.production?()).
# ---------------------------------------------------------------------------
config :raxol_earn,
  # A running Raxol.Payments.Ledger server (name or pid).
  buyer_ledger: Raxol.Payments.Ledger,
  # Per-request / session / lifetime caps.
  buyer_spending_policy: %Raxol.Payments.SpendingPolicy{
    per_request_max: Decimal.new("15.00"),
    session_max: Decimal.new("100.00"),
    lifetime_max: Decimal.new("1000.00"),
    currency: "USDC"
  }

# ---------------------------------------------------------------------------
# Crash-safe idempotency (shared with the seller). The buyer keys a single
# accreting record by a client-minted request_key. Set require_checkpoint: true
# in a fund-moving deployment so a misconfigured buyer fails closed.
# ---------------------------------------------------------------------------
config :raxol_earn,
  checkpoint: {:ets, :raxol_earn_checkpoint},
  require_checkpoint: true

# ---------------------------------------------------------------------------
# Event source + discovery. The Runtime subscribes to the configured backend for
# this buyer's job lifecycle events. For local rehearsal use the shared InMemory
# backend; a production buyer points this at an SSE-backed source for its own
# jobs (the Raxol.Earn.Agent stream -- the remaining integration item for the
# Sepolia dry-run). The backend process itself is started by the host app, not
# by Buyer.Supervisor.
# ---------------------------------------------------------------------------
config :raxol_earn,
  buyer_backend: Raxol.Earn.Seller.Backend.InMemory,
  # Off-chain REST discovery + active-job listing (for browse + resync).
  # Forwarded to Raxol.Earn.JobApi.HTTP.new/1.
  buyer_job_api_opts: [
    server_url: "https://api-dev.acp.virtuals.io",
    chain_ids: [84_532]
  ],
  # jobId resolution after createJob. Defaults to JobIdResolver.Receipt.
  # CONFIRM the JobCreated event signature / indexed position in the dry-run,
  # then override here:
  #
  #     buyer_job_id_resolver:
  #       {Raxol.Earn.JobIdResolver.Receipt,
  #        %{event_signature: "JobCreated(uint256)", topic_index: 1}}
  buyer_job_id_resolver: nil
