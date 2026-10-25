defmodule Raxol.Agent.OMP.RPC do
  @moduledoc """
  A client for one `omp --mode rpc` session (ADR-0042, decision 7).

  `start_link/1` checks the options, resolves and vets the binary
  (`Raxol.Agent.Backend.OmpGateway.resolve_binary/1`) and returns at once.
  The handshake then runs in the session process: `omp --version` is
  checked against the tested pin (`Raxol.Agent.OMP.Version`; a different
  major is refused, another minor logged), `omp --mode rpc --approval-mode
  write --profile <profile>` is spawned in a dedicated working directory,
  the ready frame must offer protocol v2, and `negotiate_protocol` v2 must
  succeed. `await_ready/2` waits for that; a request sent before it is
  refused with `{:error, :not_ready}`. A failed handshake stops the process
  with the reason, which `await_ready/2` returns. From then on a frame over
  OMP's `maxFrameBytes` arrives as `rpc_chunk` lines, which are reassembled
  (`Raxol.Agent.OMP.RPC.Codec`).

  `--no-ui` is never passed: with it, a tool that needs approval fails
  closed with no frame at all. Without it, OMP asks over the wire.

  ## The profile and the working directory

  The profile must already be provisioned: OMP exits 1 before its ready
  frame on a profile with no usable model, and the handshake fails with
  `{:omp_exit, 1}`.

  `:cwd` is the session's own directory. OMP loads and runs a working
  directory's `.omp/extensions`, rules and context files inside the process
  that holds every credential OMP has, so the BEAM's cwd (possibly a cloned,
  untrusted workspace) is refused, and so is any directory inside it. Both
  are compared by file identity (device and inode), walking the real
  ancestors of `:cwd`, so a symlink or another spelling of the same
  directory (`/tmp` and `/private/tmp` on macOS) is refused too. A directory
  not owned by this account or writable by its group or others is refused
  as well (`Raxol.Agent.OperatorFile.owned_unshared/2`).

  OMP also loads the `AGENTS.md` of every ancestor of `:cwd` into the
  session's system prompt (its `.omp/extensions` do not run). Pick a `:cwd`
  under a state directory whose ancestors hold no context files, never
  under a workspace.

  ## The environment

  OMP and every tool it runs see only an allowlist of the BEAM's
  environment: `HOME`, `PATH`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`,
  `TERM`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TZ`, the XDG base directories,
  OMP's own `PI_CODING_AGENT_DIR` and `PI_CONFIG_DIR`, and the HTTP proxy
  variables. Everything else (a bot token, `OP_SERVICE_ACCOUNT_TOKEN`, a
  wallet or provider key) is unset in the spawned process, because a port's
  `:env` only overlays the parent's environment. A variable OMP needs
  beyond these is passed explicitly with `:env`.

  ## Requests and events

  `request/3` sends one command and waits for the response with the same
  id; OMP answers in completion order (`bash` and `prompt` can answer after
  later commands). The command is encoded in the caller, so a command that
  cannot be sent fails its own request and never this process. Every other
  frame goes to the subscriber (`:subscriber`) as `{:omp_rpc, pid, frame}`,
  including a response that arrives after its request's deadline and OMP's
  later error response for a prompt it had already admitted.

  A prompt is answered when OMP admits it; its outcome arrives as a
  `prompt_result` frame (or as `data.agentInvoked: false` on the response
  when it finished locally).

  ## Dialogs

  Every `extension_ui_request` that waits for an answer gets one. A tool
  approval select goes to the principal (`:principal`) as
  `{:omp_rpc_approval, pid, ui_id, frame}`; the principal answers with one
  of the frame's `options` through `answer/3`, which refuses an answer from
  any other process (the subscriber sees the frame too). The relayed
  `options` never offer a grant OMP would persist beyond the session (its
  `alwaysLabel` options, `Codec.ui_request/1`), and `answer/3` refuses one.

  An approval is denied when nobody can answer it: with no principal, once
  the principal exits, when `:approval_timeout_ms` passes without an answer
  (the deadline is this process's timer, so it holds whatever the principal
  does), and on `close/2`. The principal then gets
  `{:omp_rpc_approval_closed, pid, ui_id, reason}` (`:timeout`, `:closing`,
  or `:cancelled` when OMP withdrew the dialog). Every other dialog is
  cancelled. Presentation frames (`setWidget`, `notify`, ...) need no answer
  and are only forwarded.

  ## Teardown

  `close/2` denies every open approval, and every approval asked while it
  waits, then tears the session down once it is settled: after OMP's
  `session_settled` frame, or, for a prompt that never reached the agent,
  its `prompt_result` with `sessionSettled: true` (OMP sends no
  `session_settled` then). A session with no agent activity is settled. If
  the session does not settle in time, `close/2` returns
  `{:error, {:settle_timeout, ms}}` and the session keeps running: an agent
  run can keep it unsettled. To end it anyway, send `%{"type" => "abort"}`
  and close again, or stop the process (`GenServer.stop/1`).

  However the process stops, it first sends OMP `abort` and `abort_bash`,
  then closes OMP's stdin. On EOF OMP finishes the commands it accepted
  before it exits, so without the aborts an RPC `bash` in flight would still
  run to its end after its caller was told `{:error, :rpc_down}`. A session
  stopped before its handshake finished is killed instead.

  ## Errors

  None carries a frame's text or a request's content.

  From `start_link/1` (the process stops with the same reason):
  `{:invalid_option, name}` (`:subscriber`, `:principal`, `:path`,
  `:ready_timeout_ms`, `:approval_timeout_ms`, `:env`), `:invalid_profile`,
  `{:invalid_cwd, reason}`
  (`:not_absolute`, `:beam_cwd`, `:inside_beam_cwd`,
  `{:not_a_directory, type}`, `{:not_owned, uid}`,
  `{:group_or_other_writable, mode}` or a posix error) and every
  `OmpGateway.resolve_binary/1` error.

  From the handshake, returned by `await_ready/2` (the process stops with
  the same reason): `{:omp_version_failed, status}`, `:omp_version_timeout`,
  `{:omp_refused, reason}` (a `Version.check/1` error),
  `{:omp_spawn_failed, reason}`, `{:omp_exit, status}` (exited before the
  handshake finished), `:rpc_ready_timeout` (no ready frame and negotiation
  within `:ready_timeout_ms` of the spawn; OMP is killed),
  `:invalid_ready_frame`, `:unsupported_protocol` and
  `{:negotiate_failed, code}`.

  From `request/3`: `{:invalid_request, reason}` (see
  `Codec.encode_command/1`; `:timeout` for a timeout that is not an integer
  from 0 to 2^32 - 1, `:too_large` for a line over OMP's `maxFrameBytes`),
  `:not_ready`, `{:rpc_error, code}` (OMP refused the command; `code` is
  OMP's machine-readable code or nil), `{:rpc_timeout, ms}`,
  `{:omp_exit, status}` (OMP exited with the request pending; the process
  stops with `{:shutdown, {:omp_exit, status}}`), `:rpc_not_started` and
  `:rpc_down`.

  A session is `restart: :temporary`: one that stopped is not replaced by a
  fresh OMP session nobody asked for.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Raxol.Agent.Backend.OmpGateway
  alias Raxol.Agent.OMP.RPC.Codec
  alias Raxol.Agent.OMP.Version
  alias Raxol.Agent.OperatorFile
  alias Raxol.Agent.SpawnedPort

  @default_ready_timeout_ms 15_000
  @default_approval_timeout_ms 120_000
  @default_request_timeout_ms 30_000
  @default_close_timeout_ms 60_000
  @version_timeout_ms 10_000
  @line_bytes 65_536
  # Until the ready frame says otherwise: OMP's documented physical limit.
  @default_frame_bytes 1_048_576
  # Sent as the process stops, before OMP's stdin closes.
  @aborts ["abort", "abort_bash"]
  # The largest delay `Process.send_after/3` accepts.
  @max_timeout_ms 4_294_967_295
  @profile ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @prompts ["prompt", "abort_and_prompt"]
  # What OMP and its tools inherit from the BEAM's environment (moduledoc).
  @env_allowlist ~w(HOME PATH USER LOGNAME SHELL TMPDIR TERM LANG LC_ALL LC_CTYPE TZ
                    XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME
                    PI_CODING_AGENT_DIR PI_CONFIG_DIR
                    HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)
  @env_name ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  @doc """
  Start a session; the handshake runs after this returns (see the
  moduledoc and `await_ready/2`).

  Options: `:profile` (required; the OMP profile name), `:cwd` (required;
  the session's absolute working directory), `:subscriber` (required; the
  pid that receives frames), `:path` (the `omp` binary; as for
  `OmpGateway.resolve_binary/1`), `:principal` (pid answering approvals;
  default none, so every approval is denied), `:approval_timeout_ms` (how
  long the principal has to answer an approval before it is denied; default
  #{@default_approval_timeout_ms}), `:env` (a map of extra environment
  variables for OMP, name to value; default none), `:ready_timeout_ms`
  (default #{@default_ready_timeout_ms}), `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @doc """
  Wait until the handshake has finished: `:ok`, the handshake's error from
  the moduledoc, `{:error, {:await_timeout, ms}}` when `timeout_ms` passed
  first (the session keeps starting), `:rpc_not_started` (no such process,
  for example one whose handshake already failed; its exit reason says why)
  or `:rpc_down`.

  The handshake is bounded on its own: at most the `omp --version` check
  (#{@version_timeout_ms} ms) plus `:ready_timeout_ms`.
  """
  @spec await_ready(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def await_ready(server, timeout_ms \\ :infinity)

  def await_ready(server, timeout_ms)
      when timeout_ms == :infinity or
             (is_integer(timeout_ms) and timeout_ms in 0..@max_timeout_ms) do
    GenServer.call(server, :await_ready, timeout_ms)
  catch
    :exit, {:timeout, _} -> {:error, {:await_timeout, timeout_ms}}
    :exit, {:noproc, _} -> {:error, :rpc_not_started}
    :exit, _reason -> {:error, :rpc_down}
  end

  def await_ready(_server, _timeout_ms), do: {:error, {:invalid_request, :timeout}}

  @doc """
  Send one command (a map with a string `type`, no `id`) and wait for its
  response: `{:ok, data}` or an error from the moduledoc.
  """
  @spec request(GenServer.server(), map(), non_neg_integer()) :: {:ok, term()} | {:error, term()}
  def request(server, command, timeout_ms \\ @default_request_timeout_ms)

  def request(server, command, timeout_ms)
      when is_integer(timeout_ms) and timeout_ms in 0..@max_timeout_ms do
    with {:ok, type, encoded} <- Codec.encode_command(command) do
      call(server, {:request, type, encoded, timeout_ms})
    end
  end

  def request(_server, _command, _timeout_ms), do: {:error, {:invalid_request, :timeout}}

  @doc """
  Answer approval `ui_id` with `value`, one of its `options`: `:ok`,
  `{:error, :not_principal}` (only the `:principal` may answer),
  `{:error, :invalid_choice}` (the approval stays open) or
  `{:error, :unknown_request}` (already answered, cancelled by OMP, or never
  asked).
  """
  @spec answer(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer(server, ui_id, value) when is_binary(ui_id) and is_binary(value),
    do: call(server, {:answer, ui_id, value})

  @doc """
  Tear the session down once it is settled (see the moduledoc): `:ok`, or
  `{:error, {:settle_timeout, ms}}` (the session keeps running; see the
  moduledoc for forcing it down), `{:error, {:omp_exit, status}}`,
  `{:error, :already_closing}`. A session whose handshake has not finished
  stops at once.
  """
  @spec close(GenServer.server(), non_neg_integer()) :: :ok | {:error, term()}
  def close(server, timeout_ms \\ @default_close_timeout_ms)

  def close(server, timeout_ms) when is_integer(timeout_ms) and timeout_ms in 0..@max_timeout_ms,
    do: call(server, {:close, timeout_ms})

  def close(_server, _timeout_ms), do: {:error, {:invalid_request, :timeout}}

  # The server answers every call by its deadline or on OMP's exit, so the
  # call itself needs no timeout of its own.
  defp call(server, message) do
    GenServer.call(server, message, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :rpc_not_started}
    :exit, _reason -> {:error, :rpc_down}
  end

  # -- startup ------------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- config(opts),
         {:ok, path} <- OmpGateway.resolve_binary(config.path) do
      {:ok, initial_state(config), {:continue, {:handshake, path, config}}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # The ready frame and the negotiation response arrive as port messages;
  # `:ready_deadline` bounds them.
  @impl true
  def handle_continue({:handshake, path, config}, state) do
    env = port_env(config.env)

    with :ok <- check_version(path, config.cwd, env),
         {:ok, port} <- open_port(path, config, env) do
      timer = Process.send_after(self(), :ready_deadline, config.ready_timeout_ms)
      {:noreply, %{state | port: port, os_pid: os_pid(port), ready_timer: timer}}
    else
      {:error, reason} -> handshake_failed(state, reason)
    end
  end

  defp config(opts) do
    config = %{
      path: Keyword.get(opts, :path),
      subscriber: Keyword.get(opts, :subscriber),
      principal: Keyword.get(opts, :principal),
      ready_timeout_ms: Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms),
      approval_timeout_ms: Keyword.get(opts, :approval_timeout_ms, @default_approval_timeout_ms),
      env: Keyword.get(opts, :env, %{})
    }

    with {:ok, profile} <- profile(Keyword.get(opts, :profile)),
         {:ok, cwd} <- cwd(Keyword.get(opts, :cwd)),
         :ok <- options(config) do
      {:ok, Map.merge(config, %{profile: profile, cwd: cwd})}
    end
  end

  defp options(config) do
    checks = [
      subscriber: is_pid(config.subscriber),
      principal: is_nil(config.principal) or is_pid(config.principal),
      path: is_nil(config.path) or is_binary(config.path),
      ready_timeout_ms:
        is_integer(config.ready_timeout_ms) and config.ready_timeout_ms in 0..@max_timeout_ms,
      approval_timeout_ms:
        is_integer(config.approval_timeout_ms) and
          config.approval_timeout_ms in 0..@max_timeout_ms,
      env: env?(config.env)
    ]

    case Enum.find(checks, fn {_option, valid?} -> not valid? end) do
      nil -> :ok
      {option, false} -> {:error, {:invalid_option, option}}
    end
  end

  defp env?(env) when is_map(env) do
    Enum.all?(env, fn {name, value} ->
      is_binary(name) and Regex.match?(@env_name, name) and is_binary(value) and
        not String.contains?(value, <<0>>)
    end)
  end

  defp env?(_env), do: false

  # A port's `:env` only overlays the BEAM's environment, so every variable
  # outside the allowlist is unset explicitly.
  defp port_env(extra) do
    unset =
      for {name, _value} <- System.get_env(),
          name not in @env_allowlist and not is_map_key(extra, name),
          do: {String.to_charlist(name), false}

    unset ++
      Enum.map(extra, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)
  end

  # A name that cannot be read as a flag or a path.
  defp profile(profile) when is_binary(profile) do
    if Regex.match?(@profile, profile), do: {:ok, profile}, else: {:error, :invalid_profile}
  end

  defp profile(_profile), do: {:error, :invalid_profile}

  defp cwd(cwd) when is_binary(cwd) do
    if Path.type(cwd) == :absolute,
      do: vet_cwd(Path.expand(cwd)),
      else: {:error, {:invalid_cwd, :not_absolute}}
  end

  defp cwd(_cwd), do: {:error, {:invalid_cwd, :not_absolute}}

  defp vet_cwd(cwd) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.stat(cwd),
         {:ok, beam} <- File.stat("."),
         :ok <- outside(cwd, identity(stat), identity(beam)),
         :ok <- OperatorFile.owned_unshared(stat) do
      {:ok, cwd}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_cwd, {:not_a_directory, type}}}
      {:error, reason} -> {:error, {:invalid_cwd, reason}}
    end
  end

  # By file identity, never by path: a symlink, or `/tmp` and `/private/tmp`,
  # name the same directory. The OS resolves `dir/..` from the directory
  # `dir` really is, so the walk visits its real ancestors, up to the root
  # (its own parent).
  defp outside(_dir, beam, beam), do: {:error, :beam_cwd}

  defp outside(dir, id, beam) do
    parent = Path.join(dir, "..")

    with {:ok, stat} <- File.stat(parent) do
      case identity(stat) do
        ^beam -> {:error, :inside_beam_cwd}
        ^id -> :ok
        parent_id -> outside(parent, parent_id, beam)
      end
    end
  end

  defp identity(%File.Stat{major_device: device, inode: inode}), do: {device, inode}

  # `omp --version` in the session's cwd and environment, stdin on
  # /dev/null, bounded. `env` also unsets the shell variables the spec's
  # own `:env` would.
  defp check_version(path, cwd, env) do
    spec = SpawnedPort.spawn_spec(path, ["--version"])

    opts =
      [:binary, :exit_status, :hide, {:args, spec.args}, {:cd, cwd}, {:env, env}] ++
        List.keydelete(spec.opts, :env, 0)

    with {:ok, port} <- spawn(spec.path, opts),
         {:ok, output} <- collect_version(port, [], deadline(@version_timeout_ms)),
         {:ok, version} <- target_output(output, spec) do
      case Version.check(version) do
        {:ok, _version, warnings} -> Enum.each(warnings, &warn/1)
        {:error, reason} -> {:error, {:omp_refused, reason}}
      end
    end
  end

  defp collect_version(port, acc, deadline) do
    receive do
      {^port, {:data, chunk}} -> collect_version(port, [acc | chunk], deadline)
      {^port, {:exit_status, 0}} -> {:ok, IO.iodata_to_binary(acc)}
      {^port, {:exit_status, status}} -> {:error, {:omp_version_failed, status}}
    after
      remaining(deadline) ->
        SpawnedPort.close(port)
        {:error, :omp_version_timeout}
    end
  end

  defp target_output(output, spec) do
    case SpawnedPort.target_output(output, spec) do
      {:ok, version} -> {:ok, version}
      :error -> {:error, {:omp_version_failed, :no_output}}
    end
  end

  # stdin stays a pipe: commands are written to it. stderr is inherited.
  # The working directory is the session's, never the BEAM's.
  defp open_port(path, config, env) do
    args = ["--mode", "rpc", "--approval-mode", "write", "--profile", config.profile]

    spawn(path, [
      :binary,
      :exit_status,
      :hide,
      {:line, @line_bytes},
      {:args, args},
      {:cd, config.cwd},
      {:env, env}
    ])
  end

  defp spawn(path, opts) do
    {:ok, Port.open({:spawn_executable, path}, opts)}
  rescue
    error in ErlangError -> {:error, {:omp_spawn_failed, error.original}}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  defp initial_state(config) do
    principal_ref = if config.principal, do: Process.monitor(config.principal)

    %{
      port: nil,
      os_pid: nil,
      subscriber: config.subscriber,
      principal: config.principal,
      approval_timeout_ms: config.approval_timeout_ms,
      principal_ref: principal_ref,
      phase: :starting,
      handshake_error: nil,
      ready_timer: nil,
      waiters: [],
      max_frame_bytes: @default_frame_bytes,
      decoder: Codec.decoder(@default_frame_bytes),
      buffer: [],
      buffer_bytes: 0,
      discarding: false,
      next_id: 1,
      pending: %{},
      approvals: %{},
      open_prompts: MapSet.new(),
      settled: true,
      closing: nil
    }
  end

  # Every caller waiting in `await_ready/2` learns why, and an OMP that may
  # not be reading its stdin yet is killed.
  defp handshake_failed(state, reason) do
    Enum.each(state.waiters, &GenServer.reply(&1, {:error, reason}))
    cancel(state.ready_timer)
    if state.port, do: kill(state)
    {:stop, reason, %{state | port: nil, waiters: [], ready_timer: nil}}
  end

  defp ready(state) do
    cancel(state.ready_timer)
    Enum.each(state.waiters, &GenServer.reply(&1, :ok))
    %{state | phase: :ready, ready_timer: nil, waiters: []}
  end

  # -- calls --------------------------------------------------------------------

  @impl true
  def handle_call(:await_ready, _from, %{phase: :ready} = state), do: {:reply, :ok, state}

  def handle_call(:await_ready, from, state),
    do: {:noreply, %{state | waiters: [from | state.waiters]}}

  def handle_call({:request, _type, _encoded, _timeout_ms}, _from, %{phase: phase} = state)
      when phase != :ready,
      do: {:reply, {:error, :not_ready}, state}

  def handle_call({:request, type, encoded, timeout_ms}, from, state) do
    id = Integer.to_string(state.next_id)
    line = Codec.frame(id, encoded)

    if IO.iodata_length(line) > state.max_frame_bytes do
      {:reply, {:error, {:invalid_request, :too_large}}, state}
    else
      write(state.port, line)
      timer = Process.send_after(self(), {:deadline, id}, timeout_ms)
      pending = Map.put(state.pending, id, {from, timer, timeout_ms, type})
      {:noreply, %{state | next_id: state.next_id + 1, pending: pending}}
    end
  end

  def handle_call({:answer, _ui_id, _value}, {pid, _tag}, %{principal: principal} = state)
      when pid != principal,
      do: {:reply, {:error, :not_principal}, state}

  def handle_call({:answer, ui_id, value}, _from, state) do
    case Map.fetch(state.approvals, ui_id) do
      {:ok, {options, timer}} ->
        if value in options do
          cancel(timer)
          write(state.port, Codec.ui_answer(ui_id, value))
          {:reply, :ok, %{state | approvals: Map.delete(state.approvals, ui_id)}}
        else
          {:reply, {:error, :invalid_choice}, state}
        end

      :error ->
        {:reply, {:error, :unknown_request}, state}
    end
  end

  def handle_call({:close, _timeout_ms}, _from, %{closing: {_, _, _}} = state),
    do: {:reply, {:error, :already_closing}, state}

  def handle_call({:close, timeout_ms}, from, state) do
    state = deny_all(state, :closing)

    if state.phase != :ready or settled?(state) do
      {:stop, :normal, :ok, state}
    else
      timer = Process.send_after(self(), :close_deadline, timeout_ms)
      {:noreply, %{state | closing: {from, timer, timeout_ms}}}
    end
  end

  # -- port and timers ----------------------------------------------------------

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = data(state, data)

    if state.handshake_error,
      do: handshake_failed(state, state.handshake_error),
      else: maybe_close(state)
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: omp_down(state, status)

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: omp_down(state, reason)

  def handle_info(:ready_deadline, %{phase: phase} = state) when phase != :ready,
    do: handshake_failed(state, :rpc_ready_timeout)

  def handle_info({:deadline, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer, timeout_ms, _type}, pending} ->
        GenServer.reply(from, {:error, {:rpc_timeout, timeout_ms}})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info(:close_deadline, %{closing: {from, _timer, timeout_ms}} = state) do
    GenServer.reply(from, {:error, {:settle_timeout, timeout_ms}})
    {:noreply, %{state | closing: nil}}
  end

  def handle_info({:approval_deadline, ui_id}, state) do
    case Map.pop(state.approvals, ui_id) do
      {{_options, _timer}, approvals} ->
        deny(state, ui_id, :timeout)
        {:noreply, %{state | approvals: approvals}}

      {nil, _approvals} ->
        {:noreply, state}
    end
  end

  # The principal is gone: nobody can answer its open approvals.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{principal_ref: ref} = state) do
    state = deny_all(%{state | principal: nil, principal_ref: nil}, :principal_down)
    {:noreply, state}
  end

  # A closed port's late messages and a stale timer land here.
  def handle_info(_message, state), do: {:noreply, state}

  # OMP drains the commands it accepted once its stdin closes, so an RPC
  # `bash` in flight is aborted first rather than left to finish after its
  # caller was told `:rpc_down`.
  @impl true
  def terminate(_reason, %{port: port, phase: :ready}) when is_port(port) do
    for type <- @aborts do
      {:ok, ^type, encoded} = Codec.encode_command(%{"type" => type})
      write(port, Codec.frame(type, encoded))
    end

    SpawnedPort.close(port)
  end

  def terminate(_reason, %{port: port} = state) when is_port(port), do: kill(state)
  def terminate(_reason, _state), do: :ok

  # Crash reports and `:sys.get_status/1` show counts, never content: pending
  # requests, open approvals (their titles name the tool call), the partial
  # line, a partial chunk run and the last message all carry it.
  @impl true
  def format_status(status) do
    status
    |> Map.replace_lazy(:state, &redact_state/1)
    |> Map.replace_lazy(:message, &redact_message/1)
    |> Map.replace(:log, [])
  end

  defp redact_state(%{pending: pending, approvals: approvals, waiters: waiters} = state) do
    %{
      state
      | pending: map_size(pending),
        approvals: map_size(approvals),
        waiters: length(waiters),
        buffer: :redacted,
        decoder: :redacted
    }
  end

  defp redact_state(state), do: state

  defp redact_message({:request, type, _encoded, timeout_ms}),
    do: {:request, type, :redacted, timeout_ms}

  defp redact_message({:answer, ui_id, _value}), do: {:answer, ui_id, :redacted}
  defp redact_message({port, {:data, _data}}) when is_port(port), do: {port, {:data, :redacted}}
  defp redact_message(message), do: message

  # -- lines and frames ---------------------------------------------------------

  # A physical frame is at most `maxFrameBytes`; a longer line is dropped
  # whole instead of buffered.
  defp data(state, {:noeol, chunk}) do
    bytes = state.buffer_bytes + byte_size(chunk)

    cond do
      state.discarding ->
        state

      bytes > state.max_frame_bytes ->
        Logger.warning("omp rpc: dropped a line over maxFrameBytes")
        %{state | buffer: [], buffer_bytes: 0, discarding: true}

      true ->
        %{state | buffer: [state.buffer | chunk], buffer_bytes: bytes}
    end
  end

  defp data(%{discarding: true} = state, {:eol, _chunk}),
    do: %{state | buffer: [], buffer_bytes: 0, discarding: false}

  defp data(state, {:eol, chunk}) do
    line = IO.iodata_to_binary([state.buffer | chunk])
    state = %{state | buffer: [], buffer_bytes: 0}

    if byte_size(line) > state.max_frame_bytes do
      Logger.warning("omp rpc: dropped a line over maxFrameBytes")
      state
    else
      line(state, line)
    end
  end

  defp line(state, line) do
    case Codec.decode_line(state.decoder, line) do
      {:ok, frame, decoder} ->
        frame(%{state | decoder: decoder}, frame)

      {:more, decoder} ->
        %{state | decoder: decoder}

      {:error, reason, decoder} ->
        Logger.warning("omp rpc: dropped a frame (#{reason})")
        %{state | decoder: decoder}
    end
  end

  defp frame(%{phase: :starting} = state, frame) do
    case Codec.ready(frame) do
      {:ok, limits} ->
        write(state.port, Codec.frame("negotiate", Codec.negotiate()))

        %{
          state
          | phase: :negotiating,
            max_frame_bytes: limits.max_frame_bytes,
            decoder: Codec.decoder(limits.max_reassembled_bytes)
        }

      {:error, reason} ->
        %{state | handshake_error: reason}
    end
  end

  defp frame(%{phase: :negotiating} = state, %{"type" => "response", "id" => "negotiate"} = frame) do
    case Codec.result(frame) do
      {:ok, %{"protocolVersion" => 2}} ->
        ready(state)

      {:ok, _data} ->
        %{state | handshake_error: {:negotiate_failed, nil}}

      {:error, {:rpc_error, code}} ->
        %{state | handshake_error: {:negotiate_failed, code}}
    end
  end

  defp frame(state, %{"type" => "response", "id" => id} = frame)
       when is_map_key(state.pending, id) do
    {{from, timer, _timeout_ms, type}, pending} = Map.pop(state.pending, id)
    cancel(timer)
    result = Codec.result(frame)
    GenServer.reply(from, result)
    admit(%{state | pending: pending}, type, id, result)
  end

  defp frame(state, %{"type" => "extension_ui_request"} = frame) do
    forward(state, frame)
    ui_request(state, frame, Codec.ui_request(frame))
  end

  defp frame(state, %{"type" => "prompt_result"} = frame) do
    forward(state, frame)
    open_prompts = MapSet.delete(state.open_prompts, frame["id"])
    state = %{state | open_prompts: open_prompts}

    # A prompt that never reached the agent gets no `session_settled`.
    if frame["agentInvoked"] == false and frame["sessionSettled"] == true and
         MapSet.size(open_prompts) == 0,
       do: %{state | settled: true},
       else: state
  end

  defp frame(state, %{"type" => "session_settled"} = frame) do
    forward(state, frame)
    %{state | settled: MapSet.size(state.open_prompts) == 0}
  end

  defp frame(state, %{"type" => "agent_start"} = frame) do
    forward(state, frame)
    %{state | settled: false}
  end

  defp frame(state, frame) do
    forward(state, frame)
    state
  end

  # An admitted prompt is open until its `prompt_result`, unless its
  # response says it already finished locally.
  defp admit(state, type, id, {:ok, data}) when type in @prompts do
    if is_map(data) and data["agentInvoked"] == false,
      do: state,
      else: %{state | open_prompts: MapSet.put(state.open_prompts, id), settled: false}
  end

  defp admit(state, _type, _id, _result), do: state

  # Nobody can answer: no principal, or the session is closing.
  defp ui_request(
         %{principal: principal, closing: closing} = state,
         _frame,
         {:approval, ui_id, _}
       )
       when is_nil(principal) or not is_nil(closing) do
    write(state.port, Codec.ui_answer(ui_id, Codec.deny()))
    state
  end

  defp ui_request(state, frame, {:approval, ui_id, options}) do
    send(state.principal, {:omp_rpc_approval, self(), ui_id, Map.put(frame, "options", options)})
    timer = Process.send_after(self(), {:approval_deadline, ui_id}, state.approval_timeout_ms)
    %{state | approvals: Map.put(state.approvals, ui_id, {options, timer})}
  end

  defp ui_request(state, _frame, {:dialog, ui_id}) do
    write(state.port, Codec.ui_cancel(ui_id))
    state
  end

  # OMP withdrew a dialog (its signal aborted): an answer is no longer due.
  defp ui_request(state, %{"method" => "cancel", "targetId" => target}, :none) do
    case Map.pop(state.approvals, target) do
      {{_options, timer}, approvals} ->
        cancel(timer)
        send(state.principal, {:omp_rpc_approval_closed, self(), target, :cancelled})
        %{state | approvals: approvals}

      {nil, _approvals} ->
        state
    end
  end

  defp ui_request(state, _frame, :none), do: state

  # Deny every open approval on the principal's behalf.
  defp deny_all(state, reason) do
    Enum.each(state.approvals, fn {ui_id, {_options, timer}} ->
      cancel(timer)
      deny(state, ui_id, reason)
    end)

    %{state | approvals: %{}}
  end

  defp deny(state, ui_id, reason) do
    write(state.port, Codec.ui_answer(ui_id, Codec.deny()))

    if state.principal,
      do: send(state.principal, {:omp_rpc_approval_closed, self(), ui_id, reason})
  end

  defp forward(state, frame), do: send(state.subscriber, {:omp_rpc, self(), frame})

  defp settled?(state), do: state.settled and MapSet.size(state.open_prompts) == 0

  defp maybe_close(%{closing: {from, timer, _timeout_ms}} = state) do
    if settled?(state) do
      cancel(timer)
      GenServer.reply(from, :ok)
      {:stop, :normal, %{state | closing: nil}}
    else
      {:noreply, state}
    end
  end

  defp maybe_close(state), do: {:noreply, state}

  defp omp_down(%{phase: phase} = state, status) when phase != :ready,
    do: handshake_failed(%{state | port: nil}, {:omp_exit, status})

  defp omp_down(state, status) do
    reason = {:omp_exit, status}

    Enum.each(state.pending, fn {_id, {from, timer, _timeout_ms, _type}} ->
      cancel(timer)
      GenServer.reply(from, {:error, reason})
    end)

    with {from, timer, _timeout_ms} <- state.closing do
      cancel(timer)
      GenServer.reply(from, {:error, reason})
    end

    {:stop, {:shutdown, reason}, %{state | port: nil, pending: %{}, closing: nil}}
  end

  # OMP that has just exited may have closed the port before its exit status
  # is handled; that status still arrives and fails the caller.
  defp write(port, line) do
    Port.command(port, line)
  rescue
    ArgumentError -> :ok
  end

  # An OMP that never finished its handshake may not be reading stdin, so
  # closing the port alone could leave it running.
  defp kill(%{port: port, os_pid: os_pid}) do
    with pid when is_integer(pid) <- os_pid,
         kill when is_binary(kill) <- System.find_executable("kill") do
      System.cmd(kill, ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    SpawnedPort.close(port)
  end

  defp warn({:newer_minor, found, tested}),
    do: Logger.warning("omp #{found} is newer than the tested #{tested}; continuing")

  defp warn({:older_minor, found, tested}),
    do: Logger.warning("omp #{found} is older than the tested #{tested}; continuing")

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
