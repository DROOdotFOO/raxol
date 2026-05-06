# raxol_acp

Elixir/OTP-native Agent Commerce Protocol (ACP) implementation for the
[Virtuals](https://app.virtuals.io) agent marketplace.

> Status: pre-alpha. Public surface is unstable. Targeting v0.1 with a
> single graduated offering on Base mainnet.

## Why OTP for ACP

Every other ACP seller is a Python or Node script wrapped around a WebSocket,
with hand-rolled `threading.Lock` for concurrent jobs and a polling loop for
flaky sockets. OTP solves both at the runtime layer:

| ACP runtime requirement       | Other SDKs                | raxol_acp                                     |
| ----------------------------- | ------------------------- | --------------------------------------------- |
| Concurrent job handling       | Thread-safe queue + locks | One supervised process per job                |
| Reconnect on socket drop      | Polling fallback          | Supervisor with backoff                       |
| One agent, many offerings     | Single fragile process    | Process-per-offering, crash isolation         |
| Hot-fix a buggy offering      | Redeploy, drop sockets    | Hot code reload                               |
| Wallet nonce serialization    | Best-effort retries       | Dedicated `NonceServer` GenServer per wallet  |

## Installation

```elixir
def deps do
  [
    {:raxol_acp, "~> 0.1"}
  ]
end
```

The package self-starts via its OTP application entry. Add it to your deps,
run `mix deps.get`, and `Raxol.ACP.Supervisor` boots automatically.

## Architecture

See `Raxol.ACP.Supervisor` for the supervision tree. Three subsystems:

- **Job lifecycle** -- `Raxol.ACP.Job.{Server, Supervisor, Registry, StateMachine, Memo, Store}`. One `:gen_server` per active job, registered by job ID, with ETS-backed memo persistence so a node restart resumes mid-flight.
- **Offering** -- `Raxol.ACP.Offering.{Handler, Registry, DSL}`. Define an offering with `use Raxol.ACP.Offering`; it becomes a registered Job Offering on Virtuals.
- **Seller runtime** -- `Raxol.ACP.Seller.{Runtime, Queue, Supervisor}`. Holds the WebSocket to the ACP backend, dispatches incoming jobs to the queue.

## Dependencies

- `raxol_payments` for wallet signing (`Raxol.Payments.EIP712`, `Raxol.Payments.Wallet`) and Xochi cross-chain settlement
- `raxol_mcp` (compile-time only, `runtime: false`) for v0.2 widget-tree-derived offering manifests

## License

MIT. See `LICENSE.md`.
