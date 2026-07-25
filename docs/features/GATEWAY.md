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

Shipping adapters:

| Adapter | Platform | Package |
|---------|----------|---------|
| `Raxol.Gateway.Adapter.InMemory` | `:in_memory` (reference; sink pid) | raxol_gateway |
| `Raxol.Telegram.GatewayAdapter` | `:telegram` (text messages, chunked plain-text sends) | raxol_telegram |
| `Raxol.Gateway.Adapter.Discord` | `:discord` (MESSAGE_CREATE text, chunked plain-text sends) | raxol_gateway |

A full Telegram wiring pairs the adapter with `Raxol.Telegram.UpdatePoller` (getUpdates
long polling) feeding `normalize_event/1` into the router:

```elixir
{:ok, conn} = Raxol.Telegram.GatewayAdapter.connect(bot_token: token)

Raxol.Gateway.Supervisor.start_link(
  handler: {Raxol.Gateway.Handler.Agent, [system_prompt: "..."]},
  adapter: {Raxol.Telegram.GatewayAdapter, conn}
)

Raxol.Telegram.UpdatePoller.start_link(
  conn: conn,
  on_update: fn raw ->
    # Authorize BEFORE routing: the adapter is a pure translator and checks
    # nothing, and Handler.Agent runs a paid backend call per text event.
    with {:ok, route, event} <- Raxol.Telegram.GatewayAdapter.normalize_event(raw),
         :allow <- Raxol.Gateway.Pairing.authorize(Raxol.Gateway.Pairing, route) do
      case Raxol.Gateway.SessionRouter.route(Raxol.Gateway.SessionRouter, route, event) do
        :ok -> :ok
        # Log rejects (rate limit, max sessions): the poller advances its
        # offset regardless, so a silent drop is permanent loss.
        {:error, reason} -> Logger.warning("update rejected: #{inspect(reason)}")
      end
    else
      :ignore -> :ok
      :deny -> :ok
    end
  end
)
```

The Discord wiring is the same shape with the roles renamed: the feed is
`Raxol.Gateway.Adapter.Discord.GatewaySocket` (one Gateway v10 WebSocket with
client heartbeats, identify/resume, and exponential reconnect; requires the
optional `mint_web_socket` dependency), whose `:on_event` passes raw dispatch
frames through `Raxol.Gateway.Adapter.Discord.normalize_event/1`. Replies go
out over REST (`POST /channels/:id/messages`, optional `req` dependency),
chunked at Discord's 2000 code points. Guild messages route as
`chat_type: :guild`, DMs as `:dm`; bot-authored messages never normalize, so
two agents cannot loop each other. Note the MESSAGE_CONTENT intent is
privileged: enable it in the Discord developer portal or guild message
content arrives empty.

```elixir
{:ok, conn} = Raxol.Gateway.Adapter.Discord.connect(bot_token: token)

Raxol.Gateway.Supervisor.start_link(
  handler: {Raxol.Gateway.Handler.Agent, [system_prompt: "..."]},
  adapter: {Raxol.Gateway.Adapter.Discord, conn}
)

Raxol.Gateway.Adapter.Discord.GatewaySocket.start_link(
  token: token,
  on_event: fn frame ->
    with {:ok, route, event} <- Raxol.Gateway.Adapter.Discord.normalize_event(frame),
         :allow <- Raxol.Gateway.Pairing.authorize(Raxol.Gateway.Pairing, route) do
      case Raxol.Gateway.SessionRouter.route(Raxol.Gateway.SessionRouter, route, event) do
        :ok -> :ok
        {:error, reason} -> Logger.warning("dispatch rejected: #{inspect(reason)}")
      end
    else
      :ignore -> :ok
      :deny -> :ok
    end
  end
)
```

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

## Voice notes

`Raxol.Gateway.Pipeline.Transcribe` is a feed-loop stage that turns a voice media event
(`%{media: %{kind: :voice, ref: ..., ...}}`, what `Raxol.Telegram.GatewayAdapter` emits
for `message.voice` updates) into the ordinary `%{text: transcript}` event before it is
routed. It runs in the feed loop rather than the session so the conversation log records
the transcript (a session logs each inbound event before its handler runs) and so STT
never blocks a per-chat mailbox. Non-voice events pass through untouched.

```elixir
{:ok, conn} = Raxol.Telegram.GatewayAdapter.connect(bot_token: token)

Raxol.Telegram.UpdatePoller.start_link(
  conn: conn,
  on_update: fn raw ->
    with {:ok, route, event} <- Raxol.Telegram.GatewayAdapter.normalize_event(raw),
         :allow <- Raxol.Gateway.Pairing.authorize(Raxol.Gateway.Pairing, route),
         {:ok, event} <-
           Raxol.Gateway.Pipeline.Transcribe.run(event,
             fetch_fn: fn media -> Raxol.Telegram.GatewayAdapter.fetch_media(conn, media) end
           ) do
      case Raxol.Gateway.SessionRouter.route(Raxol.Gateway.SessionRouter, route, event) do
        :ok -> :ok
        # Log rejects: the poller advances its offset regardless, so a
        # silent drop is permanent loss.
        {:error, reason} -> Logger.warning("update rejected: #{inspect(reason)}")
      end
    else
      :ignore -> :ok
      :deny -> :ok
    end
  end
)
```

The three stages are injectable functions: `:fetch_fn` (platform download, here
`fetch_media/2` = Bot API `getFile` + file GET), `:convert_fn` (default: ffmpeg via a
temporary file, `-f f32le -ac 1 -ar 16000`, executable allowlisted), and `:recognize_fn`
(default: `Raxol.Speech.Recognizer.recognize/1` from the optional `raxol_speech`
dependency). The stage fails open per event: any failure (STT missing, download or
conversion error, empty transcript) drops that one voice note with a warning and
`[:raxol_gateway, :transcribe, :error]` telemetry; text traffic is never affected. Audio
bytes and transcripts stay out of the logs, as does the download URL (it embeds the bot
token).

Mind the cold start: the first recognition after boot pays the XLA graph compile, which
can take minutes on CPU. Give the Recognizer a generous `:recognize_timeout_ms` (via
`Raxol.Speech.Supervisor`'s `:recognizer_opts`) or warm it up front, otherwise every
cold call times out, aborts the compile, and the next call starts over.

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
complete, the adapter contract is frozen, `Handler.Agent` (agent-backed conversations)
ships, and two platforms sit behind the frozen contract: Telegram
(`Raxol.Telegram.GatewayAdapter` + `Raxol.Telegram.UpdatePoller`; text and voice notes -
keyboards, callbacks, and other media are still the TEA surface's domain) and Discord
(`Raxol.Gateway.Adapter.Discord` + its `GatewaySocket`; text-only this slice). Voice
notes transcribe through `Raxol.Gateway.Pipeline.Transcribe`. Still deferred: an Email
adapter, and a `Lifecycle`-backed handler that runs a full TEA app under
`environment: :gateway`. Any module satisfying the two `Handler` callbacks works in the
meantime. See `docs/adr/0023-unified-messaging-gateway.md`.

## See also

- [Telegram](TELEGRAM.md), [Watch](WATCH.md), [Speech](SPEECH.md): the existing per-surface
  bridges the gateway generalizes.
- [Agent Framework](AGENT_FRAMEWORK.md): the Conversation log that carries per-chat history.
