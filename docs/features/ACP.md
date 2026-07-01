# Agent Commerce Protocol (ACP)

`raxol_acp` is an Elixir/OTP implementation of the [Virtuals ACP](https://www.virtuals.io/) for selling agent services on Base. Where `raxol_payments` is about *paying* (an agent that buys things), `raxol_acp` is about *being paid* (an agent that offers a service and accepts on-chain settlement).

Status: pre-alpha. Not yet on Hex; use the path dep at `packages/raxol_acp/`.

## Job Lifecycle

Every job is a state machine. One supervised `Job.Server` runs per active job:

```
:request -> :negotiation -> :transaction -> :evaluation -> :completed
                                                      \-> :rejected
            (any state) -> :expired
```

`Raxol.ACP.Job.StateMachine` is a pure module with no GenServer and no side effects. `Job.Server` calls into it for transitions and persists the result via `Job.Store`.

```elixir
{:ok, _pid} = Raxol.ACP.Job.Server.start_link(
  job_id: "0xabc...",
  handler: MyOffering,
  request: %{text: "..."},
  buyer: "0x...",
  seller: "0x..."
)

# Accept the buyer's request, then (once payment is escrowed) deliver.
# Both calls invoke the handler module configured above and address the
# server by its job id.
{:ok, :negotiation} = Raxol.ACP.Job.Server.accept_request("0xabc...")
{:ok, :evaluation} = Raxol.ACP.Job.Server.deliver("0xabc...")
```

## Offerings

An offering is a service the agent sells. Declared via the `Offering` DSL:

```elixir
defmodule Raxol.ACP.Offerings.SentimentAnalysis do
  use Raxol.ACP.Offering,
    name: "Sentiment Analysis",
    price_usdc: 10,
    sla_minutes: 5,
    cluster: "analytics"

  # Decide whether to take the job. Return {:accept, response} to enter
  # negotiation, or {:reject, reason} to bow out.
  @impl true
  def handle_request(request, _ctx) do
    {:accept, %{quoted_usdc: 10, text: request.text}}
  end

  # Payment is escrowed; produce the deliverable.
  @impl true
  def handle_deliver(request, _ctx) do
    {:deliver, %{sentiment: analyze(request.text)}}
  end
end
```

The DSL injects the `Handler` behaviour and registers metadata in the ETS-backed `Registry`. `Job.Server.accept_request/1` and `deliver/1` auto-invoke the handler and submit on-chain memos with the configured wallet.

## Memos

Each phase emits an on-chain memo via `Raxol.ACP.ContractClient.create_memo/5`, mirroring `InteractionLedger.createMemo` from the deployed contract. There is no off-chain memo signing: the canonical ACP contract does not accept a separate memo signature, the transaction itself is the proof. Memo kinds are the `Raxol.ACP.Job.MemoType` enum (uint8, ids 0..9).

| Phase         | Memo contents                                |
| ------------- | -------------------------------------------- |
| Request       | Offering id, buyer, amount, expiry           |
| Negotiation   | Counter-offer or acceptance                  |
| Transaction   | On-chain tx hash, amount escrowed            |
| Evaluation    | Delivery proof, off-chain artifact pointer   |
| Completed     | Final settlement, release-of-escrow proof    |

## On-Chain Client

`Raxol.ACP.ContractClient` is a behaviour with two implementations:

- `InMemory`: for tests. No network, deterministic.
- `Onchain`: production. Req-based JSON-RPC, EIP-1559 typed transactions, Yellow-Paper RLP encoding. `create_job` resolves the new job id from the `JobCreated` event's non-indexed `data` word (overridable via `:create_job_event_signature` / `:create_job_id_source`) and fails closed (`{:error, {:job_id_unresolved, _}}`) rather than return a synthetic id that would mis-target downstream calls; an integration harness opts back into the tx-hash placeholder with `config :raxol_acp, allow_placeholder_job_id: true`. A broadcast whose receipt never arrives returns `{:receipt_pending, tx_hash, _}` (plus telemetry) so a retry re-queries rather than re-broadcasts, and token amounts scale by the token's decimals (`config :raxol_acp, :token_decimals`, default 6 for USDC).

`Raxol.ACP.ABI` hand-rolls the Solidity encoder for the ACP methods. Selectors verified byte-for-byte against canonical ERC-20.

## Escrow Expiry and Reclaim

Start a `Job.Server` with `:expired_at` (unix seconds) and it arms a timer that auto-fires `:expire` once the deadline passes while the job is still non-terminal, so a job whose counterparty abandoned it does not wedge and its escrow is not stranded. The buyer reclaims the funds with `Job.Server.reclaim/1`, which calls `Raxol.ACP.ContractClient.withdraw_escrowed_funds/1` (the real `ACPSimple.withdrawEscrowedFunds`); the on-chain contract enforces that reclaim is only valid after expiry. The deadline rides the child spec, so it survives a transient restart.

## Nonce Serialization

The `Raxol.ACP.Wallet.NonceServer` GenServer serializes EVM nonce assignment through its mailbox. The original integration plan claimed process-per-job avoided concurrent-Alchemy collisions, but it doesn't. NonceServer does. A transaction that fails before it is broadcast rolls the consumed nonce back, so the next transaction reuses it instead of leaving a gap that would strand every later transaction (the SCA path reads its nonce fresh per call and is unaffected).

## Seller Stack

Opt-in via `:seller_enabled` in config:

- `Backend.InMemory`: in-process request queue (default)
- `Queue`: bounded mailbox, backpressure
- `Runtime`: worker pool dispatching to handlers
- `Supervisor`: ties it all together

`Backend.WebSocket` (talking to Virtuals' relayer) is on the roadmap. The protocol spec is available via the `virtuals-protocol-acp` skill.

## What's Blocked

External dependencies still pending:

- `Wallet.SCA`: needs Virtuals' SCA contract spec
- Real Virtuals ABIs (current encoder uses placeholder method ids)
- WebSocket protocol implementation

`mix raxol_acp.bench` is a sandbox-graduation harness that runs end-to-end against the InMemory backend.

## See Also

- [Agentic Commerce](AGENTIC_COMMERCE.md): the buyer side (raxol_payments)
- [Agent Framework](AGENT_FRAMEWORK.md): the runtime hosting the seller
