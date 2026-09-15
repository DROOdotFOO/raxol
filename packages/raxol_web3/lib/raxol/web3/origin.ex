defmodule Raxol.Web3.Origin do
  @moduledoc """
  An opaque, stable id for an outbound origin.

  Every error term this package returns names an origin by id rather than by
  host. ADR-0038 decision 6's fourth rule is why: the host can itself be the
  secret, because a bring-your-own-upstream deployment is handed per-account
  URLs and an account is named in the hostname. An error tuple travels further
  than a credential should: into a log line, a telemetry measurement, and on an
  MCP surface into text the model reads.

  The id is a truncated SHA-256 of the canonical origin, so it is stable across
  nodes and restarts (which is what makes it usable as a bucket and breaker
  key) and one-way. `resolve/1` answers from a node-local table, so an operator
  on the box can turn an id back into a host while the id in an error term
  carries nothing.

  The canonical origin is `scheme://host:port`, with the port always explicit.
  A path is deliberately excluded: rate limits and health belong to the origin,
  not to one of its endpoints, and including a path would mint a bucket per URL
  and spend the upstream's budget N times.

  ## The table only grows with configuration

  `id/1` inserts on every call and nothing ever deletes a row, which reads
  like a leak and is not one, because the set of origins is closed by
  construction. A row's key is a hash of `scheme://host:port`, and every host
  that reaches here comes from a backend handle's state, which comes from that
  backend's `new/2` at configuration time: the shipped endpoint tables hold
  fourteen hosts between them, plus whatever `:url`, `:rpc_url` or `:host` an
  operator overrides. Nothing that crosses the served surface reaches
  `Raxol.Web3.HTTP`'s `url` argument — an MCP tool argument names a chain, not
  an endpoint, and `Raxol.Web3.HTTP` documents its whole option list as
  package-internal. So the row count is the number of distinct upstreams this
  node is configured to talk to, and a row is a sixteen-character id beside a
  short origin string: tens of rows, single-digit kilobytes.

  Capping it would also be the wrong trade, which is the other half of the
  answer. An id travels into log lines, telemetry and stored error terms that
  outlive the request by weeks, and this table is the only thing that turns
  one back into a host. Evicting a row breaks `resolve/1` for exactly the old
  id an operator is investigating, so the table is deliberately
  append-only and bounded by configuration rather than by a ceiling.
  """

  alias Raxol.Web3.Tables

  @id_bytes 8

  @type id :: String.t()

  @doc """
  The id for a URI, registering it for `resolve/1`.

  Idempotent: the same origin always produces the same id, and registering it
  again overwrites an identical row.
  """
  @spec id(URI.t()) :: id()
  def id(%URI{} = uri) do
    origin = canonical(uri)
    id = hash(origin)
    :ets.insert(Tables.origins(), {id, origin})
    id
  end

  @doc "The origin behind an id, from this node's table."
  @spec resolve(id()) :: {:ok, String.t()} | :error
  def resolve(id) when is_binary(id) do
    case :ets.lookup(Tables.origins(), id) do
      [{^id, origin}] -> {:ok, origin}
      [] -> :error
    end
  end

  @doc "The canonical `scheme://host:port` form, with the port always explicit."
  @spec canonical(URI.t()) :: String.t()
  def canonical(%URI{scheme: scheme, host: host, port: port}) do
    "#{scheme}://#{host}:#{port}"
  end

  defp hash(origin) do
    :crypto.hash(:sha256, origin)
    |> binary_part(0, @id_bytes)
    |> Base.encode16(case: :lower)
  end
end
