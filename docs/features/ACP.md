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

`Raxol.ACP.Job.StateMachine` is a pure module -- no GenServer, no side effects. `Job.Server` calls into it for transitions and persists the result via `Job.Store`.

```elixir
{:ok, job_id} = Raxol.ACP.Job.Server.start(
  offering: MyOffering,
  buyer_address: "0x...",
  amount_usdc: 50
)

Raxol.ACP.Job.Server.deliver(job_id, %{result: "..."})
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

  @impl true
  def handle_request(job, params) do
    {:ok, %{sentiment: analyze(params.text)}}
  end
end
```

The DSL injects the `Handler` behaviour and registers metadata in the ETS-backed `Registry`. `Job.Server.accept_request/1` and `deliver/1` auto-invoke the handler and auto-sign memos with the configured wallet.

## Memos

Each phase emits an EIP-712 typed-data memo signed by the agent's wallet. Built via `Raxol.ACP.Job.Memo` on top of `Raxol.Payments.EIP712` and any `Raxol.Payments.Wallet` impl.

| Phase         | Memo contents                                |
| ------------- | -------------------------------------------- |
| Request       | Offering id, buyer, amount, expiry           |
| Negotiation   | Counter-offer or acceptance                  |
| Transaction   | On-chain tx hash, amount escrowed            |
| Evaluation    | Delivery proof, off-chain artifact pointer   |
| Completed     | Final settlement, release-of-escrow proof    |

## On-Chain Client

`Raxol.ACP.ContractClient` is a behaviour with two implementations:

- `InMemory` -- for tests. No network, deterministic.
- `Onchain` -- production. Req-based JSON-RPC, EIP-1559 typed transactions, Yellow-Paper RLP encoding, log decoder for `create_job` to extract the job id.

`Raxol.ACP.ABI` hand-rolls the Solidity encoder for the four ACP methods. Selectors verified byte-for-byte against canonical ERC-20.

## Nonce Serialization

The `Raxol.ACP.Wallet.NonceServer` GenServer serializes EVM nonce assignment through its mailbox. The original integration plan claimed process-per-job avoided concurrent-Alchemy collisions -- it doesn't. NonceServer does.

## Seller Stack

Opt-in via `:seller_enabled` in config:

- `Backend.InMemory` -- in-process request queue (default)
- `Queue` -- bounded mailbox, backpressure
- `Runtime` -- worker pool dispatching to handlers
- `Supervisor` -- ties it all together

`Backend.WebSocket` (talking to Virtuals' relayer) is on the roadmap. The protocol spec is available via the `virtuals-protocol-acp` skill.

## What's Blocked

External dependencies still pending:

- `Wallet.SCA` -- needs Virtuals' SCA contract spec
- Real Virtuals ABIs (current encoder uses placeholder method ids)
- WebSocket protocol implementation

`mix raxol_acp.bench` is a sandbox-graduation harness that runs end-to-end against the InMemory backend.

## See Also

- [Agentic Commerce](AGENTIC_COMMERCE.md) -- the buyer side (raxol_payments)
- [Agent Framework](AGENT_FRAMEWORK.md) -- the runtime hosting the seller
