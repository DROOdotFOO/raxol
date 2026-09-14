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
