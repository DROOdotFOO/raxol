defmodule Raxol.MCP.Client.Era do
  @moduledoc """
  Which protocol era an origin speaks, and what counts as evidence for it.

  ADR-0037 decision 2. The current specification (2026-07-28) removed
  `initialize`, `notifications/initialized` and `Mcp-Session-Id`, and made
  `server/discover` mandatory for servers. The hosted servers ADR-0033
  measured on 2026-08-31 are all stateful. A client that assumes either era
  fails against the other, so the era is probed per origin and cached.

  | | Modern (2026-07-28) | Legacy (2025-06-18 and earlier) |
  | --- | --- | --- |
  | Handshake | none | `initialize` then `notifications/initialized` |
  | Capabilities | `server/discover` | the `initialize` result |
  | Session | none | optional `Mcp-Session-Id`, echoed on every request |
  | Required headers | `Mcp-Method`, `Mcp-Name` | `MCP-Protocol-Version` |

  ## A refusal is not an era

  `evidence/1` is the whole demotion rule and it is deliberately narrow. An
  origin is demoted to legacy ONLY by a method-not-found for `server/discover`
  or by HTTP 404, 405 or 501. A 401, 403, 408, 429 or 5xx is health
  information: it feeds `Raxol.MCP.CircuitBreaker` and leaves the verdict
  untouched.

  That distinction is the difference between a transient upstream refusal and a
  permanently wedged backend. A 403 challenge is not hypothetical on these
  upstreams -- ADR-0038's probe reproduces one on a live Blockscout instance --
  and treating it as era evidence would cache `legacy` forever, after which
  every call sends an `initialize` that a modern server is specified not to
  answer.

  ## The key carries the path

  A gateway can serve several MCP endpoints under one origin, so a per-origin
  key would hand all of them one era. The key is `{origin, path}`, and the
  value is `{era, decided_at}` with a TTL, so a wrong verdict expires on its
  own rather than waiting for a specific invalidating response.

  The table is owned by `Raxol.MCP.Client.Tables`, not created here.
  `:ets.new/2` tables are owned by the process that creates them
  (`circuit_breaker.ex:31-33`), so a table created by a client would make the
  verdict per client and defeat the point of caching it at all.
  """

  @type era :: :modern | :legacy
  @type key :: {String.t(), String.t()}
  @type evidence :: :demote | :health | :none

  # A guess, not a measurement: no upstream publishes how often it changes
  # protocol revision. Fifteen minutes is short enough that a server upgraded
  # mid-session is picked up within one coffee break and long enough that a
  # busy client is not probing on every call. Override per spec with
  # `:era_ttl_ms`, or globally with `config :raxol_mcp, :client_era, ttl_ms:`.
  @default_ttl_ms 900_000

  # 400 is in this list on evidence measured on 2026-09-14, not on principle.
  # Both stateful upstreams answer a `server/discover` probe with a 400: one
  # with `{"code":-32601,"message":"Session ID required in mcp-session-id
  # header"}`, the other with a framework stack trace carrying no code at all.
  # Both are unambiguously legacy -- they issue `Mcp-Session-Id` and negotiate
  # 2025-06-18 -- so a rule that left 400 as no evidence made both of them
  # permanently unreachable.
  #
  # It belongs with 404/405/501 rather than with the health statuses because a
  # 400 to a fixed request is DETERMINISTIC: the same probe gets the same
  # answer, so it cannot be the transient refusal the health list exists to
  # tolerate. A verdict taken from it and wrong expires on the TTL; a legacy
  # origin never classified is wrong until someone edits this list.
  @demoting_statuses [400, 404, 405, 501]
  @unhealthy_statuses [401, 403, 408, 429]

  @doc """
  The cached verdict for a key, or `:miss` when absent or expired.

  An expired row is deleted on the read that finds it, so a key probed once and
  never again costs one row rather than one row forever.
  """
  @spec verdict(:ets.table(), key(), keyword()) :: {:ok, era()} | :miss
  def verdict(table, key, opts \\ []) do
    case :ets.lookup(table, key) do
      [{^key, era, decided_at}] ->
        if now_ms() - decided_at < ttl_ms(opts) do
          {:ok, era}
        else
          :ets.delete(table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @doc "Cache a verdict, stamped with the time it was decided."
  @spec remember(:ets.table(), key(), era()) :: :ok
  def remember(table, key, era) when era in [:modern, :legacy] do
    :ets.insert(table, {key, era, now_ms()})
    :ok
  end

  @doc """
  Drop a verdict.

  Used by the one invalidation that is not a TTL: a session-rejected response
  re-probes exactly once, then fails.
  """
  @spec forget(:ets.table(), key()) :: :ok
  def forget(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc """
  The cache key for a target URL.

  The query string is NOT part of the key, and the userinfo and fragment are
  not either: an MCP endpoint is identified by where it is, and a per-account
  URL can carry a credential in any of the three.
  """
  @spec key(URI.t()) :: key()
  def key(%URI{} = uri), do: {origin(uri), uri.path || "/"}

  @doc """
  An opaque, stable origin string: scheme, host and port.

  Used as the cache key's first element and as the circuit-breaker key, and
  never as an error term: a per-account URL names the account.
  """
  @spec origin(URI.t()) :: String.t()
  def origin(%URI{scheme: scheme, host: host, port: port}) do
    "#{scheme}://#{host}:#{port}"
  end

  @doc """
  What a probe response says about the era.

    * `:demote` - this origin does not implement `server/discover`, so it is
      legacy. A JSON-RPC method-not-found for that call, wherever it is
      carried, or HTTP 400, 404, 405 or 501.
    * `:health` - the origin refused us. Breaker input, not era input.
    * `:none` - no era information either way.

  A JSON-RPC code is the more specific of the two, so a caller holding both
  asks about the code first: one measured upstream carries `-32601` inside a
  400, and the code says what the status only implies.
  """
  @spec evidence({:status, non_neg_integer()} | {:jsonrpc_error, integer()} | term()) ::
          evidence()
  def evidence({:status, status}) when status in @demoting_statuses, do: :demote
  def evidence({:status, status}) when status in @unhealthy_statuses, do: :health
  def evidence({:status, status}) when status >= 500, do: :health
  def evidence({:status, _status}), do: :none

  def evidence({:jsonrpc_error, code}) do
    if code == Raxol.MCP.Protocol.method_not_found(), do: :demote, else: :none
  end

  def evidence(_other), do: :none

  @doc "Whether a response status records a circuit-breaker failure."
  @spec unhealthy?(non_neg_integer()) :: boolean()
  def unhealthy?(status), do: status in @unhealthy_statuses or status >= 500

  @doc "The verdict TTL in milliseconds: per-call option, then app config, then the default."
  @spec ttl_ms(keyword()) :: pos_integer()
  def ttl_ms(opts \\ []) do
    Keyword.get_lazy(opts, :ttl_ms, fn ->
      Application.get_env(:raxol_mcp, :client_era, [])[:ttl_ms] || @default_ttl_ms
    end)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
