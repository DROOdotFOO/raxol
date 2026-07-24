# Unified Messaging Gateway

One daemon that connects many chat platforms through a shared contract. Each platform is an
adapter that owns only its own I/O and translation; routing, per-chat sessions, pairing,
authorization, and history all live in the gateway. A chat becomes an OTP process, so
platform fan-out is supervision rather than a single-process message queue.

The package (`raxol_gateway`, pre-alpha `0.1.0`) depends on `raxol_core`, with `raxol_agent`
optional (used only to record turns to a durable conversation log). It has no auto-started
tree: you wire the supervisor yourself.

## The adapter contract

`Raxol.Gateway.Adapter` is the five-callback behaviour every platform implements:

| Callback | Purpose |
|----------|---------|
| `connect/1` | Open a platform connection, return a `conn` handle |
| `disconnect/1` | Close it |
| `platform/0` | The platform atom |
| `normalize_event/1` | Translate a raw platform event to `{:ok, Route.t(), event}` or `:ignore` |
| `send_message/3` | Send a rendered reply to a route |

The contract is frozen (ADR-0023): additions must be optional callbacks, and existing
callbacks do not change shape.

`Raxol.Gateway.Adapter.InMemory` is a reference adapter (platform `:in_memory`) that forwards
outbound messages to a sink pid; it drives the full inbound to outbound path in tests.

## Agent-backed handler

`Raxol.Gateway.Handler.Agent` turns any chat into an agent conversation: each inbound
`%{text: text}` event runs one synchronous turn through `Raxol.Agent.Stream` and replies
with the collected answer. It requires the optional `raxol_agent` dependency.

```elixir
Raxol.Gateway.Supervisor.start_link(
  handler:
    {Raxol.Gateway.Handler.Agent,
     [
       system_prompt: "You are a helpful assistant.",
       # No backend pinned: auto_provider resolves credentials from the
       # environment (1Password ref -> provider env vars -> AI_API_KEY).
       agent_opts: []
     ]},
  adapter: {MyAdapter, conn}
)
```

Per-chat history is kept in the handler state (capped by `:max_history`, default 40
messages) and, when the session has a `:log`, also recorded to the conversation log. A
failed turn logs the full reason and replies with a short error message. Turns run
synchronously inside the per-chat session process, so set `:idle_timeout` comfortably
above the longest expected turn.

## Routing and sessions

`Raxol.Gateway.Route` (`platform`, `chat_type`, `chat_id`, optional `user_id`) identifies a
chat. `Route.key/1` forms the stable session key:

```
agent:main:{platform}:{chat_type}:{chat_id}
```

`Raxol.Gateway.SessionRouter` (a `BaseManager` GenServer) starts one `Raxol.Gateway.Session`
process per chat under a `DynamicSupervisor`, keyed by that string, with an idle timeout
(default 10 minutes), a per-key start cooldown (default 5 seconds), and a max-session bound
(default 1000). Sessions run a `Raxol.Gateway.Handler` (a two-callback behaviour: `init/2`
and `handle_event/2`). Each inbound event and each reply can be recorded to an optional log
keyed by a stable `conversation_id`.

## Pairing and authorization

`Raxol.Gateway.Pairing` issues 8-character DM pairing codes (from an unambiguous alphabet,
1-hour TTL, per-user request cooldown, global lockout after repeated failed confirms) and
decides `authorize/2` in this order:

1. the platform is configured to allow everyone, else
2. the user is paired, else
3. the user is in the platform allowlist, else
4. the user is in the global allowlist, else
5. deny.

## Delivery

`Raxol.Gateway.Delivery.deliver/3` resolves four outbound destinations:

- `{:direct, route}`: reply to the originating chat.
- `{:home, route}`: a configured home channel (cron or background results).
- `{:cross_platform, route}`: a different platform's chat.
- `{:target, "platform:chat_id"}`: an explicit target string. The platform is matched against
  connected adapters by string comparison, never turned into an atom from input.

## Handoff

`SessionRouter.handoff(server, from_key, to_route)` rebinds a conversation to another
platform's route, carrying the source session's `conversation_id` and the router's log. Since
the log is keyed by `conversation_id`, history follows the conversation across platforms.

## Supervision

`Raxol.Gateway.Supervisor` ties it together with `:rest_for_one`, so the router (which
references the sessions supervisor) restarts if that supervisor dies:

```elixir
defmodule EchoHandler do
  @behaviour Raxol.Gateway.Handler
  def init(_route, _opts), do: {:ok, %{}}
  def handle_event(%{text: t}, state), do: {:reply, "echo: #{t}", state}
end

{:ok, conn} = Raxol.Gateway.Adapter.InMemory.connect(%{sink: self()})

{:ok, _sup} =
  Raxol.Gateway.Supervisor.start_link(
    handler: {EchoHandler, []},
    deliver: fn route, rendered ->
      Raxol.Gateway.Adapter.InMemory.send_message(conn, route, rendered)
    end
  )

route = Raxol.Gateway.Route.new(%{platform: :in_memory, chat_type: :dm, chat_id: "42"})
:ok = Raxol.Gateway.SessionRouter.route(Raxol.Gateway.SessionRouter, route, %{text: "hi"})
# => receives {:gateway_sent, route, "echo: hi"}
```

## Status

The gateway core (adapter contract, routing, sessions, pairing, delivery, handoff) is
complete, the adapter contract is frozen, and `Handler.Agent` (agent-backed conversations)
ships. Still deferred: concrete platform adapters (Telegram, Discord, and so on; only
`Adapter.InMemory` ships today) and a `Lifecycle`-backed handler that runs a full TEA app
under `environment: :gateway`. Any module satisfying the two `Handler` callbacks works in
the meantime. See `docs/adr/0023-unified-messaging-gateway.md`.

## See also

- [Telegram](TELEGRAM.md), [Watch](WATCH.md), [Speech](SPEECH.md): the existing per-surface
  bridges the gateway generalizes.
- [Agent Framework](AGENT_FRAMEWORK.md): the Conversation log that carries per-chat history.
