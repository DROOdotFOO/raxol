if Code.ensure_loaded?(Mint.HTTP) do
  defmodule Raxol.MCP.BoundedExchange do
    @moduledoc """
    One request and one bounded response on a dialled connection.

    ADR-0038 decision 4 and ADR-0037 decision 5 describe the same read loop,
    and this is it, once. Nothing below this module bounds anything: `Mint`
    caps a header section at 256 KiB and nothing else, and there is no
    response-size ceiling, no overall deadline and no truncation signal
    anywhere in the stack. So the read loop is ours, and it owns four bounds.

    ## The four bounds

      * **Size.** A byte counter over the accumulated body, refusing at the
        ceiling (`:max_bytes`, default 2 MiB). Exactly the ceiling is allowed;
        one byte past it is `{:too_large, limit}`.
      * **Content-length.** When the header is present and exceeds the ceiling,
        the response is refused before a single body byte is read, so an
        upstream that announces 3 MB costs one round trip rather than the
        ceiling.
      * **A wall-clock deadline** (`:deadline_ms`, default 20 s), computed once
        at entry so the request send counts against it, and re-checked before
        every `recv`. A caller that dials first passes the REMAINING budget:
        `Raxol.MCP.Client.Transport.Http.Exchange` computes the deadline
        before its connect, so the dial counts against it too.
      * **Per-`recv` silence** (`:chunk_timeout_ms`, default 10 s), which bounds
        a peer that stops talking mid-response.

    Each `recv` is given `min(remaining_deadline, chunk_timeout)`, which is what
    makes the two timeouts distinguishable rather than merged: a timeout on a
    clamped wait is `{:timeout, :deadline}`, a timeout on a full chunk wait is
    `{:timeout, :chunk}`. Total overshoot past the deadline is bounded by one
    chunk timeout, so the worst case is `deadline_ms + chunk_timeout_ms`.

    ## Every reason is an atom

    A reason returned from here is `{:too_large, limit}`,
    `{:timeout, :chunk | :deadline}` or `{:transport, atom()}` -- never a raw
    Mint struct. Mint's `{:invalid_header_value, name, value}` carries the
    offending header VALUE, and this module's callers log their reasons.

    ## Why the loop, and not a stream callback

    This is the shape Finch implements for `:request_timeout`, a budget
    decremented by each `recv` and re-checked before the next
    (`deps/finch/lib/finch/http1/conn.ex:298-301`, `:313-323`). Owning the loop
    is what makes the deadline cover the HEADER phase. A deadline checked inside
    a stream callback cannot: with Mint's default `stream_headers: false` no
    callback runs until the whole header section is parsed
    (`deps/mint/lib/mint/http1.ex:159-162`), so a peer dribbling header bytes
    just inside the chunk timeout is bounded only by the 256 KiB
    `:max_header_list_size` (`:154-157`), which at one byte per nine seconds is
    not a bound. ADR-0038's earlier draft chose the callback; this is the
    correction.

    ## Truncation is never a success

    The accumulator is `Raxol.Core.Outbound.Response`: it starts `:incomplete`
    and is promoted to `:complete` only by the terminating response, so
    `run/3` cannot return `{:ok, _}` for anything but a complete read, by
    construction. The reasoning for the tagged state is in that module.

    ## The connection

    Always closed, on every path. There is no pool (ADR-0038 decision 3), so a
    connection outlives nothing and leaving one open would leak a socket per
    request rather than save a handshake.

    ## Why this module lives in `raxol_mcp`

    Both HTTP clients in this repository need exactly this loop:
    `Raxol.Web3.Exchange` for the REST backends and
    `Raxol.MCP.Client.Transport.Http.Exchange` for the remote MCP transport.
    Two copies is what the ratchet catches, and the two copies were identical
    down to the taxonomy, so there was nothing to average.

    It cannot live in `raxol_core` beside `Raxol.Core.Outbound.vet/2` and the
    accumulator, because it calls `Mint.HTTP` and `raxol_core` carries no
    dependencies at all. It can live here: `mint` is already an OPTIONAL
    dependency of this package, `raxol_web3` already depends on `raxol_mcp`
    outright for `Raxol.MCP.CircuitBreaker` (ADR-0033 decision 2), and the
    dependency runs that way and not the other. The dial stays with each
    caller, since one pins vetted addresses for a remote MCP server and the
    other is `Raxol.Web3.Dial`; so does each caller's connect-side taxonomy.

    Like every other module here that touches Mint, it is compiled only when
    `mint` is available, which is why `Raxol.MCP.Client.Transport.select/1`
    checks for it before handing out the HTTP transport.
    """

    alias Raxol.Core.Outbound.Response

    @default_max_bytes 2_097_152
    @default_deadline_ms 20_000
    @default_chunk_timeout_ms 10_000

    @type request :: %{
            required(:method) => String.t(),
            required(:path) => String.t(),
            optional(:headers) => Mint.Types.headers(),
            optional(:body) => iodata() | nil
          }

    @type response :: Response.response()

    @type reason ::
            {:too_large, pos_integer()}
            | {:timeout, :chunk | :deadline}
            | {:transport, atom()}

    @doc """
    The default wall-clock deadline, in milliseconds.

    Public because a caller that dials before calling `run/3` starts this
    clock itself, and it has to be the same number.
    """
    @spec default_deadline_ms() :: pos_integer()
    def default_deadline_ms, do: @default_deadline_ms

    @doc """
    Send `request` on `conn` and read the response under the four bounds.

    The connection is closed before returning, whatever the outcome.

    Options: `:max_bytes`, `:deadline_ms`, `:chunk_timeout_ms`.
    """
    @spec run(Mint.HTTP.t(), request(), keyword()) :: {:ok, response()} | {:error, reason()}
    def run(conn, request, opts \\ []) do
      bounds = bounds(opts)

      # Checked before the send, not only around the read. A budget that is
      # already spent when the exchange starts must not put a packet on the
      # wire: the request would count against the upstream's rate limit and
      # produce a response nobody is waiting for.
      case wait(bounds) do
        {:ok, _timeout, _clamped?} -> send_request(conn, request, bounds)
        :expired -> close(conn, {:error, {:timeout, :deadline}})
      end
    end

    defp send_request(conn, request, bounds) do
      case Mint.HTTP.request(
             conn,
             Map.fetch!(request, :method),
             Map.fetch!(request, :path),
             Map.get(request, :headers, []),
             Map.get(request, :body)
           ) do
        {:ok, conn, ref} -> read(conn, ref, Response.new(), bounds)
        {:error, conn, reason} -> close(conn, {:error, transport_error(reason)})
      end
    end

    defp bounds(opts) do
      %{
        max_bytes: Keyword.get(opts, :max_bytes, @default_max_bytes),
        chunk_timeout: Keyword.get(opts, :chunk_timeout_ms, @default_chunk_timeout_ms),
        deadline: now_ms() + Keyword.get(opts, :deadline_ms, @default_deadline_ms)
      }
    end

    defp read(conn, ref, acc, bounds) do
      case wait(bounds) do
        {:ok, timeout, clamped?} -> recv(conn, ref, acc, bounds, timeout, clamped?)
        :expired -> close(conn, {:error, {:timeout, :deadline}})
      end
    end

    # The clamp is the whole reason the two timeouts are distinguishable. A wait
    # cut short by the deadline that then times out IS the deadline; a full chunk
    # wait that times out is a silent peer.
    defp wait(%{deadline: deadline, chunk_timeout: chunk_timeout}) do
      case deadline - now_ms() do
        remaining when remaining <= 0 -> :expired
        remaining when remaining < chunk_timeout -> {:ok, remaining, true}
        _remaining -> {:ok, chunk_timeout, false}
      end
    end

    defp recv(conn, ref, acc, bounds, timeout, clamped?) do
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, responses} ->
          continue(conn, ref, acc, bounds, responses)

        # Responses arriving alongside a transport error are processed first: an
        # HTTP/1 body delimited by connection close is completed BY the close, so
        # discarding them here would turn a well-formed response into an error.
        {:error, conn, reason, responses} ->
          case Response.absorb(acc, ref, responses, bounds.max_bytes) do
            {:complete, acc} -> close(conn, {:ok, Response.to_response(acc)})
            {:error, halt} -> close(conn, {:error, halt})
            {:incomplete, _acc} -> close(conn, {:error, transport_reason(reason, clamped?)})
          end
      end
    end

    defp continue(conn, ref, acc, bounds, responses) do
      case Response.absorb(acc, ref, responses, bounds.max_bytes) do
        {:incomplete, acc} -> read(conn, ref, acc, bounds)
        {:complete, acc} -> close(conn, {:ok, Response.to_response(acc)})
        {:error, halt} -> close(conn, {:error, halt})
      end
    end

    # A Mint timeout is reported the same way whichever bound produced the wait,
    # so the wait itself has to say which one it was.
    defp transport_reason(%Mint.TransportError{reason: :timeout}, true), do: {:timeout, :deadline}
    defp transport_reason(%Mint.TransportError{reason: :timeout}, false), do: {:timeout, :chunk}
    defp transport_reason(reason, _clamped?), do: transport_error(reason)

    # The reason is collapsed to a tag, the way the connect side already
    # collapses its own. A raw Mint error is not a closed taxonomy: an
    # `%Mint.HTTPError{reason: {:invalid_header_value, name, value}}` carries
    # the FULL header value, so a resolved `authorization` with one
    # non-printable byte in it -- a trailing newline out of `${env:VAR}`, or
    # UTF-8 -- rode `inspect/1` into a `Logger.warning`, into the `failed`
    # list `/mcp` renders, and into the caller's error term. A TLS alert's
    # `{:tls_alert, {name, charlist}}` is peer text for the same reason.
    defp transport_error(%Mint.TransportError{reason: reason}), do: transport_error(reason)
    defp transport_error(%Mint.HTTPError{reason: reason}), do: transport_error(reason)
    defp transport_error(reason) when is_atom(reason), do: {:transport, reason}

    defp transport_error(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
      case elem(reason, 0) do
        tag when is_atom(tag) -> {:transport, tag}
        _untagged -> {:transport, :unknown}
      end
    end

    defp transport_error(_other), do: {:transport, :unknown}

    defp close(conn, result) do
      _ = Mint.HTTP.close(conn)
      result
    end

    defp now_ms, do: System.monotonic_time(:millisecond)
  end
end
