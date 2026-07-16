defmodule Raxol.AgentClientProtocol.Ctx do
  @moduledoc """
  Ergonomic DX layer for agent handler code running **inside `session/prompt`
  turn tasks** (the functions a `turn_runner` closure or one of its subagent
  tasks actually calls). This module introduces **no new runtime semantics**:
  every function here is a thin, documented wrapper over
  `Raxol.AgentClientProtocol.Connection.request/4` (the agent->client
  filesystem/terminal/permission requests) or
  `Raxol.AgentClientProtocol.Session.post_update/2` /
  `Session.request_permission/2` (the Session-owned turn primitives) — see
  IC-3 in both `scratchpad/specs/acp-connection-design.md` and
  `acp-supervision-design.md` for the outbound API contract these wrap.

  ## Why this isn't built on `Connection.Ctx`

  `Raxol.AgentClientProtocol.Connection.Ctx` (IC-2) is the per-DISPATCH
  struct handed to the request/notification handler callback that answers
  `session/prompt` itself (it carries `conn`, `reply_ref`, `rx_seq`, etc.).
  It does **not** reach the turn task the handler spawns — `turn_runner` is
  injected at `Session` start with a fixed `(session_pid, req) -> ...`
  arity-2 shape (`session.ex` moduledoc, "Turn runner seam"), and a
  subagent's task closure only ever receives what its parent closed over.
  There is deliberately **one** ctx concept in this package
  (`Connection.Ctx`, IC-2); this module does not introduce a second,
  competing one. Instead every function below takes the plain pid a turn
  task actually has in hand — the `Connection` pid (closed over from the
  original dispatch's `ctx.conn` when the app builds its `turn_runner` fun)
  for the outbound protocol requests, or the `Session` pid (the task's own
  `session` argument) for the two Session-owned primitives.

  ## What's here

    * `read_text_file/3,4`, `write_text_file/4,5` — `fs/read_text_file` /
      `fs/write_text_file`, sent via `Connection.request/4` (plain
      handler-task code per IC-3 — "Any process that must stay responsive
      ... MUST use async_request; request/4 is for plain handler-task
      code", and a turn task is exactly that, not the Session itself).
    * `create_terminal/3,4`, `terminal_output/3,4`, `wait_for_terminal_exit/3,4`,
      `kill_terminal/3,4`, `release_terminal/3,4` — the five `terminal/*`
      methods, same `Connection.request/4` wrapper.
    * `request_permission/3,4` — builds a `RequestPermissionRequest` and
      delegates to `Session.request_permission/2`. **Fail-closed, always**:
      per supervision design §5/I8, the ONLY way to get an allow back is a
      literal `{:selected, %SelectedPermissionOutcome{}}` decoded from the
      client's reply; every other terminal (timeout, client error, decode
      failure, disconnect, a `session/cancel` racing the ask) resolves
      `{:ok, :cancelled}` — deny is the zero value everywhere. This wrapper
      adds no new fail-closed logic; it is documentation + ergonomics over
      the Session's existing guarantee.
    * `post_update/2` — delegates to `Session.post_update/2` verbatim (same
      arity, same contract): forwards a `session/update` for the live turn,
      surfacing `{:error, :turn_over}` for a straggler post after drain
      (§3.3) and, as of the streaming guards below, `{:error, :empty_chunk}`
      for an empty-text `agent_message_chunk`/`agent_thought_chunk` (never
      sent to the wire — see `session.ex`'s `empty_chunk?/1`).

  ## Timeouts

  `Connection.request/4`'s `timeout_ms` is `pos_integer()` — **not**
  `:infinity` (only `async_request/6` accepts that, per IC-3). Every
  function below takes a `:timeout` option (default `30_000`ms, except
  `wait_for_terminal_exit/3,4` which defaults to 30 minutes since waiting
  for a command to exit is expected to take a while); pass a larger
  `:timeout` explicitly for a longer-running command rather than relying on
  a library-invented unbounded wait.
  """

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.{
    CreateTerminalRequest,
    CreateTerminalResponse,
    KillTerminalRequest,
    KillTerminalResponse,
    PermissionOption,
    ReadTextFileRequest,
    ReadTextFileResponse,
    ReleaseTerminalRequest,
    ReleaseTerminalResponse,
    RequestPermissionRequest,
    SelectedPermissionOutcome,
    TerminalOutputRequest,
    TerminalOutputResponse,
    WaitForTerminalExitRequest,
    WaitForTerminalExitResponse,
    WriteTextFileRequest,
    WriteTextFileResponse
  }

  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Session

  @default_timeout 30_000
  @wait_for_exit_timeout :timer.minutes(30)

  # ===========================================================================
  # fs/read_text_file, fs/write_text_file
  # ===========================================================================

  @doc """
  `fs/read_text_file` — read a text file on the client side. `opts`:
  `:line` (1-based start line), `:limit` (max lines), `:timeout`
  (default `#{@default_timeout}`ms). Only sent if the client declared the
  `fs.readTextFile` capability (the client answers `-32601` otherwise —
  MethodTable's capability gate, unrelated to this wrapper).
  """
  @spec read_text_file(pid(), String.t(), String.t(), keyword()) ::
          {:ok, ReadTextFileResponse.t()} | {:error, term()}
  def read_text_file(conn, session_id, path, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(path) do
    base = ReadTextFileRequest.new(session_id, path)

    req = %{
      base
      | line: Keyword.get(opts, :line, base.line),
        limit: Keyword.get(opts, :limit, base.limit)
    }

    Connection.request(conn, "fs/read_text_file", req, timeout(opts))
  end

  @doc """
  `fs/write_text_file` — write `content` to a text file on the client side.
  `opts`: `:timeout` (default `#{@default_timeout}`ms). Only sent if the
  client declared the `fs.writeTextFile` capability.
  """
  @spec write_text_file(pid(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, WriteTextFileResponse.t()} | {:error, term()}
  def write_text_file(conn, session_id, path, content, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(path) and is_binary(content) do
    req = WriteTextFileRequest.new(session_id, path, content)
    Connection.request(conn, "fs/write_text_file", req, timeout(opts))
  end

  # ===========================================================================
  # session/request_permission
  # ===========================================================================

  @doc """
  Ask the client for permission to perform `tool_call` (`session/request_permission`),
  offering `options`. Delegates to `Session.request_permission/2` — `session`
  is the turn's own `Session` pid (the task's `session` argument), NOT the
  Connection. **Fail-closed** (supervision design §5/I8): returns
  `{:ok, {:selected, %SelectedPermissionOutcome{}}}` ONLY on a decoded
  selected outcome; every other terminal — timeout, client error reply,
  undecodable reply, transport/connection death, or a `session/cancel`
  racing the ask — returns `{:ok, :cancelled}`. There is no third outcome
  and no exception path: deny is the zero value everywhere. The Session
  arms no timer of its own for this wait; `Connection.async_request/6`
  (IC-3) is the single timeout authority, configured per-connection via
  the Session's `:permission_timeout` (default 600s).
  """
  @spec request_permission(GenServer.server(), String.t(), ToolCallUpdate.t(), [
          PermissionOption.t()
        ]) ::
          {:ok, {:selected, SelectedPermissionOutcome.t()}} | {:ok, :cancelled}
  def request_permission(session, session_id, tool_call, options \\ [])
      when is_binary(session_id) and is_list(options) do
    req = RequestPermissionRequest.new(session_id, tool_call, options)
    Session.request_permission(session, req)
  end

  # ===========================================================================
  # session/update (post_update pass-through)
  # ===========================================================================

  @doc """
  Emit a `session/update` for the live turn — a verbatim pass-through to
  `Session.post_update/2` (same arity, same contract): forwards `notification`
  via the Connection's `notify/3` on the Session's own FIFO lane (I3), returns
  `{:error, :turn_over}` for a straggler post after the turn has drained
  (§3.3), and `{:error, :empty_chunk}` for an empty-text `agent_message_chunk`/
  `agent_thought_chunk` — the streaming guard lives in `session.ex`
  (`empty_chunk?/1`); this wrapper adds no logic of its own, only the
  re-export so handler code has one module to `alias`.
  """
  @spec post_update(GenServer.server(), SessionNotification.t()) ::
          :ok | {:error, :turn_over} | {:error, :empty_chunk}
  def post_update(session, notification), do: Session.post_update(session, notification)

  # ===========================================================================
  # terminal/*
  # ===========================================================================

  @doc """
  `terminal/create` — create a terminal and execute `command`. `opts`:
  `:args` ([String.t()]), `:env` (list of `{name, value}` string pairs or
  pre-built `EnvVariable.t()` structs), `:cwd`, `:output_byte_limit`,
  `:timeout` (default `#{@default_timeout}`ms). Only sent if the client
  declared the `terminal` capability.
  """
  @spec create_terminal(pid(), String.t(), String.t(), keyword()) ::
          {:ok, CreateTerminalResponse.t()} | {:error, term()}
  def create_terminal(conn, session_id, command, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(command) do
    req = build_create_terminal_request(session_id, command, opts)
    Connection.request(conn, "terminal/create", req, timeout(opts))
  end

  @doc "`terminal/output` — the output captured so far, and exit status if the command has completed. `opts`: `:timeout`."
  @spec terminal_output(pid(), String.t(), String.t(), keyword()) ::
          {:ok, TerminalOutputResponse.t()} | {:error, term()}
  def terminal_output(conn, session_id, terminal_id, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(terminal_id) do
    req = TerminalOutputRequest.new(session_id, terminal_id)
    Connection.request(conn, "terminal/output", req, timeout(opts))
  end

  @doc """
  `terminal/wait_for_exit` — block until the terminal command exits. `opts`:
  `:timeout` (default `#{@wait_for_exit_timeout}`ms = 30 minutes, since
  waiting for a command is expected to take a while; `request/4` does not
  accept `:infinity` — pass an explicit larger `:timeout` for a
  longer-running command instead).
  """
  @spec wait_for_terminal_exit(pid(), String.t(), String.t(), keyword()) ::
          {:ok, WaitForTerminalExitResponse.t()} | {:error, term()}
  def wait_for_terminal_exit(conn, session_id, terminal_id, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(terminal_id) do
    req = WaitForTerminalExitRequest.new(session_id, terminal_id)
    Connection.request(conn, "terminal/wait_for_exit", req, timeout(opts, @wait_for_exit_timeout))
  end

  @doc "`terminal/kill` — kill the terminal's command without releasing the terminal. `opts`: `:timeout`."
  @spec kill_terminal(pid(), String.t(), String.t(), keyword()) ::
          {:ok, KillTerminalResponse.t()} | {:error, term()}
  def kill_terminal(conn, session_id, terminal_id, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(terminal_id) do
    req = KillTerminalRequest.new(session_id, terminal_id)
    Connection.request(conn, "terminal/kill", req, timeout(opts))
  end

  @doc "`terminal/release` — release a terminal and free its resources. `opts`: `:timeout`."
  @spec release_terminal(pid(), String.t(), String.t(), keyword()) ::
          {:ok, ReleaseTerminalResponse.t()} | {:error, term()}
  def release_terminal(conn, session_id, terminal_id, opts \\ [])
      when is_pid(conn) and is_binary(session_id) and is_binary(terminal_id) do
    req = ReleaseTerminalRequest.new(session_id, terminal_id)
    Connection.request(conn, "terminal/release", req, timeout(opts))
  end

  # -- internals ----------------------------------------------------------------

  defp timeout(opts, default \\ @default_timeout), do: Keyword.get(opts, :timeout, default)

  defp build_create_terminal_request(session_id, command, opts) do
    base = CreateTerminalRequest.new(session_id, command)

    %{
      base
      | args: Keyword.get(opts, :args, base.args),
        env: build_env(Keyword.get(opts, :env, base.env)),
        cwd: Keyword.get(opts, :cwd, base.cwd),
        output_byte_limit: Keyword.get(opts, :output_byte_limit, base.output_byte_limit)
    }
  end

  defp build_env(env) when is_list(env) do
    Enum.map(env, fn
      %EnvVariable{} = e -> e
      {name, value} -> EnvVariable.new(name, value)
    end)
  end

  defp build_env(_other), do: []
end
