defmodule Raxol.Agent.OMP.RPC do
  @moduledoc """
  A client for one `omp --mode rpc` session (ADR-0042, decision 7).

  `start_link/1` spawns `omp --mode rpc --approval-mode write --profile
  <profile>` in a dedicated working directory and returns once the session
  is ready: the binary is resolved and vetted
  (`Raxol.Agent.Backend.OmpGateway.resolve_binary/1`), `omp --version` is
  checked against the tested pin (`Raxol.Agent.OMP.Version`; a different
  major is refused, a newer minor logged), the ready frame must offer
  protocol v2, and `negotiate_protocol` v2 must succeed. From then on a
  frame over OMP's `maxFrameBytes` arrives as `rpc_chunk` lines, which are
  reassembled (`Raxol.Agent.OMP.RPC.Codec`).

  `--no-ui` is never passed: with it, a tool that needs approval fails
  closed with no frame at all. Without it, OMP asks over the wire.

  ## The profile and the working directory

  The profile must already be provisioned: OMP exits 1 before its ready
  frame on a profile with no usable model, and `start_link/1` returns
  `{:error, {:omp_exit, 1}}`.

  `:cwd` is the session's own directory. OMP loads and runs a working
  directory's `.omp/extensions`, rules and context files inside the process
  that holds every credential OMP has, so the BEAM's cwd (possibly a cloned,
  untrusted workspace) is refused, and so is a directory not owned by this
  account or writable by its group or others
  (`Raxol.Agent.OperatorFile.owned_unshared/2`).

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
  of the frame's `options` through `answer/3`. With no principal, or once
  the principal exits, approvals are denied. Every other dialog is
  cancelled. Presentation frames (`setWidget`, `notify`, ...) need no
  answer and are only forwarded.

  ## Teardown

  `close/2` tears the session down once it is settled: after OMP's
  `session_settled` frame, or, for a prompt that never reached the agent,
  its `prompt_result` with `sessionSettled: true` (OMP sends no
  `session_settled` then). A session with no agent activity is settled. If
  the session does not settle in time, `close/2` returns
  `{:error, {:settle_timeout, ms}}` and the session keeps running.

  ## Errors

  None carries a frame's text or a request's content.

  From `start_link/1` (the process stops with the same reason):
  `{:invalid_option, name}` (`:subscriber`, `:principal`, `:path`,
  `:ready_timeout_ms`), `:invalid_profile`, `{:invalid_cwd, reason}` (`:not_absolute`,
  `:beam_cwd`, `{:not_a_directory, type}`, `{:not_owned, uid}`,
  `{:group_or_other_writable, mode}` or a posix error), every
  `OmpGateway.resolve_binary/1` error, `{:omp_version_failed, status}`,
  `:omp_version_timeout`, `{:omp_refused, reason}` (a `Version.check/1`
  error), `{:omp_spawn_failed, reason}`, `{:omp_exit, status}` (exited
  before the handshake finished), `:rpc_ready_timeout` (no ready frame and
  negotiation in time; the process is killed), `:invalid_ready_frame`,
  `{:unsupported_protocol, versions}` and `{:negotiate_failed, code}`.

  From `request/3`: `{:invalid_request, reason}` (see
  `Codec.encode_command/1`; `:timeout` for a timeout that is not an integer
  from 0 to 2^32 - 1, `:too_large` for a line over OMP's `maxFrameBytes`),
  `{:rpc_error, command, code}` (OMP refused the command),
  `{:rpc_timeout, ms}`, `{:omp_exit, status}` (OMP exited with the request
  pending; the process stops with `{:shutdown, {:omp_exit, status}}`),
  `:rpc_not_started` and `:rpc_down`.

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
  @default_request_timeout_ms 30_000
  @default_close_timeout_ms 60_000
  @version_timeout_ms 10_000
  @line_bytes 65_536
  # Until the ready frame says otherwise: OMP's documented physical limit.
  @default_frame_bytes 1_048_576
  # The largest delay `Process.send_after/3` accepts.
  @max_timeout_ms 4_294_967_295
  @profile ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
  @prompts ["prompt", "abort_and_prompt"]

  @doc """
  Start a session and return once it is ready (see the moduledoc).

  Options: `:profile` (required; the OMP profile name), `:cwd` (required;
  the session's absolute working directory), `:subscriber` (required; the
  pid that receives frames), `:path` (the `omp` binary; as for
  `OmpGateway.resolve_binary/1`), `:principal` (pid answering approvals;
  default none, so every approval is denied), `:ready_timeout_ms` (default
  #{@default_ready_timeout_ms}), `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    ready_ms = Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)
    start_ms = if is_integer(ready_ms), do: ready_ms + @version_timeout_ms + 5_000, else: 5_000
    gen_opts = if name, do: [name: name, timeout: start_ms], else: [timeout: start_ms]
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

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
  `{:error, :invalid_choice}` (the approval stays open) or
  `{:error, :unknown_request}` (already answered, cancelled by OMP, or never
  asked).
  """
  @spec answer(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def answer(server, ui_id, value) when is_binary(ui_id) and is_binary(value),
    do: call(server, {:answer, ui_id, value})

  @doc """
  Tear the session down once it is settled (see the moduledoc): `:ok`, or
  `{:error, {:settle_timeout, ms}}`, `{:error, {:omp_exit, status}}`,
  `{:error, :already_closing}`.
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
         {:ok, path} <- OmpGateway.resolve_binary(config.path),
         :ok <- check_version(path, config.cwd),
         {:ok, port} <- open_port(path, config) do
      deadline = System.monotonic_time(:millisecond) + config.ready_timeout_ms
      handshake(initial_state(port, config), deadline)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp config(opts) do
    config = %{
      path: Keyword.get(opts, :path),
      subscriber: Keyword.get(opts, :subscriber),
      principal: Keyword.get(opts, :principal),
      ready_timeout_ms: Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)
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
        is_integer(config.ready_timeout_ms) and config.ready_timeout_ms in 0..@max_timeout_ms
    ]

    case Enum.find(checks, fn {_option, valid?} -> not valid? end) do
      nil -> :ok
      {option, false} -> {:error, {:invalid_option, option}}
    end
  end

  # A name that cannot be read as a flag or a path.
  defp profile(profile) when is_binary(profile) do
    if Regex.match?(@profile, profile), do: {:ok, profile}, else: {:error, :invalid_profile}
  end

  defp profile(_profile), do: {:error, :invalid_profile}

  defp cwd(cwd) when is_binary(cwd) do
    cond do
      Path.type(cwd) != :absolute -> {:error, {:invalid_cwd, :not_absolute}}
      Path.expand(cwd) == File.cwd!() -> {:error, {:invalid_cwd, :beam_cwd}}
      true -> vet_cwd(Path.expand(cwd))
    end
  end

  defp cwd(_cwd), do: {:error, {:invalid_cwd, :not_absolute}}

  defp vet_cwd(cwd) do
    with {:ok, %File.Stat{type: :directory} = stat} <- File.stat(cwd),
         :ok <- OperatorFile.owned_unshared(stat) do
      {:ok, cwd}
    else
      {:ok, %File.Stat{type: type}} -> {:error, {:invalid_cwd, {:not_a_directory, type}}}
      {:error, reason} -> {:error, {:invalid_cwd, reason}}
    end
  end

  # `omp --version` in the session's cwd, stdin on /dev/null, bounded.
  defp check_version(path, cwd) do
    spec = SpawnedPort.spawn_spec(path, ["--version"])
    opts = [:binary, :exit_status, :hide, {:args, spec.args}, {:cd, cwd}] ++ spec.opts

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
  defp open_port(path, config) do
    args = ["--mode", "rpc", "--approval-mode", "write", "--profile", config.profile]

    spawn(path, [
      :binary,
      :exit_status,
      :hide,
      {:line, @line_bytes},
      {:args, args},
      {:cd, config.cwd}
    ])
  end

  defp spawn(path, opts) do
    {:ok, Port.open({:spawn_executable, path}, opts)}
  rescue
    error in ErlangError -> {:error, {:omp_spawn_failed, error.original}}
  end

  defp initial_state(port, config) do
    principal_ref = if config.principal, do: Process.monitor(config.principal)

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        nil -> nil
      end

    %{
      port: port,
      os_pid: os_pid,
      subscriber: config.subscriber,
      principal: config.principal,
      principal_ref: principal_ref,
      phase: :starting,
      handshake_error: nil,
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

  # Port messages are handled here, inside `init/1`, until the ready frame
  # and the negotiation response have arrived.
  defp handshake(%{port: port} = state, deadline) do
    receive do
      {^port, {:data, data}} ->
        state = data(state, data)

        cond do
          state.handshake_error -> stop_handshake(state, state.handshake_error)
          state.phase == :ready -> {:ok, state}
          true -> handshake(state, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:stop, {:omp_exit, status}}

      {:EXIT, ^port, reason} ->
        {:stop, {:omp_exit, reason}}
    after
      remaining(deadline) ->
        kill(state)
        {:stop, :rpc_ready_timeout}
    end
  end

  defp stop_handshake(state, reason) do
    SpawnedPort.close(state.port)
    {:stop, reason}
  end

  # -- calls --------------------------------------------------------------------

  @impl true
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

  def handle_call({:answer, ui_id, value}, _from, state) do
    case Map.fetch(state.approvals, ui_id) do
      {:ok, options} ->
        if value in options do
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
    if settled?(state) do
      {:stop, :normal, :ok, state}
    else
      timer = Process.send_after(self(), :close_deadline, timeout_ms)
      {:noreply, %{state | closing: {from, timer, timeout_ms}}}
    end
  end

  # -- port and timers ----------------------------------------------------------

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state),
    do: state |> data(data) |> maybe_close()

  def handle_info({port, {:exit_status, status}}, %{port: port} = state),
    do: omp_down(state, status)

  def handle_info({:EXIT, port, reason}, %{port: port} = state),
    do: omp_down(state, reason)

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

  # The principal is gone: nobody can answer its open approvals.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{principal_ref: ref} = state) do
    Enum.each(state.approvals, fn {ui_id, _options} ->
      write(state.port, Codec.ui_answer(ui_id, Codec.deny()))
    end)

    {:noreply, %{state | principal: nil, principal_ref: nil, approvals: %{}}}
  end

  # A closed port's late messages and a stale timer land here.
  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port), do: SpawnedPort.close(port)
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

  defp redact_state(%{pending: pending, approvals: approvals} = state) do
    %{
      state
      | pending: map_size(pending),
        approvals: map_size(approvals),
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
        %{state | phase: :ready}

      {:ok, _data} ->
        %{state | handshake_error: {:negotiate_failed, nil}}

      {:error, {:rpc_error, _command, code}} ->
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

  defp ui_request(%{principal: nil} = state, _frame, {:approval, ui_id, _options}) do
    write(state.port, Codec.ui_answer(ui_id, Codec.deny()))
    state
  end

  defp ui_request(state, frame, {:approval, ui_id, options}) do
    send(state.principal, {:omp_rpc_approval, self(), ui_id, frame})
    %{state | approvals: Map.put(state.approvals, ui_id, options)}
  end

  defp ui_request(state, _frame, {:dialog, ui_id}) do
    write(state.port, Codec.ui_cancel(ui_id))
    state
  end

  # OMP withdrew a dialog (its signal aborted): an answer is no longer due.
  defp ui_request(state, %{"method" => "cancel", "targetId" => target}, :none),
    do: %{state | approvals: Map.delete(state.approvals, target)}

  defp ui_request(state, _frame, :none), do: state

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

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp cancel(nil), do: :ok
  defp cancel(timer), do: Process.cancel_timer(timer)
end
