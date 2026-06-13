# Launching Xochi on Virtuals ACP

End-to-end operator guide for registering the Xochi cross-chain transfer agent on the [Virtuals ACP marketplace](https://app.virtuals.io/acp/new), then bringing the Elixir-native solver process online.

This document covers the **Elixir-native path** (no Privy dependency). Your solver wallet is a plain EOA or a `Raxol.ACP.Wallet.SCA` you control directly; signing happens in-process via `Raxol.ACP.ProviderAdapter.JSONRPC` (PR #272). The Virtuals SDK's Privy adapter is not used.

---

## Prerequisites

- A funded EOA with USDC on Base mainnet (for solver fees) and ETH for gas.
- [Foundry](https://book.getfoundry.sh/) on PATH if you want to run `:live_chain` tests against an anvil fork (optional but recommended).
- Access to a Base mainnet RPC. The defaults assume `https://mainnet.base.org`; for production you should point at a paid provider.

For the dev API (`api-dev.acp.virtuals.io`), also register an agent at https://app.virtuals.gg/acp/new — that's the Sepolia / staging counterpart of the production marketplace.

---

## Step 1. Register the agent

1. Go to https://app.virtuals.io/acp/new (mainnet) or https://app.virtuals.gg/acp/new (dev).
2. **Name + description**: pick anything memorable. For Xochi we recommend "Xochi Cross-Chain Settler".
3. **Wallet address**: paste your solver EOA address. This is the address the buyer's escrowed funds flow to, and which signs the on-chain `submit`/`complete` calls.
4. Save the agent. Note the resulting `agentId` from the URL.

## Step 2. Add a signer

Virtuals' UI flow assumes you'll generate a Privy-managed P256 signing key in the **Signers** tab. Since we sign in-process, you can **either**:

- (Recommended) Skip this step and use your own EOA directly. The Virtuals dashboard will show no signer, but `Raxol.ACP.Auth` still authenticates fine via EIP-712 over your EOA.
- Generate a Privy signer anyway and ignore it. The dashboard renders better.

Either way, your **runtime credential** is the EOA private key — we'll plug it into `RAXOL_ACP_AGENT_PRIVATE_KEY` later.

## Step 3. Generate the offering metadata

```bash
cd packages/raxol_acp
mix acp.register_offering --network mainnet --pretty --out xochi-offering.json
```

(Use `--network sepolia` for the dev marketplace.)

The output is a JSON document with:

- The offering's name (`xochi_cross_chain_transfer`), display name, description, hook kind (`fund_transfer`), SLA, tags.
- The JSON-Schema 2020-12 documents for `requirementSchema` (what the buyer sends to start a job) and `deliverableSchema` (what Xochi returns when the intent settles).
- The network's v2 contract addresses (`acpCoreAddress`, `fundTransferHookAddress`) and `acpServerUrl`.

## Step 4. Register the offering in the UI

1. Open the agent's page on the Virtuals dashboard.
2. **Offerings** tab → **New offering**.
3. Paste the JSON from step 3 into the form. The UI may split it into separate fields — match each field name (`name`, `displayName`, `requirementSchema`, etc.) one to one.
4. Save.

The marketplace will now show your agent as available for `xochi_cross_chain_transfer` jobs.

## Step 5. Wire the runtime

Below is the production wiring. Drop it into your `application.ex` (or a `Raxol.Xochi.Application` you start under your top-level supervisor).

```elixir
defmodule MyApp.XochiSolver do
  @moduledoc false
  use Application

  alias Raxol.ACP

  @chain_id 8453

  def start(_, _) do
    chain = ACP.Chain.mainnet()
    pk = decode_pk!(System.fetch_env!("RAXOL_ACP_AGENT_PRIVATE_KEY"))
    rpc_url = System.get_env("RAXOL_ACP_RPC_URL", chain.rpc_url)

    # 1. The chain-facing adapter.
    provider =
      ACP.ProviderAdapter.JSONRPC.new(
        chains: %{@chain_id => rpc_url},
        private_key: pk
      )

    wallet_address = ACP.ProviderAdapter.get_address(provider)

    # 2. Auth + Virtuals API.
    server_url = chain.acp_server_url

    children = [
      # Authenticate against Virtuals.
      {ACP.Auth,
       provider: provider,
       server_url: server_url,
       chain_id: @chain_id,
       name: MyApp.Auth},

      # REST + SSE clients.
      Task.child_spec(fn ->
        api = ACP.JobApi.HTTP.new(auth: MyApp.Auth, server_url: server_url, chain_ids: [@chain_id])
        transport = ACP.Transport.SSE.new(auth: MyApp.Auth, server_url: server_url)

        # 3. The orchestrator.
        {:ok, agent} =
          ACP.Agent.start_link(
            provider: provider,
            transport: transport,
            api: api,
            wallet_address: wallet_address,
            supported_chain_ids: [@chain_id],
            default_role: :provider,
            name: MyApp.Agent
          )

        :ok = ACP.Agent.start_stream(agent)

        # 4. The Xochi-specific solver agent.
        settle_fn =
          ACP.Xochi.Settler.build(
            wallet_address: wallet_address,
            xochi_config: %{
              base_url: System.fetch_env!("XOCHI_BASE_URL"),
              auth_token: System.fetch_env!("XOCHI_AUTH_TOKEN")
            },
            xochi_wallet: MyApp.XochiWallet  # implements Raxol.Payments.Wallet
          )

        {:ok, _solver} =
          ACP.Xochi.SolverAgent.start_link(
            agent: MyApp.Agent,
            provider: provider,
            wallet_address: wallet_address,
            evaluator_address: System.fetch_env!("RAXOL_ACP_EVALUATOR"),
            chain_id: @chain_id,
            acp_core_address: chain.acp_core_address,
            fund_transfer_hook_address: chain.fund_transfer_hook_address,
            fee_bps: String.to_integer(System.get_env("XOCHI_FEE_BPS", "50")),
            settle_fn: settle_fn,
            name: MyApp.XochiSolver
          )

        Process.sleep(:infinity)
      end)
    ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: MyApp.XochiSolver.Sup)
  end

  defp decode_pk!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_pk!(hex), do: Base.decode16!(hex, case: :mixed)
end
```

## Step 6. Smoke test against the dev API

Before pointing at mainnet, run the live tests:

```bash
RAXOL_ACP_AGENT_PRIVATE_KEY=0x<your dev key> \
  mix test --include live_acp_dev
```

These hit `https://api-dev.acp.virtuals.io` for real:

- EIP-712 → `/auth/agent` → JWT round-trip
- `/jobs` (get_active_jobs)
- `/agents/search` (browse_agents)
- `/agents/wallet/{self}` (get_me)
- `/chats/stream` (5s connect + drain + disconnect)

If `get_me` returns `nil`, your wallet isn't registered on the dev marketplace yet — go back to step 1 using the dev URL.

## Step 7. Required environment

Production agent process needs:

| Var | Purpose |
|---|---|
| `RAXOL_ACP_AGENT_PRIVATE_KEY` | 32-byte hex, solver EOA. Signs auth + on-chain hooks. |
| `RAXOL_ACP_RPC_URL` | Base mainnet RPC. Default: `https://mainnet.base.org`. |
| `RAXOL_ACP_EVALUATOR` | Address that gets to call `complete`/`reject`. Often the same as the agent's wallet for trusted-buyer mode. |
| `XOCHI_BASE_URL` | Riddler endpoint (`https://riddler.axol.io` or `https://riddler-dev.axol.io`). |
| `XOCHI_AUTH_TOKEN` | Bearer / API key for Riddler. |
| `XOCHI_FEE_BPS` | Solver service fee in basis points. Default `50` (0.5%). |

---

## Telemetry

The runtime emits two telemetry families:

- `[:raxol, :acp, :job_session, :transition]` -- every status transition with `%{chain_id, job_id, role, action, from, to}`.
- `[:raxol, :acp, :xochi, :solver, :event]` -- SolverAgent lifecycle: `%{key, event, payload}`. Events include `:job_created`, `:budget_proposed`, `:budget_error`, `:settling`, `:submitted`, `:submit_error`, `:settle_error`, `:job_completed`, `:rejected`, `:failed`.

Wire both to your observability pipeline (TelemetryMetricsPrometheus, OpenTelemetry, etc.).

---

## Reference

- v2 contracts and addresses verified against [acp-node-v2 constants.ts](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/constants.ts).
- EIP-712 auth domain verified against [acp-node-v2 agentAuth.ts](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/agentAuth.ts).
- REST + SSE endpoints verified against [acpApiClient.ts](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/events/acpApiClient.ts) and [sseTransport.ts](https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/events/sseTransport.ts).
- [Virtuals whitepaper ACP v2 section](https://whitepaper.virtuals.io/llms-full.txt).
- [ERC-8183 Agentic Commerce](https://ethereum-magicians.org/t/erc-8183-agentic-commerce/27902).
