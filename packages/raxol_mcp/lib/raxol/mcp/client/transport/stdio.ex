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
  """

  @behaviour Raxol.MCP.Client.Transport

  alias Raxol.MCP.Protocol

  @enforce_keys [:command]
  defstruct [:port, :command, buffer: ""]

  @type t :: %__MODULE__{
          port: port() | nil,
          command: String.t(),
          buffer: binary()
        }

  @line_bytes 1_048_576

  @impl Raxol.MCP.Client.Transport
  def connect(config) do
    command = Map.fetch!(config, :command)
    args = Map.get(config, :args, [])
    env = Map.get(config, :env, [])

    port = Port.open({:spawn_executable, find_executable(command)}, port_opts(args, env))
    {:ok, %__MODULE__{port: port, command: command}}
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

  @impl Raxol.MCP.Client.Transport
  def send(%__MODULE__{port: port} = handle, id, request) when is_port(port) do
    case encode(id, request) do
      {:ok, data} ->
        Port.command(port, data)
        {:ok, handle}

      {:error, reason} ->
        {:error, {:encode_failed, reason}}
    end
  rescue
    ArgumentError -> {:error, :not_connected}
  catch
    :error, reason -> {:error, {:port_failed, reason}}
  end

  def send(%__MODULE__{}, _id, _request), do: {:error, :not_connected}

  @impl Raxol.MCP.Client.Transport
  def close(%__MODULE__{port: port}) when is_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  catch
    :error, _reason -> :ok
  end

  def close(%__MODULE__{}), do: :ok

  @impl Raxol.MCP.Client.Transport
  def decode_info(%__MODULE__{port: port} = handle, {port, {:data, {:eol, chunk}}}) do
    {:messages, [handle.buffer <> chunk], %{handle | buffer: ""}}
  end

  def decode_info(%__MODULE__{port: port} = handle, {port, {:data, {:noeol, chunk}}}) do
    {:messages, [], %{handle | buffer: handle.buffer <> chunk}}
  end

  def decode_info(%__MODULE__{port: port} = handle, {port, {:exit_status, code}}) do
    {:closed, {:server_exited, code}, %{handle | port: nil, buffer: ""}}
  end

  def decode_info(%__MODULE__{}, _message), do: :ignore

  # -- Private -----------------------------------------------------------------

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
