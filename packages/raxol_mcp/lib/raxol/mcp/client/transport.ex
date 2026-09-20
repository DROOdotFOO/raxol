defmodule Raxol.MCP.Client.Transport do
  @moduledoc """
  The seam between `Raxol.MCP.Client`'s one session machine and a wire.

  ADR-0037 decision 1. Before it, the client was a JSON-RPC session machine
  welded to a port: the config, the connect, the write, the read and the
  teardown each assumed stdio, and roughly 60 of 395 lines were the part that
  could not reach a URL. Everything else -- `pending`, `next_id`, `status`, the
  tool cache and every `handle_result/3` branch -- is transport-independent and
  stays in the client. A transport owns connection, framing and delivery, and
  nothing else.

  ## Why `send/3` carries the id and returns a handle

  An HTTP request is a round trip, not a write. A transport has to associate a
  response with the request that caused it, and it has to be able to fail ONE
  in-flight request without failing the connection, which is the
  `{:failed, id, reason, handle}` arm of `decode_info/2`.

  A stdio transport ignores the id on the way out: one pipe carries every
  request and the id only matters on the way back.

  `{:notify, id}` is a notification: encoded with no JSON-RPC id, because
  nothing answers one, and reported under `id` all the same. It is still a
  request in flight -- one POST on the session -- so the client holds an
  entry for it and the transport says when it is done. A bare `nil` id is
  the same notification with nothing tracking it, which no in-tree caller
  uses any more.

  ## Why `cancel/2` exists

  The client's own `call_timeout` can expire while the transport is still
  working: an HTTP exchange's wall time is the dial plus the read deadline
  plus a chunk overshoot, which together exceed the default 30 s. The entry
  leaves `pending` at that point, so without `cancel/2` the next queued
  request is admitted BESIDE a task that is still holding a socket -- two
  concurrent requests on a `:serialized` session. `cancel/2` drops the work
  for one id and returns the handle; for a transport with nothing to cancel
  it is the identity.

  ## Why the request is a map rather than `iodata()`

  ADR-0037 decision 1 specifies `send(handle, id, iodata())`, and decision 2's
  own table then requires `Mcp-Method` and `Mcp-Name` headers on every
  modern-era post. A transport handed opaque iodata cannot set either header
  without re-parsing the body it was just given, so the third argument is the
  request as `%{method:, params:}` (plus an optional `:reservation`) and
  encoding belongs to the transport, which is also where framing already lives.
  One encoder per framing, not one encoder plus one parser.

  ## Why `session/1` exists

  A modern-era origin is specified not to answer `initialize`, and a legacy one
  requires it. The client cannot know which without asking, and it must know
  before it sends anything: offering a handshake to a modern server leaves the
  client in `:initializing` forever. `session/1` is answered after `connect/1`
  and reports the negotiated session profile: whether to handshake, the
  protocol revision in force for this connection, and the concurrency policy
  the origin's era implies (ADR-0037 decision 6). A spec that declares
  `:concurrency` overrides the last of those.

  ## Why `decode_info/2` has `:closed` and `:settled` arms

  ADR-0037 lists three returns. A fourth is forced by the code the same
  decision requires to keep working unchanged: `{:exit_status, code}` fails
  EVERY pending entry and marks the session closed (`client.ex:236-244` before
  this change), which neither `{:messages, _, _}` nor a single-id
  `{:failed, id, _, _}` can express. A fifth, `{:settled, id, handle}`, is
  what a notification's completion is: a request that finished with nothing
  to deliver, whose in-flight slot must still be released. `:ignore`
  preserves the catch-all clause that was at `client.ex:246`.
  """

  @typedoc "Opaque per-connection transport state, threaded back through every call."
  @type handle :: term()

  @typedoc "Concurrency policy for one origin (ADR-0037 decision 6)."
  @type concurrency :: :stateless | :pooled | :serialized

  @typedoc """
  One outbound JSON-RPC message.

  `:reservation` is the spend-gate handle for a priced tool call. Its ABSENCE
  on a priced tool is what `Transport.Http` refuses; its value is opaque here.
  """
  @type request :: %{
          required(:method) => String.t(),
          required(:params) => map(),
          optional(:reservation) => term()
        }

  @typedoc "The negotiated session profile, answered once after `connect/1`."
  @type session ::
          {:handshake | :ready, %{version: String.t(), concurrency: concurrency()}}

  @callback connect(config :: map()) :: {:ok, handle()} | {:error, term()}
  @callback session(handle()) :: session()
  @callback send(handle(), pos_integer() | nil | {:notify, pos_integer()}, request()) ::
              {:ok, handle()} | {:error, term()}
  @callback cancel(handle(), pos_integer() | {:notify, pos_integer()}) :: handle()
  @callback close(handle()) :: :ok
  @callback decode_info(handle(), message :: term()) ::
              {:messages, [binary()], handle()}
              | {:failed, pos_integer(), term(), handle()}
              | {:settled, pos_integer(), handle()}
              | {:closed, term(), handle()}
              | :ignore

  @http_transport Raxol.MCP.Client.Transport.Http
  @http_exchange Raxol.MCP.Client.Transport.Http.Exchange
  @http_read Raxol.MCP.BoundedExchange
  @stdio_transport Raxol.MCP.Client.Transport.Stdio

  @doc """
  Whether a spec of this provenance may reach `target` -- the URL a remote
  spec dials, or the command a stdio spec spawns.

  A spec carries `:source` (`:user` when absent: a spec assembled in code is
  the operator's own program) and, for anything else, a `:permit` function of
  arity one that answers `:ok` or an error for that target. The rule the
  function enforces is not this package's to know: `Raxol.Agent.McpHosts`
  owns it, because the allowlist it reads is an operator file in `~/.raxol`
  and `.mcp.json` is parsed one layer up.

  This is asked INSIDE each `connect/1`, not only by the caller that built
  the spec. `Raxol.Agent.McpBundle` asks first, for the operator-facing
  refusal; a future caller that maps a workspace spec straight to
  `Raxol.MCP.Client.start_link/1` gets the check anyway, because the socket
  and the subprocess are here.

  A refusal is `{:blocked, :source}` whatever the gate said. The gate's own
  reason names the host or the command, which this package's closed error
  taxonomy does not carry, and the caller that supplied the gate has already
  logged it.
  """
  @spec permit(map(), term()) :: :ok | {:error, {:blocked, :source}}
  def permit(config, target) do
    case {Map.get(config, :source, :user), Map.get(config, :permit)} do
      {:user, _no_gate_needed} -> :ok
      {_untrusted, gate} when is_function(gate, 1) -> collapse(gate.(target))
      {_untrusted, _ungated} -> {:error, {:blocked, :source}}
    end
  end

  defp collapse(:ok), do: :ok
  defp collapse({:error, _refused}), do: {:error, {:blocked, :source}}

  @doc """
  Pick the transport a spec asks for: `:command` XOR `:url`.

  Both keys, or neither, is `{:error, {:invalid_spec, spec}}` rather than a
  silent preference for one. A remote spec in a build without `mint` is
  `{:error, :no_http_client}`, which `Raxol.Agent.McpBundle.load/2` already
  handles as a per-server fail-open skip.

  The refused spec is echoed back with its header VALUES replaced, because a
  spec carries resolved credentials and an error term is one of the four places
  ADR-0033 section 7 names as where they leak.
  """
  @spec select(map() | keyword()) :: {:ok, module(), map()} | {:error, term()}
  def select(spec) do
    config = normalize(spec)

    case {Map.get(config, :command), Map.get(config, :url)} do
      {command, nil} when is_binary(command) and command != "" ->
        {:ok, @stdio_transport, config}

      {nil, url} when is_binary(url) and url != "" ->
        http(config)

      _both_or_neither ->
        {:error, {:invalid_spec, redact(config)}}
    end
  end

  defp http(config) do
    # Every module behind the guard, not just the transport. A stale `_build`
    # can carry `Transport.Http.beam` without `Transport.Http.Exchange.beam` or
    # `BoundedExchange.beam`, since all three sit behind a compile-time
    # `Code.ensure_loaded?(Mint.HTTP)` and an incremental compile can predate
    # any of them. Checking only the first turns that into an
    # `UndefinedFunctionError` on the first request instead of the fail-open
    # skip this error exists for.
    if Enum.all?([@http_transport, @http_exchange, @http_read], &Code.ensure_loaded?/1),
      do: {:ok, @http_transport, config},
      else: {:error, :no_http_client}
  end

  @doc """
  A spec with every header value replaced by `"[redacted]"`.

  Public because the client reports refused specs too, and one redaction is
  better than two.
  """
  @spec redact(map()) :: map()
  def redact(%{headers: headers} = config) when is_list(headers) do
    %{config | headers: Enum.map(headers, fn {name, _value} -> {name, "[redacted]"} end)}
  end

  def redact(%{headers: headers} = config) when is_map(headers) do
    %{config | headers: Map.new(headers, fn {name, _value} -> {name, "[redacted]"} end)}
  end

  def redact(config), do: config

  # A spec is a map or a keyword list, and both arrive: `.mcp.json` parses to a
  # map and every in-tree caller writes a keyword list.
  defp normalize(spec) when is_map(spec), do: spec

  defp normalize(spec) when is_list(spec) do
    if Keyword.keyword?(spec), do: Map.new(spec), else: %{}
  end

  defp normalize(_other), do: %{}
end
