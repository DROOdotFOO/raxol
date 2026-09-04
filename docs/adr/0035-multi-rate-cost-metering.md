# ADR-0035: Cost metering for multi-rate providers

## Status

Proposed, 2026-09-04. Nothing is implemented; this records the metering model before a provider
whose prices do not fit the current one is added.

Written against DeepSeek as the forcing case, but the model it breaks was already straining:
two of the three collision hazards below are live today on OpenRouter and LLM7, and Anthropic's
own cached-read tier is mispriced by the same mechanism.

Pairs with ADR-0034, which handles the foreign-agent half of the same integration work.

Revised 2026-09-04, after a measurement against a real ACP peer confirmed that a foreign agent
reports per-turn cost in USD on the wire. That strengthens the provider-reported-cost decision
below from an anticipated case to an observed one; nothing else in the model changed.

## Context

`Raxol.Agent.LlmPrices.@prices` (`llm_prices.ex:19-33`) is a flat list of
`{prefix, usd_per_mtok_in, usd_per_mtok_out}` triples, matched longest-prefix-wins, with a
`strip_vendor/1` retry (`:77-82`) for OpenRouter's `vendor/model` form. It encodes one
assumption: **a model name determines a price.**

That held while every hosted provider billed a flat per-token rate. It no longer does.

### Gap 1: $0.00 is not a bug in the spend gate, it is the spend gate

The metering path in `Raxol.Agent.Code.App` reads, at `:1065-1083`:

```elixir
defp flag_unpriced(%{ledger: nil} = model, _usage, _billed, _cost), do: model
defp flag_unpriced(%{spending_policy: nil} = model, _usage, _billed, _cost), do: model

defp flag_unpriced(model, usage, billed, cost) do
  if cost == 0.0 and billed_tokens?(usage) do
    %{model | unpriced_model: billed || "(unnamed)"}
```

feeding `enforce_budget/1` (`:1100-1102`), which halts the turn. `CostLedger.record/4` guards
on `cost_usd > 0.0` (`cost_ledger.ex:34`), so a zero cost is a no-op on the ledger, and
`flag_unpriced/4` is what notices that a real turn burned real tokens for zero recorded
dollars. The comment above it says so directly: a budget is only a budget if every paid round
can be priced.

This inverts the obvious framing of "what price should DeepSeek get":

> **Adding any row to the price table disarms a safety mechanism.** Before the row, a DeepSeek
> turn under a ledger halts with a notice naming both remedies. After it, the turn proceeds
> silently at whatever number was typed. That trades a guaranteed-correct halt for a guess, and
> the guess had better only ever err upward.

The direction of error follows immediately. Under-metering is unbounded real spend against a
budget that never trips. Over-metering trips a budget early and inconveniences someone. Over-meter.

Two properties of the guard belong in any design that touches it. It is armed only when a
ledger **and** a spending policy are both wired (`:1072-1075`), so a local single-user session
gets neither the protection nor an estimate. And it halts the **next** turn, not the current
one, because the billed model is only knowable from a response (`:1069`).

The practical consequence for a new provider: on the hosted multi-tenant coding agent, which
wires a ledger through `RAXOL_SSH_CODE_BUDGET_USD`, an unpriced model halts every turn after
the first. Prices are not optional polish there; without them the provider does not function.

### Gap 2: DeepSeek's price has two dimensions the table cannot express

Published rates, USD per million tokens, verified 2026-09-04:

| Model | input, cache hit | input, cache miss | output |
| ----- | ---------------- | ----------------- | ------ |
| `deepseek-v4-pro` | 0.022 / 0.044 | 0.66 / 1.32 | 1.98 / 3.96 |
| `deepseek-v4-flash` | 0.007 / 0.014 | 0.22 / 0.44 | 0.66 / 1.32 |
| `deepseek-v4-flash-vision-exp` | 0.007 / 0.014 | 0.22 / 0.44 | 0.66 / 1.32 |

Each cell is off-peak / peak. Two dimensions, neither derivable from a model name:

- **Cache tier.** A cache hit costs roughly 1/31 of a miss on input. The split is knowable only
  from the response.
- **Clock.** Peak is 01:00 to 04:00 and 06:00 to 10:00 UTC (Beijing business hours); off-peak is
  half. Derivable from a UTC clock, with no timezone database and no DST.

A third dimension is not a price at all but defeats name-based matching just as thoroughly:
DeepSeek's Anthropic-compatible endpoint maps `claude-opus*` to `deepseek-v4-pro` and
`claude-sonnet*` / `claude-haiku*` to `deepseek-v4-flash`. In that mode the name the caller
supplies and the model that bills are different things.

These rates took effect 2026-08-16 and were an increase, not a relabel: `deepseek-v4-pro`
output went from a flat 0.87 to 3.96 at peak. This is the most volatile row anyone would add to
`@prices`, and that volatility is an argument about where the number should come from, not just
about how often to check it.

### Gap 3: a naive DeepSeek row breaks two backends that have nothing to do with DeepSeek

`@prices` is vendor-agnostic while `rates/2` accepts a `backend` argument it explicitly ignores
(`llm_prices.ex:42`). Adding a global `deepseek-v4-*` row therefore prices every serving of
that name identically:

| Hazard | Mechanism | Effect |
| ------ | --------- | ------ |
| OpenRouter | `strip_vendor/1` turns `deepseek/deepseek-v4-pro` into `deepseek-v4-pro` | Marked-up OpenRouter traffic priced at DeepSeek's direct rate, with no peak dimension. Under-bills. |
| LLM7 | `selector.ex:33-38` records that LLM7 hosts `deepseek-v4-flash`; LLM7 is `billing: :free` | Meters free tokens as paid, burning a real budget on nothing |
| Anthropic-compat | `claude-sonnet-*` served by `deepseek-v4-flash` matches the `claude-sonnet` row at 3.0 / 15.0 | Over-meters by roughly 7 to 11 times, and `/usage` displays it as fact |

The first two are the serious ones, because both paths return `:unknown` today and therefore
**fail closed**. A global row converts them to fail-open at the wrong vendor's rate. A change
made to price DeepSeek would silently weaken the budget on two backends nobody was thinking
about.

### Gap 4: the seam for this was reserved and never used

`llm_prices.ex:40-49`:

```elixir
@spec rates(atom() | nil, String.t() | nil) :: {:ok, {float(), float()}} | :unknown
def rates(_backend, model) when is_binary(model) do
```

The moduledoc at `:36-38` calls the backend argument "accepted for future disambiguation".
Gap 3 is that future: all three hazards say the same thing, which is that the model name is no
longer sufficient and the serving backend is the missing discriminator.

### Gap 5: no cache tier is read anywhere, so Anthropic is already mispriced

Nothing in raxol reads `prompt_cache_hit_tokens`, `cache_read_input_tokens`, or
`cache_creation_input_tokens`. `BenchmarkProfile.add_usage/2` (`benchmark_profile.ex:114-134`)
collapses usage to `%{input_tokens, output_tokens}` and `cost_usd/2` (`:141-147`) is a two-rate
linear function, so the split is destroyed before pricing even happens.

Anthropic bills cached reads at a fraction of full input rate and raxol prices them at full
rate. This is an existing over-meter on the most-used backend, in the safe direction, and
invisible.

The split also arrives on the ACP wire, not only from a REST provider, so this is not a
DeepSeek-shaped problem wearing a general disguise. A probed turn against Oh My Pi's ACP
surface reported:

```json
{"inputTokens": 1997, "outputTokens": 52, "totalTokens": 46081,
 "cachedReadTokens": 44032}
```

Note what a name-and-two-rates model does with that: 44,032 of 46,081 tokens were cached
reads, so pricing `inputTokens` alone under-bills by more than an order of magnitude, while
pricing `totalTokens` at the full input rate over-bills by roughly twenty times. Neither is
close, and the correct figure is computable only because the agent reported the split. This is
the same shape as DeepSeek's `prompt_cache_hit_tokens`, reached through a different transport,
which is the argument for putting the fix in the pricing seam rather than in a provider row.

## Decision

### Compose four strategies rather than choose one

```
observed usage carries a cache split?
  yes -> price it exactly, using the UTC peak clock
  no  -> price the conservative worst case: peak rates, every input token a cache miss
model and backend pair absent from the scoped table?
      -> :unknown, fail closed
```

Every branch errs the same direction, which is the property that matters for a fail-closed
mechanism. Exact when the wire says so, conservative when it does not, refusing when it knows
nothing.

The fallback branch is load-bearing rather than theoretical. Three real paths land there:
streaming turns whose trailing usage frame is empty, resumed sessions whose journal payloads
are string-keyed and may predate the field, and the Anthropic-compat surface, which emits no
cache fields at all.

### Scope prices by backend, in a table consulted before the flat one

Add a backend-scoped table and leave `@prices`, `match_prefix/1`, `strip_vendor/1` and `rates/2`
untouched, so every existing caller and every existing assertion keeps working. Resolution
order inside the new entry point: the scoped table by longest prefix, then `rates/2` treated as
hit rate equal to miss rate.

Scoping is what closes Gap 3. `rates(:openrouter, "deepseek/deepseek-v4-pro")` and
`rates(:llm7, "deepseek-v4-flash")` keep returning `:unknown`, which is to say they keep failing
closed, because a DeepSeek row is declared to apply to the `:deepseek` backend rather than to a
name.

The table must record what it cannot know as well as what it can. DeepSeek's own page says peak
hours are Monday through Friday and does not state unambiguously whether a weekend hour inside
a peak window is peak or off-peak. Treat every weekend hour as peak: that over-bills a weekend
turn by two times, and an unresolved ambiguity in a spend gate points upward.

### The new entry point

```elixir
@spec turn_cost_usd(atom() | nil, String.t() | nil, map(), DateTime.t()) ::
        {:ok, float()} | :unknown
def turn_cost_usd(backend, model, usage, now \\ DateTime.utc_now())
```

It takes the provider-raw usage map, before `add_usage/2` collapses it, and an injectable clock
so the module stays pure and testable. `parse_response` passes usage through untouched
(`http.ex:706`, `:723`, `:746`, `:775`), so the fields survive to the call site.

At the call site, `code/app.ex:1129-1143` currently collapses usage and then prices it. Reorder
to price first and collapse only on the fallback path. `RAXOL_COST_PER_MTOK_IN/OUT` still win
outright: an operator who states a rate is not second-guessed by a table.

Return `0.0` on `:unknown`. That is not a shrug, it is the signal `flag_unpriced/4` reads, and
changing it would break the gate described in Gap 1.

`enforce_budget`, `flag_unpriced`, `CostLedger` and `BenchmarkProfile` stay unchanged.
`add_usage/2` keeps its two-field shape, because the env-rate path and `raxol.p`'s
`RAXOL_MAX_COST_USD` are flat by construction: a benchmark harness that states its own rates
does not want a cache model imposed on it.

### Prefer a provider's own reported cost where it exists

`usage["cost"]` is currently a dead key: `Harness.GrokBuild` stamps it from `total_cost_usd`
(`grok_build.ex:98-107`) and nothing reads it.

This is not a hypothetical second source. Driving Oh My Pi's ACP surface with
`scripts/acp_probe.py` returned a `usage_update` frame carrying money directly:

```json
{"sessionUpdate": "usage_update", "size": 272000, "used": 22974,
 "cost": {"amount": 0.11544, "currency": "USD"}}
```

That is `Schema.UsageUpdate`'s shape exactly (`schema/session_update.ex:491-561`), and
`Schema.Cost` already models `%{amount, currency}`. So a foreign agent hosted over ACP reports
authoritative per-turn dollars for a model raxol may know nothing about, priced by whoever is
actually billing. No table can compete with that, and no table needs to.

A provider-reported cost should therefore be preferred over any table, ranking below the env
rates and above the scoped table. This is what turns an unpriced-model halt into a real charge
for exactly the cases a table cannot cover, and it retroactively activates a value grok has
been reporting all along.

Two cautions to carry into the implementation. Currency must never be coerced: map to
`cost_usd` only when `currency == "USD"` and keep the pair verbatim otherwise, because a
silently-converted figure in a spend gate is the failure this ADR exists to prevent. And a
reported cost is the counterparty's claim, not an invoice; it is right to prefer it over a
guess and wrong to treat it as audited.

### Ship a new provider unpriced first, deliberately

The integration commit that adds DeepSeek should leave it unpriced, with the choice stated in
the commit message and the docs so it reads as a decision rather than an omission. Under a
ledger and policy it then fails closed with the existing notice, which names both remedies;
without one it degrades to today's best-effort estimate.

The point of the separate step is that at no moment between adding the provider and adding the
pricing mechanism is the halt disarmed by a guess.

### What not to do

- **Do not add a short `"deepseek"` prefix to `@prices`.** `llm_prices.ex:74-76` records that no
  row may be shorter than `"gpt-4o"` or `strip_vendor/1`'s collision-safety argument fails. A
  bare `"deepseek"` would also swallow OpenRouter's vendor prefix on the un-stripped first pass.
- **Do not price `deepseek-chat` or `deepseek-reasoner`.** Both were announced retired after
  2026-07-24 and were observed still routing days later, which makes them aliases that may
  silently reroute. Leaving an alias unpriced means it fails closed, which is the correct
  treatment for a name whose target is not stable.
- **Do not put `max_tokens` in a `Selector.@backend_table` entry.** `build_request/3` reads
  `Keyword.get(opts, :max_tokens, default_max_tokens())` (`http.ex:620`) and
  `default_max_tokens/0` (`:68-78`) is what honours `AI_MAX_TOKENS`. Because `Selector.select/1`
  merges table defaults into opts (`selector.ex:100`), a table `max_tokens` would make that env
  override permanently inert for that backend, since `Keyword.get/3` never evaluates its default
  when the key is present. No existing entry sets it. A reasoning model may well need more than
  the 4,096 default, which `http.ex:37-41` already anticipates, but the fix belongs in
  `default_max_tokens/0` becoming provider-aware.
- **Do not add a second harness for an Anthropic-compatible endpoint.** It is reachable with
  `base_url` plus `provider: :anthropic` and no code, but it buys nothing: raxol's
  `build_request(:anthropic, ...)` sends only model, max_tokens, messages, optional system and
  optional tools, so every feature such an endpoint drops is one raxol never sends. It is also
  strictly less capable, since the Anthropic path has no `extra_headers` support, and it
  actively creates the Gap 3 hazard by design. Document the configuration, do not register it.

## Alternatives considered

**Price the conservative worst case and stop there.** One triple per model, flat shape
preserved, errs upward.

Rejected as the whole answer, kept as the fallback branch. A representative coding turn of 40k
input tokens (35k of them cached), 1.5k output, off-peak, costs about $0.0023 in reality and
about $0.0196 priced at peak and all-miss: **8.4 times over**, and 4.2 times over at peak. That
turns a $10 budget into an effective $1.20. Safe, and it presents a number to the user through
`/usage` that is wrong by nearly an order of magnitude. It also does nothing about Gap 3.

**Extend the price row to a struct carrying cache and peak fields.** More expressive table,
same shape of lookup.

Rejected. It solves the clock, which is the easy half, and cannot solve the cache tier, which is
knowable only from a response. So it pays the full cost (a changed return type rippling into
`table_profile/2`, a clock threaded into a module that is currently pure, the same session
priced differently minute to minute) and still needs a conservative cache assumption on top. Its
UTC clock is worth keeping as an input to the chosen design; as a standalone answer it is the
worst ratio of cost to benefit in this list.

**Leave the provider unpriced permanently and require `RAXOL_COST_PER_MTOK_IN/OUT`.**

Rejected as an end state, adopted as the starting state. It is the only option that preserves
the fail-closed guarantee unconditionally, and it ships in zero lines, which is why the
integration commit uses it. But it makes `/usage` read "unknown model" indefinitely, and the
halt only fires when both a ledger and a policy are wired, so the default single-user
configuration gets neither protection nor estimate.

**Meter tokens instead of dollars.** Symphony already does this: `Sandboxes.BudgetCap`'s only
shipped `cost_fn` is `tokens_from_usage/1`.

Rejected for the agent path. A token proxy cannot express that a cache hit costs 1/31 of a
miss, or that the same call costs double at 02:00 UTC, which are precisely the facts this ADR
exists to handle. It stays reasonable for Symphony until a runner reports real dollars, which
ADR-0034 notes pi would be the first to do.

## Consequences

### What becomes possible

A provider whose price depends on the response rather than only on the request can be metered
accurately, which is the class DeepSeek belongs to and is not alone in.

The two latent fail-open regressions in Gap 3 are closed before they are opened, and the
`backend` argument reserved in `rates/2` starts carrying its stated meaning.

Anthropic's cached-read tier becomes correctable through the same seam, which is where the
mechanism pays for itself: it is not DeepSeek-specific machinery.

A provider-reported cost becomes usable, activating a value `Harness.GrokBuild` already reports
and unblocking accurate metering for models no static table can cover.

### What costs we accept

Two pricing paths exist where one did. `rates/2` stays for callers that have only a name, and
`turn_cost_usd/4` is preferred wherever the raw usage map is still in hand. A caller that
reaches for the wrong one gets a less accurate answer rather than a wrong-direction one, which
is the tolerable failure, but it is still two functions to choose between.

The scoped table encodes a vendor's published rates, and those rates move. DeepSeek's moved 355%
on one row three weeks before this was written. A comment recording the verification date and
the volatility is the mitigation, and it is a weak one: nothing makes a stale row fail loudly.
Preferring a provider-reported cost is the real answer wherever a provider offers one.

Pricing from observed usage means the same prompt can cost different amounts on consecutive
runs, because cache state changes. That is accurate, and it will look like a bug in a
reproducibility-minded test. Tests should assert against injected usage maps and an injected
clock, never against a live call.

### What this ADR does not decide

- **Whether the peak clock covers weekends.** Documented as unresolved and resolved
  conservatively; a definitive upstream answer should replace the assumption, not the mechanism.
- **How `/usage` displays a cache split.** Showing "input: 40000 (35000 cached)" is cosmetic and
  can come last or never.
- **Whether `default_max_tokens/0` becomes provider-aware.** Named as the right place for the
  reasoning-model token budget, deliberately out of scope here.
- **Whether Symphony's `BudgetCap` adopts dollars.** It becomes possible once a runner reports
  them; the migration is ADR-0034's business.
- **Anything about which provider ships when.** This is the metering model, not a roadmap.

## Validation

The tests an implementation must produce.

- **Exact pricing from a cache split**: a usage map carrying hit and miss token counts prices to
  the hit rate and the miss rate respectively, not to a blend.
- **Conservative fallback**: the same turn with the split absent prices at peak rates with every
  input token a miss, and the result is strictly greater than the exact figure.
- **Peak boundaries** at 01:00, 04:00, 06:00 and 10:00 UTC, and a Saturday 02:00 UTC hour priced
  as peak, pinning the documented ambiguity so a later change to it is deliberate.
- **The Gap 3 regressions, as explicit assertions**:
  `rates(:openrouter, "deepseek/deepseek-v4-pro")` and `rates(:llm7, "deepseek-v4-flash")` must
  **still** return `:unknown`. These are the tests that prove scoping did its job, and they
  would pass today for the wrong reason, so they must be written against the new table.
- **Every existing `llm_prices_test.exs` assertion unchanged**, which is the check that the flat
  table was genuinely left alone.
- **A live gate** on the pattern of `longcat_live_test.exs`: `@moduletag :live_deepseek`, body
  compiled only when the key is present, registered in the exclude list at
  `packages/raxol_agent/test/test_helper.exs`. Its one load-bearing assertion is that
  `prompt_cache_hit_tokens` and `prompt_cache_miss_tokens` are present and sum to
  `prompt_tokens`. That is the single fact the entire design rests on, it is unverifiable
  offline, and it is exactly what a live gate is for.
- **A fail-closed test**: a model absent from both tables, under a wired ledger and policy,
  halts the following turn rather than proceeding at $0.00.

## References

- ADR-0034: foreign coding-agent seams, the other half of this integration work, and the source
  of the provider-reported-cost case
- ADR-0020: `Raxol.Agent.Sandbox`, for the policy layer a spend gate sits beside
- `packages/raxol_agent/lib/raxol/agent/llm_prices.ex`: the flat table, the reserved `backend`
  argument at `:42`, and the short-prefix warning at `:70-76`
- `packages/raxol_agent/lib/raxol/agent/code/app.ex:1038-1171`: the metering path, the
  fail-closed guard, and the call site that reorders
- `packages/raxol_agent/lib/raxol/agent/code/cost_ledger.ex:34`: the positive-cost guard
- `packages/raxol_agent/lib/raxol/agent/benchmark_profile.ex:114-147`: where the cache split is
  currently destroyed
- `packages/raxol_agent/lib/raxol/agent/backend/http.ex:36-42`, `:620`, `:965-992`: the token
  default, the `max_tokens` trap, and the `reasoning_content` channel already handled
- `packages/raxol_agent/lib/raxol/agent/backend/selector.ex:33-38`: LLM7 hosting DeepSeek names
- `packages/raxol_agent/lib/raxol/agent/harness/grok_build.ex:98-107`: the dead `usage["cost"]`
- `docs/features/CODING_AGENT.md:416-423`: the fail-closed behaviour as currently documented
- `packages/raxol_agent_client_protocol/lib/raxol/agent_client_protocol/schema/session_update.ex:491-616`:
  `UsageUpdate` and `Cost`, the wire shape a foreign agent reports cost in
- `scripts/acp_probe.py`: used to observe a real `usage_update` frame carrying USD
- `api-docs.deepseek.com`: rates and the cache-token fields, verified 2026-09-04
