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

  ## Trailers are not headers

  Mint delivers a chunked trailer section as a SECOND `{:headers, ref, _}`, so
  the two are the same tuple and only arrival order tells them apart. They are
  collected into `:trailers`, never merged into `:headers`, and never used for
  the content-length pre-rejection. A merged trailer is a header the response
  never sent, arriving after the point every downstream reader assumed the
  header set was closed, and a trailer `content-length` re-runs a size check on
  a body that has already been read.

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
  defstruct state: :incomplete,
            status: nil,
            headers: [],
            trailers: [],
            chunks: [],
            size: 0,
            headers_seen?: false

  @typedoc "An HTTP status code."
  @type status :: non_neg_integer()

  @typedoc "Header names are lowercase, as Mint delivers them."
  @type headers :: [{String.t(), String.t()}]

  @typedoc """
  `:headers_seen?` is what separates a header block from a trailer block.

  Mint delivers trailers as a SECOND `{:headers, ref, _}` and nothing in the
  tuple says which one it is, so arrival order is the only evidence there is.
  """
  @type t :: %__MODULE__{
          state: :incomplete | :complete,
          status: status() | nil,
          headers: headers(),
          trailers: headers(),
          chunks: [binary()],
          size: non_neg_integer(),
          headers_seen?: boolean()
        }

  @type response :: %{
          status: status(),
          headers: headers(),
          trailers: headers(),
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
  def to_response(%__MODULE__{state: :complete, status: status} = acc)
      when is_integer(status) do
    %{
      status: status,
      headers: Enum.reverse(acc.headers),
      trailers: Enum.reverse(acc.trailers),
      body: acc.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    }
  end

  # The flag is RESET here rather than set once, because an informational
  # response is a status and a header block of its own
  # (`Mint.HTTP1.decode_body(:informational, ...)`), and a 1xx's headers are
  # not the trailers of anything.
  defp step({:status, ref, status}, ref, acc, _max_bytes),
    do: {:incomplete, %{acc | status: status, headers_seen?: false}}

  defp step({:headers, ref, headers}, ref, %{headers_seen?: false} = acc, max_bytes) do
    case announced_length(headers) do
      {:ok, length} when is_integer(length) and length > max_bytes ->
        {:error, {:too_large, max_bytes}}

      {:ok, _within} ->
        {:incomplete, %{acc | headers: Enum.reverse(headers) ++ acc.headers, headers_seen?: true}}

      :invalid ->
        {:error, {:transport, :invalid_content_length}}
    end
  end

  # Trailers: a second `{:headers, ref, _}` for the same reference, which is
  # the shape Mint parses a chunked trailer section into. They are kept out of
  # `:headers` and out of the pre-rejection, and that is two failures and not
  # one.
  #
  # Merged, a trailer introduces a header name the response never sent:
  # `Raxol.MCP.Client.Transport.Http` reads `content-type` back with
  # `List.keyfind/3` to choose between the SSE and the JSON parse path, and
  # `mcp-session-id` the same way, so a server that cannot set a header before
  # its body could set one after it.
  #
  # Pre-rejected, a trailer `content-length` re-runs the size check AFTER the
  # body: `content-length: 99999` behind a five-byte body returned
  # `{:too_large, _}`, which `Raxol.Web3.HTTP` records as neither breaker
  # success nor failure, so an origin appending one trailer per response was
  # permanently exempt from health accounting.
  defp step({:headers, ref, trailers}, ref, acc, _max_bytes),
    do: {:incomplete, %{acc | trailers: Enum.reverse(trailers) ++ acc.trailers}}

  defp step({:data, ref, data}, ref, acc, max_bytes) do
    size = acc.size + byte_size(data)

    if size > max_bytes do
      {:error, {:too_large, max_bytes}}
    else
      {:incomplete, %{acc | chunks: [data | acc.chunks], size: size}}
    end
  end

  # A terminating response with no status is a malformed read, not a response.
  # Completing on it put `nil` into a `response()` whose `:status` every
  # consumer treats as an integer, and Erlang term order answers those
  # comparisons instead of failing them: `nil in 200..299` is false, `nil >=
  # 500` is TRUE, so an empty result was recorded as a 5xx from the origin.
  defp step({:done, ref}, ref, %{status: nil}, _max_bytes),
    do: {:error, {:transport, :no_status}}

  defp step({:done, ref}, ref, acc, _max_bytes), do: {:complete, %{acc | state: :complete}}

  defp step({:error, ref, reason}, ref, _acc, _max_bytes), do: {:error, {:transport, reason}}

  # A response for another reference cannot occur (one request per connection,
  # no pipelining) but is ignored rather than crashing the read of the one we
  # asked for.
  defp step(_other, _ref, acc, _max_bytes), do: {:incomplete, acc}

  # `{:ok, nil}` for an absent or unparseable length leaves the streaming
  # counter as the only bound, which is correct: a chunked response has no
  # length at all.
  #
  # `:invalid` is a length that is present and is not a length. A NEGATIVE one
  # bypassed the pre-rejection outright — `Integer.parse("-5")` is `{-5, ""}`
  # and `-5 > max_bytes` is false — and differing duplicates are the classic
  # request-smuggling desync, which is why the first value is not simply
  # taken. Duplicates that agree are legal (RFC 9110 8.6) and collapse.
  defp announced_length(headers) do
    case headers |> Enum.filter(&content_length?/1) |> Enum.map(&parse_length/1) |> Enum.uniq() do
      [] -> {:ok, nil}
      [nil] -> {:ok, nil}
      [length] when is_integer(length) and length >= 0 -> {:ok, length}
      _negative_or_conflicting -> :invalid
    end
  end

  defp content_length?({name, _value}), do: name == "content-length"

  defp parse_length({_name, value}) do
    case Integer.parse(String.trim(value)) do
      {length, ""} -> length
      _unparseable -> nil
    end
  end
end
