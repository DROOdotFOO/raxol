defprotocol Raxol.Agent.Directive.Executor do
  @moduledoc """
  Protocol for executing `Raxol.Agent.Directive` structs.

  External packages register their own directive types by defining a struct
  and implementing this protocol for it.

  ## Context

  The `context` map carries at minimum:

    * `:pid` - process to receive `{:command_result, payload}` messages
    * `:runtime_pid` - process to receive runtime-level signals (e.g. quit)

  Effect messages land at `context.pid` as `{:command_result, payload}`.
  Consumers rely on the asynchronous result message rather than the return
  value of `execute/2`.
  """

  @spec execute(t(), context :: map()) :: any()
  def execute(directive, context)
end

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.Async do
  alias Raxol.Agent.Directive.Async

  def execute(%Async{fun: fun}, context) do
    pid = context.pid
    sender = fn msg -> send(pid, {:command_result, msg}) end

    Task.start(fn ->
      try do
        fun.(sender)
      rescue
        e -> send(pid, {:command_result, {:async_error, Exception.message(e)}})
      end
    end)
  end
end

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.Shell do
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

    Task.start(fn ->
      charlist_env =
        Enum.map(env, fn {k, v} ->
          {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
        end)

      port_opts =
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          args: ["-c", command]
        ]
        |> maybe_add_port_opt(:cd, cd)
        |> maybe_add_port_opt(:env, if(charlist_env != [], do: charlist_env))

      port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
      result = collect_port_output(port, [], timeout)
      send(context.pid, {:command_result, {:shell_result, result}})
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

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.SendAgent do
  alias Raxol.Agent.Directive.SendAgent

  def execute(%SendAgent{target_id: target_id, message: message}, context) do
    with pid when is_pid(pid) <- Process.whereis(Raxol.Agent.Registry),
         [{agent_pid, _}] <- Registry.lookup(Raxol.Agent.Registry, target_id) do
      GenServer.cast(agent_pid, {:send_message, message, causation_metadata()})
    else
      _ ->
        send(
          context.pid,
          {:command_result, {:send_agent_error, :not_found, target_id}}
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

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.Schedule do
  alias Raxol.Agent.Directive.Schedule

  def execute(%Schedule{interval_ms: interval_ms, payload: payload}, context) do
    Process.send_after(context.pid, {:command_result, payload}, interval_ms)
  end
end

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.Spawn do
  alias Raxol.Agent.Directive.Spawn

  def execute(%Spawn{fun: fun}, context) do
    Task.start(fn ->
      result = fun.()
      send(context.pid, {:command_result, result})
    end)
  end
end

defimpl Raxol.Agent.Directive.Executor, for: Raxol.Agent.Directive.Stop do
  alias Raxol.Agent.Directive.Stop

  def execute(%Stop{}, context) do
    send(context.runtime_pid, :quit_runtime)
  end
end
