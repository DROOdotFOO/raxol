defmodule Raxol.Symphony.Runners.Codex.Session do
  @moduledoc """
  Port-backed session for the Codex app-server.

  Spawns `bash -lc <codex.command>` inside the workspace via `Port.open/2`,
  performs the `initialize` -> `initialized` -> `thread/start` handshake, and
  then drives one or more `turn/start` cycles over the same stdio session.

  Inbound messages are pushed through `Codex.Framing` (line buffered) and
  decoded with `Codex.Protocol`. Notifications, tool calls, and approval
  requests are emitted to `:on_event` (a 1-arity callback) as Symphony
  event maps; the receive loop continues until a terminal `turn/completed`
  / `turn/failed` / `turn/cancelled` arrives.

  This module owns the calling process's mailbox during `start/3` and
  `run_turn/4`. Run it inside a `Task` (which is what the orchestrator does).
  """

  require Logger

  alias Raxol.Symphony.PortReaper
  alias Raxol.Symphony.Runners.Codex.{Framing, Protocol}
  alias Raxol.Symphony.Ssh
  alias Raxol.Symphony.Worker.HostSpec

  @type session :: %{
          required(:port) => port(),
          required(:thread_id) => binary(),
          required(:workspace) => Path.t(),
          required(:policy) => map(),
          required(:turn_id) => pos_integer(),
          optional(:reaper) => PortReaper.watcher(),
          optional(:reap_target) => PortReaper.target(),
          optional(:stop_grace_ms) => non_neg_integer()
        }

  @type policy :: %{
          required(:approval_policy) => binary(),
          required(:thread_sandbox) => binary(),
          required(:turn_sandbox_policy) => map(),
          required(:read_timeout_ms) => pos_integer(),
          required(:turn_timeout_ms) => pos_integer(),
          required(:auto_approve?) => boolean(),
          required(:dynamic_tools) => list()
        }

  @port_line_bytes 1_048_576
  @default_turn_id 100

  # How long a codex gets to act on the EOF `stop/1` delivers before it is
  # killed. Long enough for a clean app-server shutdown, short enough that it
  # cannot stall the orchestrator's `after` block -- and the ordinary case does
  # not spend it, since polling stops the moment the process group drains.
  @stop_grace_ms 2_000

  # A remote session's port child is the local `ssh` client, and `ssh` does NOT
  # exit on stdin EOF. Its clean teardown is a round trip: the EOF crosses the
  # network, the remote codex exits, the remote `wait` returns, `ssh` follows.
  # A local-sized budget SIGKILLs a perfectly well-behaved client partway
  # through that.
  #
  # Nothing is stranded either way -- `Ssh.reap_on_disconnect/2` catches the
  # far side on disconnect -- but that path costs a poll interval and reaps the
  # remote codex with a signal instead of letting it exit on the EOF, so it is
  # worth waiting to avoid.
  @remote_stop_grace_ms 10_000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a Codex app-server session in `workspace`.

  `command` is the shell command Codex was launched with (per `codex.command`).
  `host` (a `Raxol.Symphony.Worker.HostSpec` or `nil`) routes the session to a
  remote worker over SSH when present; `nil` runs it locally (the default).
  """
  @spec start(Path.t(), binary(), policy(), [{charlist(), charlist()}], HostSpec.t() | nil) ::
          {:ok, session()} | {:error, term()}
  def start(workspace, command, %{} = policy, env \\ [], host \\ nil)
      when is_binary(workspace) and is_binary(command) and is_list(env) do
    with {:ok, bash} <- find_bash(),
         {:ok, port} <- open_port(host, bash, command, workspace, env) do
      handshake(port, workspace, policy, host)
    end
  end

  defp handshake(port, workspace, policy, host) do
    grace_ms = stop_grace_ms(host)

    # Watched from the moment the child exists, because from here on an
    # untrappable exit skips `stop/1` entirely -- and the orchestrator tears
    # workers down exactly that way (`stop_run`, stall detection,
    # reconcile-kill), so `try/after` never runs.
    #
    # The target is kept as well as watched. It is readable only while the port
    # is open, and the paths that need it most are the ones where it no longer
    # is: a codex that exits on its own closes its own port, and `stop/1` then
    # has nothing left to capture.
    target = PortReaper.capture(port)
    reaper = PortReaper.watch(target)

    with :ok <- send_initialize(port, policy.read_timeout_ms),
         {:ok, thread_id} <- send_thread_start(port, workspace, policy) do
      {:ok,
       %{
         port: port,
         thread_id: thread_id,
         workspace: workspace,
         policy: policy,
         turn_id: @default_turn_id,
         reaper: reaper,
         reap_target: target,
         stop_grace_ms: grace_ms
       }}
    else
      {:error, _} = err ->
        # A handshake that fails has still left a codex running, and only a
        # session that was built ever reaches `stop/1`. The usual reason to be
        # here is a codex that died answering `initialize`, which has already
        # closed the port -- so the captured target is the only one there is.
        stop_port(port, grace_ms, target)
        PortReaper.release(reaper)
        err
    end
  end

  @doc false
  @spec stop_grace_ms(HostSpec.t() | nil) :: pos_integer()
  def stop_grace_ms(nil), do: @stop_grace_ms
  def stop_grace_ms(%HostSpec{}), do: @remote_stop_grace_ms

  @doc """
  Drives one turn against an active session.

  Returns `:ok` when the turn completes, or `{:error, reason}` on
  `turn/failed`, `turn/cancelled`, approval denial, port exit, or timeout.
  """
  @spec run_turn(session(), binary(), map(), (map() -> any())) ::
          {:ok, session()} | {:error, term()}
  def run_turn(%{} = session, prompt, %{} = issue, on_event)
      when is_binary(prompt) and is_function(on_event, 1) do
    send_turn_start(session, prompt, issue)

    case await_response(session.port, session.turn_id, session.policy.read_timeout_ms, "") do
      {:ok, %{"turn" => %{"id" => turn_label}}} ->
        emit_session_started(on_event, session, turn_label)
        receive_turn(session, on_event, "")

      {:ok, _other} ->
        {:error, :invalid_turn_response}

      {:error, _} = err ->
        err
    end
  end

  defp send_turn_start(session, prompt, issue) do
    payload =
      Protocol.turn_start_request(
        session.turn_id,
        session.thread_id,
        session.workspace,
        prompt,
        issue,
        approval_policy: session.policy.approval_policy,
        turn_sandbox_policy: session.policy.turn_sandbox_policy
      )

    send_payload(session.port, payload)
  end

  @doc """
  Closes the Port, reaps whatever the session left running, and drains any
  residual messages.

  Closing the port delivers the EOF a stdio server treats as "shut down", and a
  codex that is reading its stdin exits on it. That covers the ordinary case and
  only the ordinary case, so it is not the whole of stopping a session:

    * a codex that is NOT reading stdin -- wedged, or busy inside a turn --
      never sees the EOF and keeps running.
    * the tool subprocesses codex spawned are not its stdin's business at all.
      They survive a parent that exited perfectly cleanly, reparented to init,
      still holding the workspace open. Measured: parent gone, orphan still
      running.

  So the EOF is given first and a group kill backs it up. The grace window is
  what keeps a well-behaved codex on the clean path -- it gets to flush and exit
  on its own terms, and the kill only reaches a session that would otherwise
  have been left behind. A remote session gets a longer one, since `ssh` does
  not exit on EOF and its clean teardown is a network round trip.

  This is the ordinary path. It does not run at all when the caller is killed
  outright, which is what `PortReaper.watch/1` covers.
  """
  @spec stop(session() | port()) :: :ok
  def stop(%{port: port} = session) do
    result =
      stop_port(
        port,
        Map.get(session, :stop_grace_ms) || @stop_grace_ms,
        Map.get(session, :reap_target, :none)
      )

    # Released last: until the reap has actually happened the watcher is the
    # only thing still covering us if this process dies mid-stop.
    PortReaper.release(Map.get(session, :reaper))
    result
  end

  # A bare port has no start-up target to fall back on, so a codex that has
  # already closed its own port takes its orphans with it unreaped. Callers with
  # a session map do not have that gap.
  def stop(port) when is_port(port), do: stop_port(port, @stop_grace_ms, :none)

  def stop(_), do: :ok

  defp stop_port(port, grace_ms, captured_at_start) do
    # Re-read while the port is open, since that answer is current. It is only
    # available while the port IS open, though: every path where the codex exits
    # on its own -- `{:error, {:port_exit, _}}` out of either receive loop, and
    # the handshake failures -- gets here with the port already closed by the
    # VM, and `capture/1` can only answer `:none`.
    #
    # Falling back to what start-up captured is what makes those paths reap at
    # all. Its staleness is bounded the same way the watcher's is: a group id
    # cannot be recycled while the group still has a member, so the fallback is
    # exact for as long as there is anything to kill.
    target = current_or_captured(PortReaper.capture(port), captured_at_start)
    close_port(port)

    case PortReaper.await_exit(target, grace_ms) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "symphony.runners.codex.session_unreaped target=#{inspect(target)} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  end

  defp current_or_captured(:none, captured_at_start), do: captured_at_start
  defp current_or_captured(current, _captured_at_start), do: current

  # ---------------------------------------------------------------------------
  # Handshake
  # ---------------------------------------------------------------------------

  defp send_initialize(port, timeout_ms) do
    send_payload(port, Protocol.initialize_request())

    with {:ok, _} <- await_response(port, Protocol.initialize_id(), timeout_ms, "") do
      send_payload(port, Protocol.initialized_notification())
      :ok
    end
  end

  defp send_thread_start(port, workspace, policy) do
    payload =
      Protocol.thread_start_request(workspace,
        approval_policy: policy.approval_policy,
        thread_sandbox: policy.thread_sandbox,
        dynamic_tools: policy.dynamic_tools
      )

    send_payload(port, payload)

    case await_response(port, Protocol.thread_start_id(), policy.read_timeout_ms, "") do
      {:ok, %{"thread" => %{"id" => thread_id}}} when is_binary(thread_id) ->
        {:ok, thread_id}

      {:ok, other} ->
        {:error, {:invalid_thread_payload, other}}

      {:error, _} = err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Receive loops
  # ---------------------------------------------------------------------------

  defp await_response(port, request_id, timeout_ms, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Framing.push(buffer, {:eol, chunk}) do
          {:line, line, _} -> handle_response_line(port, request_id, timeout_ms, line)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:partial, new_buffer} = Framing.push(buffer, {:noeol, chunk})
        await_response(port, request_id, timeout_ms, new_buffer)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response_line(port, request_id, timeout_ms, line) do
    case Framing.decode(line) do
      {:ok, :empty} ->
        await_response(port, request_id, timeout_ms, "")

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id, "error" => err}} ->
        {:error, {:response_error, err}}

      {:ok, %{"id" => ^request_id} = response} ->
        {:error, {:response_error, response}}

      {:ok, _other} ->
        await_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json(line, "handshake")
        await_response(port, request_id, timeout_ms, "")
    end
  end

  defp receive_turn(%{port: port, policy: policy} = session, on_event, buffer) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        case Framing.push(buffer, {:eol, chunk}) do
          {:line, line, _} -> handle_turn_line(session, on_event, line)
        end

      {^port, {:data, {:noeol, chunk}}} ->
        {:partial, new_buffer} = Framing.push(buffer, {:noeol, chunk})
        receive_turn(session, on_event, new_buffer)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      policy.turn_timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_turn_line(session, on_event, line) do
    case Framing.decode(line) do
      {:ok, :empty} ->
        receive_turn(session, on_event, "")

      {:ok, payload} ->
        dispatch(session, on_event, payload)

      {:error, _} ->
        log_non_json(line, "turn")
        receive_turn(session, on_event, "")
    end
  end

  defp dispatch(session, on_event, payload),
    do: handle_classification(Protocol.classify(payload), session, on_event)

  defp handle_classification({:turn_completed, event}, session, on_event) do
    on_event.(event)
    {:ok, %{session | turn_id: session.turn_id + 1}}
  end

  defp handle_classification({:turn_failed, event, reason}, _session, on_event) do
    on_event.(event)
    {:error, reason}
  end

  defp handle_classification({:tool_call, id, name, args, event}, session, on_event) do
    on_event.(event)
    result = unsupported_tool_response(name, args)
    send_payload(session.port, Protocol.tool_call_result(id, result))
    receive_turn(session, on_event, "")
  end

  defp handle_classification({:approval, id, decision, event}, session, on_event) do
    on_event.(event)
    handle_approval(session, on_event, id, decision)
  end

  defp handle_classification({:input_required, event, reason}, _session, on_event) do
    on_event.(event)
    {:error, {:input_required, reason}}
  end

  defp handle_classification({:notification, event}, session, on_event) do
    on_event.(event)
    receive_turn(session, on_event, "")
  end

  defp handle_classification({:response, _payload}, session, on_event) do
    # Stray result from an out-of-band request -- ignore and keep listening.
    receive_turn(session, on_event, "")
  end

  defp handle_classification(:ignore, session, on_event),
    do: receive_turn(session, on_event, "")

  defp handle_approval(%{policy: %{auto_approve?: true}} = session, on_event, id, decision) do
    send_payload(session.port, Protocol.approval_result(id, decision))
    receive_turn(session, on_event, "")
  end

  defp handle_approval(_session, _on_event, _id, decision),
    do: {:error, {:approval_required, decision}}

  defp unsupported_tool_response(name, _args) do
    %{
      "success" => false,
      "output" =>
        "Dynamic tool #{inspect(name)} is not registered with this Symphony deployment.",
      "contentItems" => [
        %{"type" => "inputText", "text" => "Unsupported dynamic tool: #{inspect(name)}"}
      ]
    }
  end

  defp emit_session_started(on_event, %{thread_id: thread_id}, turn_label) do
    on_event.(%{
      event: :session_started,
      message: "session #{thread_id}/#{turn_label}",
      payload: %{"thread_id" => thread_id, "turn_id" => turn_label},
      timestamp: DateTime.utc_now()
    })
  end

  # ---------------------------------------------------------------------------
  # Port lifecycle
  # ---------------------------------------------------------------------------

  defp find_bash do
    case System.find_executable("bash") do
      nil -> {:error, :bash_not_found}
      path -> {:ok, path}
    end
  end

  defp open_port(host, bash, command, workspace, env) do
    with {:ok, {executable, opts}} <- launch_spec(host, bash, command, workspace, env) do
      {:ok, Port.open({:spawn_executable, executable}, opts)}
    end
  rescue
    e -> {:error, {:port_open_failed, e}}
  end

  # Pure: the `{executable, Port.open-opts}` for a local or remote launch.
  #
  # Local (`host == nil`): `bash -lc command`, cwd via `{:cd, workspace}`, env
  # injected into the child. Remote (`%HostSpec{}`): `ssh <opts> host
  # "bash -lc 'cd WS && command'"` — the remote login shell sources
  # host-provisioned credentials, so no env is forwarded (see
  # `Raxol.Symphony.Ssh`). Codex's JSON-RPC then streams over the port's
  # stdio unchanged, whether that stdio is local bash or an ssh pipe.
  @doc false
  @spec launch_spec(HostSpec.t() | nil, binary(), binary(), Path.t(), list()) ::
          {:ok, {binary(), keyword()}} | {:error, term()}
  def launch_spec(nil, bash, command, workspace, env) do
    opts = base_port_opts() ++ [{:cd, workspace}, {:args, ["-lc", command]}]

    # Only add {:env, _} when there is something to inject: an empty list still
    # scopes the child to an explicit env on some OTP versions, so `:inherit`
    # (env == []) must pass through untouched to keep the ambient environment.
    opts = if env == [], do: opts, else: opts ++ [{:env, env}]

    {:ok, {bash, opts}}
  end

  def launch_spec(%HostSpec{} = host, _bash, command, workspace, _env) do
    with {:ok, ssh} <- Ssh.executable() do
      # Reap the remote codex on disconnect so a `Port.close` (worker stop /
      # pause / crash) never orphans it on the host.
      remote = Ssh.remote_bash(workspace, Ssh.reap_on_disconnect(command))
      args = Ssh.command_args(host, remote)
      {:ok, {ssh, base_port_opts() ++ [{:args, args}]}}
    end
  end

  defp base_port_opts do
    [:binary, :exit_status, :stderr_to_stdout, :hide, {:line, @port_line_bytes}]
  end

  defp close_port(port) do
    PortReaper.close(port)
    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  defp send_payload(port, payload) do
    Port.command(port, Framing.encode!(payload))
  end

  defp log_non_json(line, label) do
    trimmed = line |> String.trim() |> String.slice(0, 200)

    if trimmed != "" do
      Logger.debug("symphony.codex.non_json #{label}: #{trimmed}")
    end
  end
end
