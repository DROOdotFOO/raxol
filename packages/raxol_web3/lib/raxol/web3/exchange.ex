defmodule Raxol.Web3.Exchange do
  @moduledoc """
  One request and one bounded response on a dialled connection.

  This is ADR-0038 decision 4, and the loop itself is
  `Raxol.MCP.BoundedExchange`: the send, the four bounds, the accumulator and
  the close, in one place rather than two. The remote MCP transport needs the
  identical loop, and the two copies this package used to carry were identical
  down to the error taxonomy, so there was nothing to choose between them.
  `raxol_web3` depends on `raxol_mcp` outright (ADR-0033 decision 2), so the
  shared module sits on the side of the graph both callers can reach; the
  reasoning for each bound is in that module's docs.

  What stays here is what differs: `Raxol.Web3.Dial` opens the connection this
  is handed, and `Raxol.Web3.HTTP` owns the vet, the budget, the health record
  and the mapping of a refusal into this package's error taxonomy. The bounds
  reach the loop as options, so a caller that wants a smaller ceiling still
  passes `:max_bytes` here.

  ## Truncation is never a success

  The accumulator is `Raxol.Core.Outbound.Response`, which starts
  `:incomplete` and is promoted to `:complete` only by the terminating
  response, so `run/3` cannot return `{:ok, _}` for anything but a complete
  read. That matters for this package in particular: every halt-based reader in
  this ecosystem returns success on abort, and an accumulator whose initial
  value looks like a success turns a refused oversized response into an empty
  200, which for `list_transactions/3` is indistinguishable from an address
  with no transactions.

  ## The connection

  Always closed, on every path, by the shared loop. There is no pool
  (ADR-0038 decision 3), so a connection outlives nothing and leaving one open
  would leak a socket per request rather than save a handshake.
  """

  alias Raxol.MCP.BoundedExchange

  @type request :: BoundedExchange.request()

  @type response :: BoundedExchange.response()

  @type reason :: BoundedExchange.reason()

  @doc """
  Send `request` on `conn` and read the response under the four bounds.

  The connection is closed before returning, whatever the outcome.

  Options: `:max_bytes`, `:deadline_ms`, `:chunk_timeout_ms`.
  """
  @spec run(Mint.HTTP.t(), request(), keyword()) :: {:ok, response()} | {:error, reason()}
  def run(conn, request, opts \\ []), do: BoundedExchange.run(conn, request, opts)
end
