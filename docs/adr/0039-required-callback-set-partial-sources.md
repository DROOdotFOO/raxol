# ADR-0039: The required callback set, and what a partial source is

## Status

Accepted, 2026-09-14. Amends [ADR-0033](0033-web3-data-surface.md) decision 3, whose required
set of six this replaces with three. Everything else in that decision stands: the
`{module, state}` handle, `capabilities/1` plus the `function_exported?/3` check, the three
load-bearing shapes (a height that names its unit, an opaque tagged account reference, opaque
cursors in both directions), the `raw_request/2` allowlist, and the rule that reference
implementations ship in `lib/`.

Accepted rather than Proposed because two backends are blocked on it and cannot be written
against an undecided contract, and because it lands with its implementation in the same
change, so the alternative shape is visible in the diff rather than only in this file.

Upstream claims dated 2026-09-14 were probed on that date with the honest User-Agent ADR-0033
section 7 mandates. The re-probe commands are in "Validation".

## Context

ADR-0033 decision 3 requires six callbacks of every backend: `chain_info/1`,
`block_height/1`, `get_transaction/2`, `account_info/2`, `list_transactions/3` and
`token_balances/2`. The companion survey derived that set from what **chains** can answer,
and it is a good answer to that question.

It is the wrong question. The contract binds **sources**, and a chain is not a source. Chain 1
has at least three: a Blockscout instance, an Etherscan-compatible API, and a raw JSON-RPC
node. They answer different questions about the same chain, and the required set is the
intersection over sources, not over chains. Three consequences of getting that backwards were
all live before this decision:

1. **A raw-JSON-RPC source cannot be a backend.** No `eth_*` method answers "the transactions
   of this address" or "the tokens this address holds". `Raxol.Web3.RPC`'s allowlist is ten
   methods and none of them lists by account. So the coverage matrix's raw-RPC fallback, named
   for every EVM row in ADR-0033 section 5, had no contract to fit.
2. **Chain 4663 had nothing to fail over to.** Its only explorer surface answered 403 with
   `cf-mitigated: challenge` on 2026-09-13, and `Raxol.Web3.Backend.Blockscout` admits the
   chain and lets the breaker trip, which is right. The router then had no second candidate,
   because the raw-RPC path the matrix names could not be expressed.
3. **Aztec cannot answer `token_balances/2` at all.** Private notes are unobservable by
   construction. Forcing the callback yields an empty page for a question the chain cannot be
   asked, which a caller cannot distinguish from an account holding nothing.

### What the sources actually answer, measured

Three upstreams were probed on 2026-09-14, because the demotions below should rest on
measurement rather than on the shape of an API's name.

**Raw JSON-RPC.** Structural, not probed: the allowlist in
`packages/raxol_web3/lib/raxol/web3/rpc.ex` is `eth_blockNumber`,
`eth_getBlockByNumber`, `eth_getBlockByHash`, `eth_getTransactionByHash`,
`eth_getTransactionReceipt`, `eth_getBalance`, `eth_getCode`, `eth_getLogs`, `eth_call` and
`eth_chainId`. It answers `chain_info/1`, `block_height/1`, `get_transaction/2` and
`account_info/2` (a balance from `eth_getBalance`, code presence from `eth_getCode`). It
cannot answer `list_transactions/3` or `token_balances/2` without an index it does not have.

**Aztecscan** (`api.aztecscan.xyz/v1/temporary-api-key`). `l2/accounts` and
`l2/accounts/{address}` both answer 404. `l2/contract-instances/{address}` answers 200 for a
deployed instance, which is contract metadata rather than an account: the record carries an
address, a deployer, class and salt, and no balance field exists to report. `l2/txs` answers
200, and each item carries `txHash`, `feePayer` and timestamps, with no sender and no
recipient, so a per-account transaction list cannot be assembled from it at all. The private
half was already known to be unobservable; what is new here is that the **public** surface has
no account resource either, so on this chain `account_info/2` and `list_transactions/3` join
`token_balances/2` as questions the source cannot be asked.

**SQD Portal** (`portal.sqd.dev/mcp`). Stateless, keyless, 31 tools today against the survey's
28 on 2026-08-31, which is drift worth recording rather than a discrepancy to resolve.
`portal_get_head` takes `type: latest | finalized`, so it answers `block_height/1` including
the finalized half. `portal_get_network_info` answers indexing freshness and lag, which is
`chain_info/1` plus the height shape's `indexer` field. `portal_list_networks` takes
`vm: evm | tron | solana | bitcoin | substrate | hyperliquid` and `real_time_only`, which is
how a supported network is resolved at runtime rather than hardcoded. The nearest thing to an
account read is `portal_get_wallet_summary`, and it takes an address plus a look-back
`timeframe` and returns activity and fund flow over that window: an archive answers queries
over ranges, and "the current native balance of this account" is not a range query. So the
Solana primary cannot answer `account_info/2` while its public-RPC fallback can.

One further measurement, recorded here because it bears on ADR-0037's era probe rather than on
this decision: SQD's `tools/list` result carries no `ttlMs` and no `cacheScope`, which the
2026-07-28 revision requires on a list result. A client that treats their absence as evidence
of a legacy server would misclassify a server that is otherwise on the current revision.

### Why this is not a module's decision

Either resolution changes ADR-0033, and implementing either one inside a backend would mean a
`list_transactions/3` that returns `{:error, {:unsupported, _}}` to satisfy a behaviour, which
is a stub with a behaviour attached and is what the repository's rules forbid.

## Decision

### 1. The required set is three

Required: `chain_info/1`, `block_height/1`, `get_transaction/2`.

Optional, declared through `capabilities/1` and checked by `Backend.supports?/2`:
`account_info/2`, `list_transactions/3`, `token_balances/2`, plus the eight ADR-0033 already
makes optional. Eleven optional, three required, fourteen callbacks unchanged.

The three are the measured intersection, and they have a property in common that is worth
naming because it predicts the next source too: each is answerable from a chain identity, a
height, and a transaction id, which is the least a thing can know and still be a source of
chain data. Every question that has to be asked *about an account* needs an index over
accounts, and an index is exactly what a node does not have and what an archive has only over
ranges.

`Backend.required/0` remains the dispatch rule: a required callback is always dispatched,
an optional one is dispatched only when the handle declares and exports it. That is unchanged
code with a shorter list.

### 2. No second contract

The rejected alternative was a separate behaviour for a partial source, with the router
routing across both. Three reasons, in increasing order of weight.

A second behaviour would redeclare `backend/0`, `supported_chain_ids/1`, `capabilities/1` and
`health_key/1` verbatim and differ only in which reads it carries. The difference between a
full source and a partial one is precisely *which callbacks it implements*, and
`capabilities/1` plus `function_exported?/3` already expresses that, including the case of a
backend that declares a capability it did not implement.

`Raxol.Web3.Router` already selects candidates **per callback and not per backend**
(`router.ex:116-122`, `answers?/2`), so this decision needs no router change beyond
enumerating the three demoted names in `callbacks/0` so `coverage/2` keeps reporting all
fourteen. A second contract would need the router to know which contract a handle satisfies
before it could ask whether the handle answers a callback, which is a dispatch branch added to
the one module whose whole content is failover classification.

And the coverage matrix's own shape argues against it. Blockscout is a full source for chain 1
and a challenge-gated source for 4663 on the same day, from the same module; a contract
distinction drawn at the module level cannot express that, while a capability declared per
handle already does.

### 3. A callback a chain cannot answer is absent, not empty, and not a new error

An Aztec backend does not declare `token_balances/2`. The router answers
`{:error, {:unsupported, :token_balances}}` and `coverage/2` omits the entry.

No `{:unobservable, _}` variant is added, which was the tempting third option. It would give
the router a third state to classify in the one place a misclassification turns an upstream's
bad minute into a wrong answer, and it would not buy a caller anything: both an
`{:unsupported, _}` and an absent coverage entry are already non-answers, and the property
that matters is that **no gate can read either one as zero**. An empty page is the only shape
that would be dangerous here, and this decision is what makes it unnecessary to return one.

What an operator gets instead of a per-call error is `coverage/2`, which is now load-bearing
rather than informational: it is the only place the served surface's real shape for a chain is
visible, and it already reports the live breaker state rather than a static declaration.

### 4. Chain 4663 gets a routable fallback

`Raxol.Web3.Backend.JSONRPC` is the first partial source: a backend over `Raxol.Web3.RPC`,
answering the three required callbacks plus `account_info/2`, `get_block/2`, `get_logs/3`,
`read_contract/2` and `raw_request/2`, and declining `list_transactions/3`,
`token_balances/2`, `list_token_transfers/3`, `list_nfts/2`, `contract_metadata/2` and
`resolve_name/2`.

Partial is not the same as minimal, and this is the case that shows it: an RPC node answers
`eth_call` and `eth_getLogs`, which are two callbacks a challenge-gated explorer cannot serve
at all, so the fallback is stronger than the primary on part of the surface and much weaker on
the rest. That is the shape `coverage/2` exists to report.

This closes the third of the three live consequences above, and it means ADR-0033's answer for
4663 is a configured RPC URL rather than self-hosting an explorer.

## Consequences

### Positive

- The raw-RPC fallback named in ADR-0033 section 5 becomes expressible, so no EVM row in the
  coverage matrix depends on one vendor, and chain 4663 is routable without self-hosting.
- Aztec can be honest. A structurally unobservable read is an absent capability rather than an
  empty page, which is the one outcome that could have produced a wrong balance decision.
- No second behaviour, no second dispatch path in the router, and no new error variant.
- Three of the fourteen callbacks now have the property that every source answers them, which
  is what makes a health-ordered failover chain meaningful: a chain with two sources has two
  candidates for the three, whatever else differs.

### Negative

- A caller of `account_info/2`, `list_transactions/3` or `token_balances/2` must handle
  `{:error, {:unsupported, _}}`. This was already true of eight of the fourteen callbacks, and
  the MCP and Action surfaces already render it, but it is now true of the three reads a
  caller is most likely to reach for first.
- `coverage/2` moves from informational to load-bearing. An operator who does not consult it
  learns a chain's shape from a stream of per-call errors.
- A backend that simply forgot to declare `account_info/2` is indistinguishable at the
  contract level from a source that cannot answer it.
- The required set is now smaller than the set most chains can answer, so the contract
  understates a full source. `capabilities/1` is what recovers that, and it is a declaration
  rather than a probe.

### Mitigation

- Every backend in the package asserts its own declared capability set in its tests, so a
  forgotten declaration is a red test in the backend that forgot rather than a silent
  degradation at the router. `Raxol.Web3.Backend.Blockscout` continues to declare and answer
  all six of the previously required callbacks, so nothing that was answerable stopped being
  answerable in this change.
- `Raxol.Web3.Router.coverage/2` keeps enumerating all fourteen callbacks, so a demoted
  callback appears there exactly as an optional one always has.
- ADR-0033's section 5 note that a challenge response degrades the served surface is now
  visible in `coverage/2` rather than only in the breaker's state, which is the observability
  gap the adversarial review raised as item 4 of "not asked about".

### What this ADR does not decide

- Whether `capabilities/1` should be computed from a live probe rather than declared. The
  review's "not asked about" item 4 argues for it, and it is a change to how every backend
  reports itself rather than to the required set.
- Which optional callbacks each remaining backend declares. That lands with each backend, as
  ADR-0033 says of the `raw_request/2` allowlist.
- Anything about the `Raxol.Payments.ChainReader` migration in ADR-0033 decision 2's move
  table. `Raxol.Web3.RPC` is still the destination it collapses onto, and
  `Raxol.Web3.Backend.JSONRPC` is a consumer of that module rather than a step in that
  migration.

## Alternatives considered

### Keep six required, and let a partial source lie

Rejected. It is the current state, and it produces an empty `token_balances/2` page on Aztec,
which is the one failure mode in this package that could be read as a fact about money.

### Keep six required, and give a partial source its own behaviour

Rejected in decision 2, on the grounds that the distinction it draws at the module level is
already drawn per handle by `capabilities/1`, and that it adds a dispatch branch to the
router's failover classification.

### Shrink to four, keeping `account_info/2` required

This was the leading candidate until the probe. A raw JSON-RPC node answers `account_info/2`,
so the argument for keeping it was that a source which cannot name an account cannot be asked
anything account-shaped and is barely a source. Two measurements killed it: Aztecscan has no
account resource at all (`l2/accounts` is a 404, 2026-09-14), and SQD Portal's nearest tool
summarizes activity over a look-back window rather than reporting a current balance. Requiring
it would have forced the Solana primary and the Aztec backend to fake exactly the field a
caller would use for a balance decision.

## Validation

The demotions rest on four claims, and each one is reproducible.

```sh
# Aztecscan has no account resource, and its transactions carry no counterparties.
B=https://api.aztecscan.xyz/v1/temporary-api-key
curl -s -o /dev/null -w '%{http_code}\n' "$B/l2/accounts"
curl -s "$B/l2/txs?limit=2" | head -c 400

# SQD Portal is keyless and stateless, and its wallet tool is a look-back summary.
curl -s -X POST -H 'content-type: application/json' \
  -H 'accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  https://portal.sqd.dev/mcp
```

In the suite rather than at a shell:

- Every backend shipped in this package answers the three required callbacks, and the router
  dispatches them whatever `capabilities/1` says.
- A chain whose only source is partial reports the truth through `coverage/2`: the three
  required callbacks plus whatever that source declares, and nothing else.
- `Raxol.Web3.Backend.JSONRPC` answers `account_info/2` from a balance and a code read, and
  declines `list_transactions/3` and `token_balances/2` rather than returning an empty page.
- Chain 4663 routes: a Blockscout primary whose origin is breakered open orders behind a
  JSONRPC fallback for the callbacks both declare, and the fallback answers.

## References

- [ADR-0033](0033-web3-data-surface.md): decision 3, whose required set this amends, and
  section 5's coverage matrix, whose raw-RPC fallback this makes expressible
- [ADR-0038](0038-guarded-outbound-client-evm-rest-backend.md): the outbound client every
  source dials through, and the EVM backend whose declared capabilities grow in this change
- [The upstream survey](../proposals/web3-upstream-survey.md): the chain-side derivation of
  the original six, and the "Unverified" list this decision measures three entries from
- `docs/proposals/web3-client-plan-review.md`: "not asked about" item 4, which reaches the
  same degradation from the observability side
