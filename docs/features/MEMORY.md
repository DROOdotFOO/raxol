# Memory

Three opt-in layers on one provider contract: a stack that composes several memory providers
at once, full-text recall over raw conversation history, and a dialectic user model derived
in the background. All of it composes through the single `Raxol.Agent.Memory` behaviour, so
the rest of the framework sees one provider that happens to be a composite.

The default store is pure Elixir with no SQLite and no NIF: a BM25-lite inverted index in
concurrent-read ETS, with the durable records mirrored to DETS and every secondary index
rebuilt on boot.

## The provider contract

`Raxol.Agent.Memory` is the behaviour every provider implements:

| Callback | Purpose | Required? |
|----------|---------|:---:|
| `search/2` | Recall curated records for a query | Yes |
| `store/2` | Persist a record | Yes |
| `forget/2` | Delete a record by id | Yes |
| `prefetch/2` | Records to prime the turn (defaults to `search`) | No |
| `build_system_prompt/1` | System-prompt memory block | No |
| `build_user_context/1` | Per-user block, injected into the last user message | No |

`build_user_context/1` is injected into the **last user message** rather than the system
prompt, on purpose: refreshing it per turn does not invalidate the cacheable system prefix.

## Enabling it

Two callbacks, singular or stacked (default off):

```elixir
defmodule MyAgent do
  use Raxol.Agent

  # Stack the built-in ETS store alongside an external semantic provider.
  # A non-empty memory_providers/0 takes precedence over memory_provider/0.
  def memory_providers do
    [Raxol.Agent.Memory.Store.Ets, {MyApp.SemanticMemory, index: "prod"}]
  end
end
```

Setting either callback auto-exposes the `memory_remember` / `memory_recall` / `memory_forget`
tools. The user model and session search are caller-supplied instances, wired through
[`Raxol.Agent.Turn`](AGENT_FRAMEWORK.md#turn-driver):

```elixir
Raxol.Agent.Turn.run(MyAgent, prompt,
  backend: MyBackend,
  log: log_server,
  conversation_id: cid,
  agent_id: "my-agent",
  user_id: "user-123",
  user_model: MyApp.UserModel,        # enables the user-context block + async refresh
  session_search: MyApp.SessionSearch # enables the session_search tool + post-turn indexing
)
```

## Provider stack

`Raxol.Agent.Memory.Stack` composes N providers behind the one contract. `store` and `forget`
fan out to every provider; `search` queries all of them, normalizes each provider's results
into a `[0, 1]` rank (its top hit is 1.0, scaling down by position), merges, dedups by
content, and takes the limit. A provider that raises or exits is caught and degrades to no
results rather than breaking the stack.

Where Hermes keeps its built-in layer plus exactly one external provider, the stack composes
the built-in store with as many external providers as you configure, and re-ranks across all
of them.

## Session search

`Raxol.Agent.Memory.SessionSearch` answers "what did we say about X three sessions ago." It
is a full-text inverted index over raw conversation-item text (BM25-lite, k1 1.2 / b 0.75, no
recency or tag weighting), distinct from semantic memory:

- `attach(server, log, conversation_id)` subscribes to a [Conversation
  Log](AGENT_FRAMEWORK.md#conversation-item-log), indexes the snapshot, then indexes every
  appended item live.
- The `session_search` tool returns **raw** matching items (id, conversation, seq, type,
  content), not summaries. Summarization is a provider concern, not a search concern.
- The default backend is the ETS index. A `SessionSearch.Sqlite` FTS5 adapter is available
  for deployments that outgrow it.

This contrasts with a single-process embedded database file: the index lives in
concurrent-read ETS and is fed live by a pub/sub subscription to the conversation log.

## Dialectic user model

`Raxol.Agent.UserModel` is a native, OTP-shaped version of dialectic user modeling: a derived
representation of the user (preferences, goals, habits) keyed by `user_id`, reasoned out on a
cheap auxiliary model.

- `refresh_async/4` derives in a spawned `Task` off the GenServer, so the foreground turn
  never blocks on the model call. `refresh/4` is the synchronous variant for explicit use.
  The Turn driver refreshes asynchronously after each turn.
- `build_user_context/1` returns the derived block, which `Memory.Manager` appends to the
  last user message. Keeping it out of the system prompt preserves the cacheable prefix while
  still refreshing per turn.

This is a deliberate improvement over injecting the dialectic into the system prompt (which
forces a frozen snapshot to keep the cache warm): here the user block refreshes every turn
and the cached prefix stays intact.

## Recall ranking

The default `Raxol.Agent.Memory.Store.Ets` scores `relevance + recency + tag_bonus`:

- **relevance**: length-normalized BM25-lite (k1 1.2, b 0.75).
- **recency**: `0.3 * exp(-age_days / 30)`.
- **tag_bonus**: `0.5 * |record.tags intersect query_tags|`.

An empty query degrades to most-recent-N. Every secondary index (tokens, tags, agent, doc
frequencies) is rebuilt from the durable records on open, so no stale index can survive a
restart.

## Tools

| Tool | Input | Returns |
|------|-------|---------|
| `memory_remember` | `content`, `type`, `tags` | `id`, `stored` |
| `memory_recall` | `query`, `limit` | curated record summaries |
| `memory_forget` | `id` | `forgotten: true` |
| `session_search` | `query`, `limit`, `conversation_id` | raw conversation items |

`memory_recall` returns curated facts the agent chose to keep; `session_search` returns raw
past messages. They are different questions with different answers.

## See also

- [Self-Improvement](SELF_IMPROVEMENT.md): the after-turn reviewer that writes facts into
  memory.
- [Agent Framework](AGENT_FRAMEWORK.md): the Turn driver and the Conversation item-log that
  session search indexes.
