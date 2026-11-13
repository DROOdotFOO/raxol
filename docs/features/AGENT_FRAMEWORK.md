# Agent Framework

An agent is a TEA module where input comes from LLMs and tools instead of a keyboard. Same `init/update/view` loop, same OTP supervision, same crash isolation. The "user" is an AI model issuing commands and processing results.

For agent payment capabilities (wallets, spending controls, cross-chain transfers), see [Agentic Commerce](AGENTIC_COMMERCE.md).

## Quick start

```elixir
defmodule MyAgent do
  use Raxol.Agent

  def init(_ctx), do: %{findings: []}

  def update({:agent_message, _from, {:analyze, file}}, model) do
    {model, [shell("wc -l #{file}")]}
  end

  def update({:command_result, {:shell_result, %{output: out}}}, model) do
    {%{model | findings: [out | model.findings]}, []}
  end
end

{:ok, _} = Raxol.Agent.Session.start_link(app_module: MyAgent, id: :my_agent)
Raxol.Agent.Session.send_message(:my_agent, {:analyze, "lib/raxol.ex"})
```

## How it works

```elixir
use Raxol.Agent
    |
    v
Agent.Session (GenServer)
    |-- wraps Lifecycle with environment: :agent
    |-- skips terminal driver and plugin manager
    |-- registers in Agent.Registry for discovery
    |
    v
TEA cycle: init/1 -> update/2 -> view/1 (optional)
    |
    v
Commands: async/1, shell/1, send_agent/2
```

`use Raxol.Agent` sets up the standard TEA callbacks (`init/1`, `update/2`, `view/1`, `subscribe/1`) with defaults, and injects three command helpers:

- `async(fun)`: async command with a sender callback
- `shell(command, opts \\ [])`: shell command via Port
- `send_agent(target_id, message)`: message another agent

All callbacks are overridable. `view/1` defaults to `nil`, which means no rendering. Useful for headless agents that only process messages.

## Agent session

`Raxol.Agent.Session` is the GenServer hosting a single agent. It wraps `Lifecycle` with `environment: :agent`, which skips the terminal driver and plugin manager.

```elixir
# Start an agent
{:ok, _pid} = Raxol.Agent.Session.start_link(
  id: :code_reviewer,
  app_module: CodeReviewAgent
)

# Send a message (async, arrives as {:agent_message, from, payload} in
# update/2; from is the sender's id when attributed with the :from option,
# nil otherwise -- the framework never guesses a sender)
:ok = Raxol.Agent.Session.send_message(:code_reviewer, {:review, "lib/app.ex"})

# Read the agent's current model
{:ok, model} = Raxol.Agent.Session.get_model(:code_reviewer)

# Read the agent's rendered view tree
{:ok, tree} = Raxol.Agent.Session.get_view_tree(:code_reviewer)
```

Agents auto-register in `Raxol.Agent.Registry` by their `:id`. If the agent is dead, lookups return `{:error, :not_found}`.

## Communication

`Raxol.Agent.Comm` has three messaging primitives:

```elixir
alias Raxol.Agent.Comm

# Fire and forget. Pass from: to identify yourself; without it the
# target sees from = nil (attribution is caller-asserted, not verified).
:ok = Comm.send(:target_agent, {:task, data}, from: :my_agent)
# Arrives in target's update/2 as {:agent_message, :my_agent, {:task, data}}

# Synchronous call with timeout. The target must answer with
# Comm.reply(caller, ref, response) from its update/2:
#   def update({:agent_message, _from, {:call, caller, ref, q}}, model) do
#     Comm.reply(caller, ref, answer(q, model))
#     {model, []}
#   end
{:ok, reply} = Comm.call(:target_agent, {:query, params}, 5_000)

# Broadcast to every agent in a team (delivery filtered by the receiving
# session's team_id)
:ok = Comm.broadcast_team(:my_team, {:status_update, status})
# Arrives in each teammate's update/2 as
# {:agent_message, nil, {:team_broadcast, :my_team, {:status_update, status}}}
```

### Agent turn contract

A prompt is one turn: `Comm.call(agent, {:acp_prompt, text, approver}, timeout)` returns
`{:ok, {:ok, text, usage}}`. `approver` is an arity-3 `:tool_authorizer` (see
`Raxol.Agent.ToolPolicy`) that every tool call of the turn must pass. The timeout is required
(`:infinity` for none): a timeout cancels the turn, so `Comm.call/2` refuses a prompt with
`{:error, :timeout_required}` without sending it. The session stands in as the caller:
`update/2` sees the prompt with the session's pid and the session's own ref for the turn (never
the caller's ref, which can cancel the turn but not answer it, run its work or message its
process), and answers inline with `Comm.reply/3`, or with `Comm.run_turn/3` for work that blocks.
`{:acp_cancel, ref}` stops the turn's process and answers the prompt `{:error, :cancelled}`: the
process gets an exit signal with reason `:shutdown`, which a turn that traps exits can use to
release what it started, and is killed if it is still alive after
`config :raxol_agent, :turn_cancel_grace_ms` (default 500). Sent with `Comm.call/3`, the
cancel's `:ok` arrives only after that process is dead. Pass `ref: ref` to
`Comm.call/4` to know the ref; it must be a fresh `make_ref/0`, used for one call only. A
prompt is also cancelled when its caller goes down or its `Comm.call/4` times out. Whenever a
turn ends without its reply (cancelled, or its process crashed or was killed), `update/2`
receives `{:acp_cancel, ref}` with its own ref for the turn, so the agent drops what it tracks
for the turn in one place. An inline reply while the turn's process runs stops that process
first, and `update/2` receives the cancel too. The session does not check a reply's shape: what
the agent replies reaches the caller as is. The session intercepts the prompt and both cancel
forms, with or without `:from`; an `{:acp_cancel, x}` naming no in-flight turn is swallowed.

An agent consults `approver`, and runs the actions it gates, in the `Comm.run_turn/3` process,
never inline in `update/2`: an inline ask would block the whole agent until it is answered, and
a cancel stops only the turn's process, so inline work is neither stopped nor undone. A turn
process that changes agent state sends the change to the agent process (`self()` in
`update/2`) as `{:command_result, msg}`, which `update/2` receives. `{:error, :cancelled}` does
not roll back such a change: one already sent when the cancel arrives is still applied.

The session journals each prompt turn under a turn id of its own: `turn_started`, then one of
`turn_completed`, `turn_canceled` or `error`.

Other answers to a prompt: `{:error, :invalid_prompt}` (`text` not a binary or `approver` not
arity 3), `{:error, :duplicate_ref}` (the ref already names an in-flight turn),
`{:error, :no_dispatcher}` (the agent is not running), `{:error, :turn_failed}` (the turn's
process crashed or was killed from outside), `{:error, :agent_down}` (a standalone session's
agent went down mid-turn) and `{:error, :cancelled}`. A cancel sent with
`Comm.call/3` answers `:ok` or `{:error, :not_found}` (no in-flight turn has that ref).
`Raxol.Agent.Reference.Counter` is the reference agent (`increment`, `get`, sensitive
`reset`, `hold` until `release` or a cancel); it applies a change only from a turn it still
tracks (the turn's ref is the only credential).

## Teams

`Raxol.Agent.Team` is an OTP Supervisor for agent groups:

```elixir
{:ok, _} = Raxol.Agent.Team.start_link(
  team_id: :review_team,
  coordinator: {ReviewCoordinator, [id: :coordinator]},
  workers: [
    {FileAnalyzer, [id: :analyzer_1]},
    {FileAnalyzer, [id: :analyzer_2]}
  ],
  strategy: :rest_for_one
)
```

Coordinator starts first. With `:rest_for_one`, a coordinator crash restarts all workers. Workers crash independently.

## Command types

Commands returned from `update/2` are processed by Lifecycle:

| Command    | Helper                        | Result in update/2                                                   |
| ---------- | ----------------------------- | -------------------------------------------------------------------- |
| Async      | `async(fn sender -> ... end)` | `{:command_result, {:async_result, value}}`                          |
| Shell      | `shell("ls -la")`             | `{:command_result, {:shell_result, %{output: ..., exit_status: ...}}}` |
| Send Agent | `send_agent(:target, msg)`    | Delivered to target as `{:agent_message, from, msg}`                 |

## Headless agents

When `view/1` returns `nil` (the default), no rendering happens. The agent is a pure message-processing loop, good for background workers, data pipelines, or agents that only talk to other agents.

## AI backend streaming

`Raxol.Agent.Backend.HTTP` does real SSE streaming to LLM providers:

```elixir
{:ok, stream} = Raxol.Agent.Backend.HTTP.stream(
  [%{role: "user", content: "Explain OTP"}],
  api_key: System.get_env("ANTHROPIC_API_KEY"),
  provider: :anthropic,
  model: "claude-sonnet-4-20250514"
)

# Stream elements:
# {:chunk, "text delta"}
# {:done, %{content: full_text, usage: %{...}}}
# {:error, "message"}
```

Supports Anthropic, OpenAI, Ollama, Proton's Lumo, Kimi 2.5/moonshot, OpenRouter, Meituan's LongCat, and DeepSeek.
Provider is auto-detected from `:base_url` or set via `:provider`.

Without an explicit `:provider`, detection matches the `:base_url`: `anthropic` picks Anthropic, `ollama` (or the default Ollama port) picks Ollama, `moonshot` picks Kimi, and anything else is treated as OpenAI-compatible. The `FREE_AI=true` / `AI_API_KEY` backend switch is a convention of the example agents under `examples/agents/`, not the `Backend.HTTP` layer.

The `:openrouter` harness (via `Backend.Selector`) targets OpenRouter, an OpenAI-compatible aggregator. It attaches app-attribution headers (HTTP-Referer, X-OpenRouter-Title, X-OpenRouter-Categories) so Raxol's usage appears on openrouter.ai/rankings. Pass the key via `ExecutorConfig` `auth: %{api_key: ...}`.

The `:longcat` harness targets Meituan's LongCat (`https://api.longcat.chat/openai`, model `LongCat-2.0`), also OpenAI-compatible. It rides the `:openai` request/SSE path, which already handles LongCat's non-standard frames (a full `message` chunk instead of `delta`, the `reasoning_content` channel, and the underscore-less `finishreason` key). Pass the key via `ExecutorConfig` `auth: %{api_key: ...}`.

The `:deepseek` harness targets DeepSeek's OpenAI-compatible endpoint (`https://api.deepseek.com`, default model `deepseek-v4-flash`, key from `DEEPSEEK_API_KEY`).

## Turn loop

`Raxol.Agent.Backend.HTTP` streams one model call. `Raxol.Agent.Stream.react/2` drives a
whole turn: the model sees the tools in `:actions`, each call it makes is run, and the loop
continues until it answers in text or `:max_iterations` is reached.

```elixir
{:ok, result} =
  "refactor lib/foo.ex"
  |> Raxol.Agent.Stream.react(
    backend: MyBackend,
    actions: MyAgent.available_actions()
  )
  |> Raxol.Agent.Stream.collect()
```

- `:context` is a map handed to every tool call. An agent with a skills provider passes
  `context: %{skills: Raxol.Agent.Skills.provider_context(provider)}`, which is where the
  skill tools find their store.
- The result is a lazy stream of events; `collect/1` drains it to `{:ok, info}`, whose
  `:messages` is the conversation the loop built.

## Backends

`Raxol.Agent.ExecutorConfig` (`%{harness, model, auth, opts}`) plus
`Raxol.Agent.Backend.Selector.select/1` map a harness atom to a backend:

| Harness | Backend |
|---------|---------|
| `:anthropic`, `:openai`, `:kimi`, `:ollama`, `:lm_studio`, `:llm7`, `:longcat`, `:deepseek`, `:openrouter` | `Backend.HTTP` |
| `:lumo` | `Backend.Lumo` |
| `:mock` | `Backend.Mock` |

`Raxol.Agent.Backend.Catalog` is the single declaration this table, the resolver's provider
registry and `ExecutorConfig.backend()` are all derived from (`Catalog.ids/0` lists every
backend). `select/1` returns `{:error, {:unknown_backend, harness}}` for a harness the
catalog does not declare.

### Credentials

`Raxol.Agent.Backend.Resolver.resolve/1` turns the environment into an `ExecutorConfig`.
`Raxol.Agent.Stream` calls it when given `auto_provider: true` and no `:executor`.

- **A named provider** (`harness:` to the resolver, `provider:` to `Stream`). Its key is the
  first of: the `:api_key` option; a 1Password reference, read with the `op` CLI, from the
  store or from `RAXOL_<HARNESS>_OP`; the provider's environment variable
  (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, ...). With none of them the result is
  `{:no_key, harness}`. `:ollama`, `:lm_studio`, `:llm7` and `:mock` need no key.
- **No provider named.** The resolver walks the catalog in order and takes the first provider
  with a stored reference or an environment key, or a keyless one with an entry in the store.
  Providers billed in API credits (`:anthropic`, `:openai`, `:kimi`, `:openrouter`,
  `:longcat`, `:deepseek`) and the generic `AI_API_KEY` / `AI_BASE_URL` / `AI_MODEL` endpoint
  are skipped unless `RAXOL_ALLOW_PAID_API` is `1`, `true`, `TRUE` or `yes`. With nothing
  found the result is `:no_provider`, and `Stream` answers from its `:backend` option, by
  default `Backend.Mock`.

The store is `~/.raxol/providers.json`, or the file `$RAXOL_PROVIDERS` names. It maps a
provider to an `op://` reference and an optional model and base URL, never to a key, and is
written with mode `0600`. A store the account does not own, or that its group or others may
write, is refused with a logged warning, and resolution continues with environment variables.

```elixir
Raxol.Agent.Setup.connect_ref(:anthropic, %{op_ref: "op://Vault/Item/api_key"})
Raxol.Agent.Setup.remove(:anthropic)
```

`connect_ref/3` stores a reference and reports whether it authorizes. `connect_key/3` first
puts a raw key into a new 1Password item. `remove/1` deletes a provider's entry. `status/0`
is what `raxol doctor` prints under `providers`.

## Authorization (ALLOW/ASK/DENY)

`Raxol.Agent.Authorization` is a three-way policy engine.

- `Engine` is a pure reducer over a list of policies. It folds with `reduce_while`: a DENY
  short-circuits, an ALLOW merges whitelisted label writes, an ASK escrows writes and
  accumulates a prompt. Final precedence is deny > ask > allow.
- `Policy` is a data struct (`phases`, `conditions`, `writable_labels`, `scope`). Scope is
  `:once`, `:session`, or `:root`; a remembered ASK auto-allows within its scope, so
  "approve once covers the tree" works.

A host calls `Engine.evaluate/4` itself and holds the engine state; `raxol_broker` does for
its order policy. The LLM tool-call path does not consult it. There a `sensitive` action is
denied unless the context of the call carries a `:tool_authorizer` (`Raxol.Agent.ToolPolicy`).

## Conversation item-log

`Raxol.Agent.Conversation` is an append-only item log. Nothing records a turn into it:
a caller appends, and a `raxol_gateway` session started with
`log: {Raxol.Agent.Conversation.Log, server}` appends each inbound event and each
delivered reply.

- `Item` is an immutable typed entry (message, tool_call, tool_result, reasoning, error, and
  more) with a stable id `"<conversation_id>:<seq>"` and a monotonic, store-assigned seq.
- `Store` is a behaviour with cursor pagination (`:after`/`:before`/`:limit`/`:order`/`:type`);
  `Store.ETS` is the shipped adapter (an `ordered_set` keyed `{conversation_id, seq}`). Append
  is the only writer.
- `Log` is a GenServer that wraps a store (durability) with in-process subscriber fan-out
  (liveness) and no replay buffer. `subscribe/3` returns the snapshot and registers the
  subscriber in one serialized call, so the snapshot and the live tail partition exactly:
  every item once, no gap, no duplicate. Reconnect with an `:after` cursor.

## Examples

```bash
FREE_AI=true mix run examples/agents/zero_system.exs  # ZERO System cockpit w/ live LLM reasoning
# framework primitives run from the package (they need Raxol.Agent):
cd packages/raxol_agent && mix run examples/agents/react_agent.exs  # Actions + ReAct + tools + shell
cd packages/raxol_agent && mix run examples/agents/agent_team.exs   # coordinator + workers
```
