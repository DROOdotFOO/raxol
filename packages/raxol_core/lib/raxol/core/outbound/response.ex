defmodule Raxol.Core.Outbound.Response do
  @moduledoc """
  The bounded response accumulator: a tagged state that starts incomplete.

  This is the response half of the outbound policy `Raxol.Core.Outbound`
  states, which is why it carries that name. `vet/2` owns rules 1 to 3 (which
  target may be reached, and by which addresses) and says outright that rules 4
  and 5 belong to whoever owns the request. This module is the part of rule 5 a
  request owner cannot write differently per package without the answer
  differing too: the size ceiling, the content-length pre-rejection, and the
  rule that a read which never terminated has no response at all.

  Two packages had a byte-for-byte copy of it, one a submodule of
  `Raxol.Web3.Exchange` and one a private map inside
  `Raxol.MCP.Client.Transport.Http.Exchange`, because the package graph forbids
  either depending on the other. `raxol_core` is what both already depend on,
  so this is where the single copy belongs.

  ## Truncation is never a success

  `:state` is `:incomplete` until the terminating response promotes it, and
  `to_response/1` accepts nothing else. That is finding M1 of
  `docs/proposals/web3-client-plan-review.md`, and it is why the accumulator is
  a tagged struct rather than a bare map: every halt-based reader in this
  ecosystem returns success on abort (`Finch.stream_while/5` answers `{:ok,
  acc}` for both a finished response and a `{:halt, acc}`), so an accumulator
  whose initial value is shaped like a success turns a refused oversized
  response into an empty 200. For a list endpoint that is indistinguishable
  from a list with no entries. Here a caller cannot build a response out of an
  accumulator the terminating response never reached.

  ## What it does not own

  The ceiling arrives as an argument, so this module holds no policy and has no
  defaults of its own. It opens no socket, runs no timer, and calls nothing
  from Mint: it pattern-matches Mint's response tuples and never invokes it, so
  `raxol_core` gains no dependency. The dial, the wall-clock deadline, the
  per-`recv` chunk timeout and each package's error taxonomy stay with the
  request owner, because those differ between the two.

  The two reasons that can be decided from the response bytes alone are
  returned here: `{:too_large, max_bytes}` and `{:transport, reason}`. Both
  taxonomies already contain exactly those shapes.
  """

  @enforce_keys [:state]
  defstruct state: :incomplete, status: nil, headers: [], chunks: [], size: 0

  @typedoc "An HTTP status code."
  @type status :: non_neg_integer()

  @typedoc "Header names are lowercase, as Mint delivers them."
  @type headers :: [{String.t(), String.t()}]

  @type t :: %__MODULE__{
          state: :incomplete | :complete,
          status: status() | nil,
          headers: headers(),
          chunks: [binary()],
          size: non_neg_integer()
        }

  @type response :: %{
          status: status(),
          headers: headers(),
          body: binary()
        }

  @typedoc """
  One of Mint's response tuples: `{:status, ref, status}`,
  `{:headers, ref, headers}`, `{:data, ref, binary}`, `{:done, ref}` or
  `{:error, ref, reason}`. Matched structurally, never constructed.
  """
  @type mint_response :: tuple()

  @type reason :: {:too_large, non_neg_integer()} | {:transport, term()}

  @doc "A fresh, incomplete accumulator."
  @spec new() :: t()
  def new, do: %__MODULE__{state: :incomplete}

  @doc """
  Fold Mint responses in, enforcing the size ceiling as they arrive.

  Returns `{:incomplete, acc}`, `{:complete, acc}`, or `{:error, reason}`,
  where `reason` is already one of the two the response bytes can decide.

  Folding stops at the first terminating or refusing response, so responses
  after a `{:done, ref}` are not consumed; one request per connection and no
  pipelining means there are none.

      iex> alias Raxol.Core.Outbound.Response
      iex> ref = make_ref()
      iex> Response.absorb(Response.new(), ref, [{:data, ref, "0123456789"}], 4)
      {:error, {:too_large, 4}}

      iex> alias Raxol.Core.Outbound.Response
      iex> ref = make_ref()
      iex> headers = [{"content-length", "9000"}]
      iex> Response.absorb(Response.new(), ref, [{:headers, ref, headers}], 1024)
      {:error, {:too_large, 1024}}
  """
  @spec absorb(t(), reference(), [mint_response()], non_neg_integer()) ::
          {:incomplete, t()} | {:complete, t()} | {:error, reason()}
  def absorb(acc, ref, responses, max_bytes) do
    Enum.reduce_while(responses, {:incomplete, acc}, fn response, {_tag, acc} ->
      case step(response, ref, acc, max_bytes) do
        {:error, _reason} = error -> {:halt, error}
        {:complete, acc} -> {:halt, {:complete, acc}}
        {:incomplete, acc} -> {:cont, {:incomplete, acc}}
      end
    end)
  end

  @doc """
  The response, or a raise.

  Only a `:complete` accumulator has one. A raise rather than an error tuple
  because reaching here with an incomplete accumulator is a bug in the read
  loop, not an outcome a caller can handle.
  """
  @spec to_response(t()) :: response()
  def to_response(%__MODULE__{state: :complete} = acc) do
    %{
      status: acc.status,
      headers: Enum.reverse(acc.headers),
      body: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  defp step({:status, ref, status}, ref, acc, _max_bytes),
    do: {:incomplete, %{acc | status: status}}

  defp step({:headers, ref, headers}, ref, acc, max_bytes) do
    case announced_length(headers) do
      length when is_integer(length) and length > max_bytes ->
        {:error, {:too_large, max_bytes}}

      _within ->
        {:incomplete, %{acc | headers: Enum.reverse(headers) ++ acc.headers}}
    end
  end

  defp step({:data, ref, data}, ref, acc, max_bytes) do
    size = acc.size + byte_size(data)

    if size > max_bytes do
      {:error, {:too_large, max_bytes}}
    else
      {:incomplete, %{acc | chunks: [data | acc.chunks], size: size}}
    end
  end

  defp step({:done, ref}, ref, acc, _max_bytes), do: {:complete, %{acc | state: :complete}}

  defp step({:error, ref, reason}, ref, _acc, _max_bytes), do: {:error, {:transport, reason}}

  # Trailers carry no body bytes and nothing here reads them. A response for
  # another reference cannot occur (one request per connection, no pipelining)
  # but is ignored rather than crashing the read of the one we asked for.
  defp step(_other, _ref, acc, _max_bytes), do: {:incomplete, acc}

  # An unparseable or absent content-length leaves the streaming counter as the
  # only bound, which is correct: a chunked response has no length at all.
  defp announced_length(headers) do
    with {_name, value} <- Enum.find(headers, fn {name, _value} -> name == "content-length" end),
         {length, ""} <- Integer.parse(String.trim(value)) do
      length
    else
      _absent -> nil
    end
  end
end
