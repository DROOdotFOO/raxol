defmodule Raxol.Agent.Auth.Loopback do
  @moduledoc """
  The one-shot local HTTP listener a browser OAuth flow redirects back to.

  ACP's Agent Auth is defined in terms of this: the agent binds a port on the
  user's machine, sends them to the provider in a browser, and catches the
  redirect. `open/1` binds, `redirect_uri/1` names the URL to hand the
  provider, `await/2` blocks until the browser arrives, and `close/1` gives the
  port back.

  It binds `127.0.0.1` explicitly, so nothing off-box can reach it, and it
  speaks just enough HTTP to answer one GET: a browser tab is the only client
  it ever has. A request without an authorization code (a favicon probe, a
  stray scan) is answered 404 and does not end the wait -- only a `code`, an
  `error`, or the deadline does.

  Nothing here writes to stdout. On the ACP surface stdout is the JSON-RPC
  wire and a single stray line is a parse error at the client.
  """

  @loopback {127, 0, 0, 1}

  # A browser sends a dozen headers at most; this bound just stops a
  # malformed peer from holding the accept loop open header-by-header.
  @max_headers 64

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket(),
          port: :inet.port_number(),
          path: String.t()
        }

  @enforce_keys [:socket, :port, :path]
  defstruct socket: nil, port: nil, path: "/callback"

  @doc """
  Bind an ephemeral loopback port.

  Options: `:path`, the callback path to advertise (default `"/callback"`).
  """
  @spec open(keyword()) :: {:ok, t()} | {:error, term()}
  def open(opts \\ []) do
    path = Keyword.get(opts, :path, "/callback")

    listen_opts = [
      :binary,
      ip: @loopback,
      packet: :http_bin,
      active: false,
      reuseaddr: true,
      backlog: 4
    ]

    with {:ok, socket} <- :gen_tcp.listen(0, listen_opts),
         {:ok, port} <- :inet.port(socket) do
      {:ok, %__MODULE__{socket: socket, port: port, path: path}}
    else
      {:error, reason} -> {:error, {:listen_failed, reason}}
    end
  end

  @doc "The URL to give the provider as its redirect target."
  @spec redirect_uri(t()) :: String.t()
  def redirect_uri(%__MODULE__{port: port, path: path}) do
    "http://localhost:#{port}#{path}"
  end

  @doc "Release the bound port. Safe to call twice."
  @spec close(t()) :: :ok
  def close(%__MODULE__{socket: socket}), do: :gen_tcp.close(socket)

  @doc """
  Wait up to `timeout` ms for the browser redirect.

  Returns `{:ok, code}` for a redirect carrying one, `{:error, {:oauth_error,
  error, description}}` for a provider-reported denial (the user pressed
  "cancel"), and `{:error, :timeout}` if nobody arrives. The deadline covers
  the whole wait, not each accept, so a stream of junk requests cannot extend
  it.
  """
  @spec await(t(), timeout()) :: {:ok, String.t()} | {:error, term()}
  def await(%__MODULE__{} = listener, timeout) when is_integer(timeout) do
    accept_loop(listener, System.monotonic_time(:millisecond) + timeout)
  end

  defp accept_loop(listener, deadline) do
    case remaining(deadline) do
      0 ->
        {:error, :timeout}

      left ->
        case :gen_tcp.accept(listener.socket, left) do
          {:ok, conn} -> serve(listener, conn, deadline)
          {:error, :timeout} -> {:error, :timeout}
          {:error, reason} -> {:error, {:accept_failed, reason}}
        end
    end
  end

  defp serve(listener, conn, deadline) do
    result = read_request(conn, deadline)
    respond(conn, result)
    :gen_tcp.close(conn)

    case result do
      {:done, outcome} -> outcome
      :continue -> accept_loop(listener, deadline)
    end
  end

  # Reads the request line, then drains headers so the response is not met by
  # an unread request buffer -- closing on one makes the kernel send RST and
  # the browser shows a connection error instead of the page we just wrote.
  defp read_request(conn, deadline) do
    case :gen_tcp.recv(conn, 0, remaining(deadline)) do
      {:ok, {:http_request, :GET, {:abs_path, path}, _version}} ->
        drain_headers(conn, deadline)
        classify(path)

      {:ok, {:http_request, _method, _uri, _version}} ->
        drain_headers(conn, deadline)
        :continue

      _other ->
        :continue
    end
  end

  defp drain_headers(conn, deadline, seen \\ 0)

  defp drain_headers(_conn, _deadline, seen) when seen >= @max_headers, do: :ok

  defp drain_headers(conn, deadline, seen) do
    :inet.setopts(conn, packet: :httph_bin)

    case :gen_tcp.recv(conn, 0, remaining(deadline)) do
      {:ok, {:http_header, _, _, _, _}} ->
        drain_headers(conn, deadline, seen + 1)

      _ ->
        :ok
    end
  end

  # `URI.decode_query/1` on the query string only: the path itself is ours and
  # carries nothing we act on.
  defp classify(path) do
    params =
      path
      |> to_string()
      |> URI.parse()
      |> Map.get(:query)
      |> decode_query()

    case params do
      %{"code" => code} when is_binary(code) and code != "" ->
        {:done, {:ok, code}}

      %{"error" => error} when is_binary(error) ->
        {:done,
         {:error, {:oauth_error, error, Map.get(params, "error_description")}}}

      _ ->
        :continue
    end
  end

  defp decode_query(nil), do: %{}
  defp decode_query(query), do: URI.decode_query(query)

  defp respond(conn, {:done, {:ok, _code}}) do
    write(
      conn,
      200,
      "Connected",
      "You can close this tab and return to your editor."
    )
  end

  defp respond(conn, {:done, {:error, {:oauth_error, error, description}}}) do
    write(conn, 200, "Sign-in cancelled", description || error)
  end

  defp respond(conn, _other) do
    write(
      conn,
      404,
      "Not found",
      "This port is only listening for a sign-in redirect."
    )
  end

  defp write(conn, status, title, message) do
    body = page(title, message)

    head = [
      "HTTP/1.1 #{status} #{reason_phrase(status)}\r\n",
      "Content-Type: text/html; charset=utf-8\r\n",
      "Content-Length: #{byte_size(body)}\r\n",
      "Connection: close\r\n\r\n"
    ]

    :inet.setopts(conn, packet: :raw)
    :gen_tcp.send(conn, [head, body])
    :gen_tcp.shutdown(conn, :write)
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(_status), do: "OK"

  # The only markup a user of this flow ever sees. Plain, self-contained, and
  # escaped, since `message` can carry a provider-supplied description.
  defp page(title, message) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>raxol</title>
    <style>
    body { font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
           margin: 4rem auto; max-width: 32rem; line-height: 1.5; }
    h1 { font-size: 1.1rem; font-weight: 600; }
    p { color: #555; }
    </style>
    </head>
    <body>
    <h1>#{escape(title)}</h1>
    <p>#{escape(message)}</p>
    </body>
    </html>
    """
  end

  defp escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end
end
