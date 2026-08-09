defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.Agent.Directive.Async do
  alias Raxol.Agent.Directive.Async

  def execute(%Async{fun: fun}, context) do
    pid = context.pid
    # Snapshot the minting turn's id NOW (dispatch time). Results may land
    # turns later; the tag makes each delta carry its originating turn's id
    # instead of whatever the dispatcher's current turn happens to be.
    meta = %{turn_id: Map.get(context, :turn_id)}
    sender = fn msg -> send(pid, {:command_result, msg, meta}) end

    Task.start(fn ->
      try do
        fun.(sender)
      rescue
        e ->
          send(
            pid,
            {:command_result, {:async_error, Exception.message(e)}, meta}
          )
      end
    end)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.Agent.Directive.Shell do
  alias Raxol.Agent.Directive.Shell

  def execute(%Shell{command: command, opts: opts}, context) do
    timeout =
      Keyword.get(
        opts,
        :timeout,
        Raxol.Core.Defaults.health_check_interval_ms()
      )

    cd = Keyword.get(opts, :cd)
    env = Keyword.get(opts, :env, [])
    # Originating-turn snapshot; see the Async impl above.
    meta = %{turn_id: Map.get(context, :turn_id)}

    Task.start(fn ->
      charlist_env =
        Enum.map(env, fn {k, v} ->
          {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
        end)

      # `:in` closes the child's stdin. Without it an Erlang port hands the
      # command a pipe that never delivers and never closes, so anything that
      # READS stdin -- a bare `cat`, a tool that prompts, a `read` in a script
      # -- blocks until the timeout instead of seeing EOF. Nothing here ever
      # writes to the port, so there is no input to lose; this is what
      # `sh -c '...' < /dev/null` gives every other non-interactive runner.
      port_opts =
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          :in,
          args: ["-c", command]
        ]
        |> maybe_add_port_opt(:cd, cd)
        |> maybe_add_port_opt(:env, if(charlist_env != [], do: charlist_env))

      port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
      result = collect_port_output(port, [], timeout)
      send(context.pid, {:command_result, {:shell_result, result}, meta})
    end)
  end

  defp maybe_add_port_opt(opts, _key, nil), do: opts
  defp maybe_add_port_opt(opts, key, value), do: [{key, value} | opts]

  defp collect_port_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_port_output(port, [data | acc], timeout)

      {^port, {:exit_status, status}} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        %{exit_status: status, output: output}
    after
      timeout ->
        Port.close(port)
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        %{exit_status: :timeout, output: output}
    end
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.Agent.Directive.SendAgent do
  alias Raxol.Agent.Directive.SendAgent

  def execute(
        %SendAgent{target_id: target_id, message: message} = directive,
        context
      ) do
    with pid when is_pid(pid) <- Process.whereis(Raxol.Agent.Registry),
         [{agent_pid, _}] <- Registry.lookup(Raxol.Agent.Registry, target_id) do
      metadata =
        case directive.from do
          nil -> causation_metadata()
          from -> Map.put(causation_metadata(), :from, from)
        end

      GenServer.cast(agent_pid, {:send_message, message, metadata})
    else
      _ ->
        send(
          context.pid,
          {:command_result, {:send_agent_error, :not_found, target_id},
           %{turn_id: Map.get(context, :turn_id)}}
        )
    end
  end

  defp causation_metadata do
    case Raxol.Core.Telemetry.TraceContext.current() do
      %{span_id: span_id} when is_binary(span_id) -> %{causation_id: span_id}
      _ -> %{}
    end
  end
end
