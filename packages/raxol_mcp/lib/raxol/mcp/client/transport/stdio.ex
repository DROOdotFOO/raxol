defmodule Raxol.MCP.Client.Transport.Stdio do
  @moduledoc """
  The local-subprocess transport: `Raxol.MCP.Client`'s original port code,
  moved behind `Raxol.MCP.Client.Transport` with no change to what it does.

  ADR-0037 decision 1. The port is opened `{:line, 1_048_576}`, so a line
  longer than a mebibyte arrives as a run of `:noeol` chunks followed by one
  `:eol`, and reassembly is this handle's `:buffer`. It used to be the client's
  `state.buffer`; the client no longer knows what a line is.

  ## The one behaviour that did change, deliberately

  `send_to_port/2` fell through to `:ok` for anything that was not a port
  (`client.ex:355-362` before this change), so a client whose server had
  already exited ACCEPTED a request, never replied, and left the caller blocked
  for the full 30 s `call_timeout`. `send/3` here returns
  `{:error, :not_connected}` instead. ADR-0037 decision 1 names that
  fallthrough as the thing a transport must not inherit.

  A failed spawn is also an error tuple rather than an exception, so
  `Raxol.MCP.Client.start_link/1` answers `{:error, {:spawn_failed, reason}}`
  for a command that is not on the path instead of taking the caller down with
  an `:enoent` from deep inside `Port.open/2`.

  ## Closing the port is not stopping the server

  `Port.close/1` closes the child's stdio and signals nothing. A server that
  reads stdin sees EOF and usually exits; one that does not -- and the `npx`
  and `uvx` wrappers that shell out to a long-lived server are exactly that --
  keeps running with no owner, forever, once per session. On a long-lived SSH
  host that is unbounded accumulation.

  So `connect/1` captures the child's signal target while the port is open
  (`Port.info/2` is the only thing that knows it, and a closed port has
  forgotten it), and `close/1` closes the port, sends SIGTERM, waits a short
  grace for the child to go, then SIGKILLs what is left. The grace is 400 ms
  on purpose: `close/1` runs inside the client's `terminate/2`, and a
  supervisor's default worker shutdown budget is 5 s.
  """

  @behaviour Raxol.MCP.Client.Transport

  require Logger

  alias Raxol.Core.ProcessGroup
  alias Raxol.MCP.Protocol

  @enforce_keys [:command]
  defstruct [:port, :command, target: :none, buffer: ""]

  @type t :: %__MODULE__{
          port: port() | nil,
          command: String.t(),
          target: ProcessGroup.target(),
          buffer: binary()
        }

  @line_bytes 1_048_576

  # `{:line, @line_bytes}` bounds one port CHUNK, not the line: a server that
  # never emits a newline delivers an unbounded run of `:noeol` chunks and
  # every one of them was appended to `:buffer`, so 100 MB of output became
  # 100 MB of the client's heap. The accumulated line gets the ceiling the HTTP
  # leg already gives a response body (`Raxol.MCP.BoundedExchange`'s 2 MiB
  # `:max_bytes` default), and passing it fails the SESSION rather than the
  # line: a peer that cannot frame its output is not one whose next line can be
  # trusted to start where this one stopped.
  @max_line_bytes 2_097_152

  # Long enough for a node or python server to run its SIGTERM handler and
  # flush, short enough that `terminate/2` finishes well inside a supervisor's
  # 5 s worker shutdown. `ProcessGroup.await_gone/3` polls, so a child that
  # goes immediately costs one poll, not the whole window.
  @reap_grace_ms 400

  @impl Raxol.MCP.Client.Transport
  def connect(config) do
    command = Map.fetch!(config, :command)
    args = Map.get(config, :args, [])
    env = Map.get(config, :env, [])

    # Spawning is the side effect, so the provenance gate is asked HERE and
    # not only by whoever assembled the spec: a workspace `.mcp.json` command
    # is arbitrary local code from a file a clone carried.
    with :ok <- Raxol.MCP.Client.Transport.permit(config, command) do
      port = Port.open({:spawn_executable, find_executable(command)}, port_opts(args, env))
      {:ok, %__MODULE__{port: port, command: command, target: capture(port)}}
    end
  catch
    # `Port.open/2` signals a missing or unexecutable command as an ERROR with
    # a bare POSIX atom, not an exception struct, so the atom is kept as the
    # reason and only a genuine exception is flattened to its message.
    :error, %{__exception__: true} = error ->
      {:error, {:spawn_failed, Exception.message(error)}}

    :error, reason ->
      {:error, {:spawn_failed, reason}}
  end

  @doc """
  A stdio server is a legacy-era peer: it handshakes, and its revision is the
  one this package has always offered.

  `:stateless` rather than `:serialized` is parity, not an oversight. One pipe
  carries every request and the ids on the way back disambiguate them, which is
  why the concurrency policy ADR-0037 decision 6 adds exists for HTTP origins
  in the first place: a session is what cannot be fanned out over.
  """
  @impl Raxol.MCP.Client.Transport
  def session(%__MODULE__{}) do
    {:handshake, %{version: Protocol.mcp_protocol_version(), concurrency: :stateless}}
  end

  # A pipe write has no round trip to wait for, so a notification is finished
  # the moment `Port.command/2` returns. The client holds an in-flight entry
  # for it either way, so say so -- through the same mailbox every other
  # transport event arrives on, which keeps it ordered behind anything the
  # port has already delivered.
  @impl Raxol.MCP.Client.Transport
  def send(%__MODULE__{port: port} = handle, {:notify, id}, request) when is_port(port) do
    with {:ok, handle} <- write(handle, nil, request) do
      Kernel.send(self(), {port, {:settled, id}})
      {:ok, handle}
    end
  end

  def send(%__MODULE__{port: port} = handle, id, request) when is_port(port) do
    write(handle, id, request)
  end

  def send(%__MODULE__{}, _id, _request), do: {:error, :not_connected}

  # Nothing to cancel: the write already happened, and a late reply for an id
  # the client has forgotten is dropped by `with_pending/3`.
  @impl Raxol.MCP.Client.Transport
  def cancel(%__MODULE__{} = handle, _id), do: handle

  # A JSON-RPC response the CLIENT owes the server. The method is the modern
  # HTTP era's routing header and means nothing on a pipe, where one stream
  # carries everything in both directions.
  @impl Raxol.MCP.Client.Transport
  def respond(%__MODULE__{port: port} = handle, _method, response) when is_port(port) do
    command(handle, Protocol.encode(response))
  end

  def respond(%__MODULE__{}, _method, _response), do: {:error, :not_connected}

  defp write(%__MODULE__{} = handle, id, request) do
    command(handle, encode(id, request))
  end

  defp command(%__MODULE__{port: port} = handle, {:ok, data}) do
    Port.command(port, data)
    {:ok, handle}
  rescue
    ArgumentError -> {:error, :not_connected}
  catch
    :error, reason -> {:error, {:port_failed, reason}}
  end

  defp command(%__MODULE__{}, {:error, reason}), do: {:error, {:encode_failed, reason}}

  # The close and the reap, in that order: EOF first gives a well-behaved
  # server the chance to exit on its own terms, and the grace below is then
  # usually one poll rather than a wait. What survives both is killed, because
  # a client that has stopped reading a pipe has already stopped being the
  # thing keeping that subprocess honest.
  @impl Raxol.MCP.Client.Transport
  def close(%__MODULE__{port: port} = handle) do
    if is_port(port), do: close_port(port)
    reap(handle.target, handle.command)
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :error, _reason -> :ok
  end

  defp reap(:none, _command), do: :ok

  defp reap(target, command) do
    shell = [shell: ProcessGroup.shell()]

    case ProcessGroup.signal(target, "-TERM", shell) do
      # Already gone: the EOF the close delivered was enough.
      :gone -> :ok
      :ok -> insist(target, command, shell)
      {:error, reason} -> warn_unreaped(command, reason)
    end

    :ok
  end

  defp insist(target, command, shell) do
    case ProcessGroup.await_gone(target, @reap_grace_ms, shell) do
      :ok -> :ok
      :timeout -> kill(target, command, shell)
      {:error, reason} -> warn_unreaped(command, reason)
    end
  end

  defp kill(target, command, shell) do
    Logger.warning(
      "[MCP.Client.Stdio] #{command} ignored SIGTERM after #{@reap_grace_ms} ms; killing"
    )

    case ProcessGroup.signal(target, "-KILL", shell) do
      {:error, reason} -> warn_unreaped(command, reason)
      _gone_or_delivered -> :ok
    end
  end

  # The server is still out there and nothing here can stop it: no shell to
  # signal through, or a kernel that refused. `close/1` answers `:ok` either
  # way -- the transport contract has no arm for "the server outlived the
  # session" -- so this is the only place the operator watching a host
  # accumulate MCP servers gets the reason.
  defp warn_unreaped(command, reason) do
    Logger.warning("[MCP.Client.Stdio] could not stop #{command}: #{inspect(reason)}")
  end

  @impl Raxol.MCP.Client.Transport
  def decode_info(%__MODULE__{port: port} = handle, {port, {:data, {:eol, chunk}}}) do
    case accumulate(handle, chunk) do
      {:ok, line} -> {:messages, [line], %{handle | buffer: ""}}
      :too_long -> overflowed(handle)
    end
  end

  def decode_info(%__MODULE__{port: port} = handle, {port, {:data, {:noeol, chunk}}}) do
    case accumulate(handle, chunk) do
      {:ok, buffer} -> {:messages, [], %{handle | buffer: buffer}}
      :too_long -> overflowed(handle)
    end
  end

  def decode_info(%__MODULE__{port: port} = handle, {port, {:exit_status, code}}) do
    {:closed, {:server_exited, code}, %{handle | port: nil, buffer: ""}}
  end

  def decode_info(%__MODULE__{port: port} = handle, {port, {:settled, id}}) do
    {:settled, id, handle}
  end

  def decode_info(%__MODULE__{}, _message), do: :ignore

  # -- Private -----------------------------------------------------------------

  # Read while the port is OPEN: `Port.info/2` is the only thing that knows the
  # child's pid, and a closed port has forgotten it -- and a process group that
  # outlived its leader is exactly the case worth reaping. `resolve/1` costs
  # one `kill -0` here, once per session, against the fork of a whole server.
  defp capture(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 1 -> ProcessGroup.resolve(os_pid)
      _no_child -> :none
    end
  end

  defp accumulate(%__MODULE__{buffer: buffer}, chunk) do
    if byte_size(buffer) + byte_size(chunk) > @max_line_bytes,
      do: :too_long,
      else: {:ok, buffer <> chunk}
  end

  # The port is torn down HERE because `{:closed, _, _}` routes to the client's
  # reconnect, which drops the handle without closing it: the subprocess would
  # go on filling a pipe nobody reads.
  defp overflowed(%__MODULE__{} = handle) do
    Logger.warning(
      "[MCP.Client.Stdio] #{handle.command} sent more than #{@max_line_bytes} bytes " <>
        "with no newline; closing the session"
    )

    close(handle)
    {:closed, {:line_too_long, @max_line_bytes}, %{handle | port: nil, target: :none, buffer: ""}}
  end

  defp encode(nil, %{method: method, params: params}) do
    Protocol.encode(Protocol.notification(method, params))
  end

  defp encode(id, %{method: method, params: params}) when is_integer(id) do
    Protocol.encode(Protocol.request(id, method, params))
  end

  defp port_opts(args, env) do
    charlist_env =
      Enum.map(env, fn {key, value} ->
        {String.to_charlist(key), String.to_charlist(value)}
      end)

    opts = [
      :binary,
      :exit_status,
      {:line, @line_bytes},
      :use_stdio,
      :stderr_to_stdout,
      args: args
    ]

    if charlist_env == [], do: opts, else: [{:env, charlist_env} | opts]
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> String.to_charlist(command)
      path -> String.to_charlist(path)
    end
  end
end
