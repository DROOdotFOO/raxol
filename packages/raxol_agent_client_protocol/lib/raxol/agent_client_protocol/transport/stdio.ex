defmodule Raxol.AgentClientProtocol.Transport.Stdio do
  @moduledoc """
  Newline-delimited JSON (NDJSON) over a stdio pipe — either our OWN
  process's real stdin/stdout (`:self` mode, when this BEAM process IS the
  ACP agent/client speaking on its own stdio), or a spawned peer command's
  stdio (`:spawn` mode, when we launch and speak to a subprocess).

  One `GenServer` owns BOTH directions of the pipe:

    * **Read** — raw bytes arrive from the OS pipe as `Port` `:data`
      messages and are fed through
      `Raxol.AgentClientProtocol.Transport.Framer` (byte-splitting only:
      buffers partial data, yields complete NDJSON lines, tolerates
      CRLF, bounds unterminated-line memory). Each complete line is then
      `Jason.decode/1`'d *tolerantly*: a line that isn't valid JSON, that
      decodes to something other than a JSON object, or that the framer
      itself rejected as oversized, is delivered to the owner as
      `{:acp_transport, ref, {:decode_error, reason, raw_line}}` rather
      than crashing the transport or dropping the frame silently. A
      well-formed object is delivered as
      `{:acp_transport, ref, {:message, map}}`. Lines are processed (and
      therefore delivered) strictly in arrival order. Blank lines are
      skipped by the framer without generating a decode error — a
      trailing newline at EOF is common and not itself malformed input.

    * **Write** — `send_message/2` `Jason.encode!/1`s the message, appends
      `"\n"`, and writes through THIS GenServer's own mailbox
      (`GenServer.call/2`). This is deliberate single-writer discipline:
      every caller's write is serialized through one process, so two
      concurrent `send_message/2` calls can never interleave their bytes
      on the wire and corrupt a frame — NDJSON has no length prefix, so a
      torn write (line A's bytes and line B's bytes interleaved before
      either `"\n"` lands) is unrecoverable, unlike a length-framed
      protocol. Never write to the underlying port through any path other
      than this module.

  ## stdout is protocol-pure

  In `:self` mode, this process's real stdout carries the wire protocol.
  Nothing else may ever write to it — an errant `IO.puts/1`, a stray
  `Logger` line landing on the `:user` group leader, or any other
  application output would land mid-frame on a peer that is line-buffered
  reading JSON. This module logs unexpected messages via `Logger.debug/1`,
  which is safe **only if** the host application's Logger is configured to
  a device other than `:user`/stdout (e.g.
  `config :logger, :default_handler, config: [type: :standard_error]`, or
  an equivalent `:standard_error` console backend). Configuring that is the
  host application's responsibility, not this module's — get it wrong and
  every log line is a corrupted ACP frame on the wire.

  ## Modes

    * `start_self/1` — open the BEAM's own fd 0 (stdin) / fd 1 (stdout) as
      a `Port` (`{:fd, 0, 1}`). Only meaningful when this process's real
      stdio is dedicated to the ACP wire protocol — e.g. a compiled
      release or escript entry point, or `mix run --no-halt` invoked
      non-interactively with stdio piped by the peer. **Never** call this
      from an interactive `iex` session, or under a test runner — both
      already have fd 0/1 claimed (ExUnit's own IO capture owns `:user`).
    * `start_spawn/3` — launch a peer executable via
      `Port.open({:spawn_executable, ...}, ...)` and speak to *its*
      stdin/stdout. The peer's exit is delivered to the owner as
      `{:closed, {:exit_status, code}}`.

  ## Ownership

  Mirrors `Raxol.AgentClientProtocol.Transport.Paired`: a freshly created
  handle has no owner (`nil`) — inbound messages are silently dropped
  until `set_owner/2` adopts it, so a supervisor can create the transport
  before the `Connection` process that will own it exists.
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.Transport.Framer

  @behaviour Raxol.AgentClientProtocol.Transport

  @type t :: %__MODULE__{pid: pid()}
  defstruct [:pid]

  @typep mode :: :self | :spawn

  @typep server_state :: %{
           owner: pid() | nil,
           port: port(),
           mode: mode(),
           framer: Framer.t(),
           closed: boolean()
         }

  # -- Construction --------------------------------------------------------

  @doc """
  Open the BEAM's own stdin/stdout (fd 0 / fd 1) as the transport. See the
  moduledoc's "Modes" section for when this is (and is not) safe to call.

  `opts`:

    * `:owner` — pid to receive inbound `{:acp_transport, ...}` messages;
      defaults to `nil` (adopt later via `set_owner/2`).
  """
  @spec start_self(keyword()) :: {:ok, t()}
  def start_self(opts \\ []) do
    owner = Keyword.get(opts, :owner)
    {:ok, pid} = GenServer.start_link(__MODULE__, {:self, owner})
    {:ok, %__MODULE__{pid: pid}}
  end

  @doc """
  Spawn `cmd` (resolved via `System.find_executable/1`, so a bare name is
  looked up on `$PATH` and an absolute/relative path containing a slash is
  used as-is) with `args`, and speak NDJSON over its stdin/stdout.

  `opts`:

    * `:owner` — pid to receive inbound messages; defaults to `nil`.
    * `:cd` — working directory for the child process.
    * `:env` — list of `{name, value}` environment overrides, passed
      straight to `Port.open/2`'s `:env` option.

  Returns `{:error, :executable_not_found}` if `cmd` cannot be resolved.
  """
  @spec start_spawn(String.t(), [String.t()], keyword()) ::
          {:ok, t()} | {:error, :executable_not_found}
  def start_spawn(cmd, args \\ [], opts \\ []) when is_binary(cmd) and is_list(args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, :executable_not_found}

      path ->
        owner = Keyword.get(opts, :owner)
        spawn_opts = Keyword.take(opts, [:cd, :env])
        {:ok, pid} = GenServer.start_link(__MODULE__, {:spawn, path, args, spawn_opts, owner})
        {:ok, %__MODULE__{pid: pid}}
    end
  end

  @doc """
  Set (or replace) the owner process for a handle — mirrors
  `Raxol.AgentClientProtocol.Transport.Paired.set_owner/2`.
  """
  @spec set_owner(t(), pid()) :: :ok
  def set_owner(%__MODULE__{pid: pid}, owner) when is_pid(owner) do
    GenServer.call(pid, {:set_owner, owner})
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec send_message(t(), map()) :: {:ok, t()} | {:error, term()}
  def send_message(%__MODULE__{pid: pid} = state, message) when is_map(message) do
    case GenServer.call(pid, {:send, message}) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.call(pid, :close)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  # -- GenServer callbacks --------------------------------------------------

  @impl GenServer
  @spec init({:self, pid() | nil} | {:spawn, String.t(), [String.t()], keyword(), pid() | nil}) ::
          {:ok, server_state()}
  def init({:self, owner}) do
    port = Port.open({:fd, 0, 1}, [:binary, :eof])
    {:ok, %{owner: owner, port: port, mode: :self, framer: Framer.new(), closed: false}}
  end

  def init({:spawn, path, args, spawn_opts, owner}) do
    port_opts = [:binary, :exit_status, args: args] ++ build_spawn_opts(spawn_opts)
    port = Port.open({:spawn_executable, String.to_charlist(path)}, port_opts)
    {:ok, %{owner: owner, port: port, mode: :spawn, framer: Framer.new(), closed: false}}
  end

  @spec build_spawn_opts(keyword()) :: keyword()
  defp build_spawn_opts(opts) do
    Enum.flat_map(opts, fn
      {:cd, cd} -> [cd: cd]
      {:env, env} -> [env: env]
      _other -> []
    end)
  end

  @impl GenServer
  def handle_call({:set_owner, owner}, _from, state) when is_pid(owner) do
    {:reply, :ok, %{state | owner: owner}}
  end

  def handle_call({:send, _message}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, message}, _from, %{port: port} = state) do
    line = Jason.encode!(message) <> "\n"

    try do
      Port.command(port, line)
      {:reply, :ok, state}
    rescue
      ArgumentError -> {:reply, {:error, :closed}, %{state | closed: true}}
    end
  end

  def handle_call(:close, _from, %{closed: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, %{port: port} = state) do
    safe_close_port(port)
    {:reply, :ok, %{state | closed: true}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port, closed: false} = state) do
    {frames, framer} = Framer.push(state.framer, data)
    Enum.each(frames, &deliver_frame(state.owner, &1))
    {:noreply, %{state | framer: framer}}
  end

  def handle_info({port, {:data, _data}}, %{port: port, closed: true} = state) do
    # Already closed locally (or the peer already signalled exit); drop
    # further inbound bytes rather than deliver past the closed boundary.
    {:noreply, state}
  end

  def handle_info({port, :eof}, %{port: port, closed: false} = state) do
    deliver_closed(state.owner, :eof)
    {:noreply, %{state | closed: true}}
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, closed: false} = state) do
    deliver_closed(state.owner, {:exit_status, code})
    {:noreply, %{state | closed: true}}
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Raxol.AgentClientProtocol.Transport.Stdio: unexpected message #{inspect(msg)}")

    {:noreply, state}
  end

  # -- Framing ---------------------------------------------------------------

  # A `Framer.push/2` result is either a complete NDJSON line (still raw
  # text -- decode it) or an oversized-frame error the framer already
  # detected and resynced past (no raw bytes to hand back -- the framer
  # deliberately does not retain them, see its moduledoc).
  @spec deliver_frame(pid() | nil, Framer.frame_or_error()) :: :ok
  defp deliver_frame(owner, {:error, {:frame_too_large, _size} = reason}) do
    deliver_to_owner(owner, {:decode_error, reason, ""})
  end

  defp deliver_frame(owner, line) when is_binary(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> deliver_to_owner(owner, {:message, map})
      {:ok, other} -> deliver_to_owner(owner, {:decode_error, {:not_an_object, other}, line})
      {:error, reason} -> deliver_to_owner(owner, {:decode_error, reason, line})
    end
  end

  @spec deliver_to_owner(pid() | nil, {:message, map()} | {:decode_error, term(), binary()}) ::
          :ok
  defp deliver_to_owner(nil, _payload), do: :ok

  defp deliver_to_owner(owner, payload) do
    send(owner, {:acp_transport, self(), payload})
    :ok
  end

  @spec deliver_closed(pid() | nil, term()) :: :ok
  defp deliver_closed(nil, _reason), do: :ok

  defp deliver_closed(owner, reason) do
    send(owner, {:acp_transport, self(), {:closed, reason}})
    :ok
  end

  @spec safe_close_port(port()) :: :ok
  defp safe_close_port(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
