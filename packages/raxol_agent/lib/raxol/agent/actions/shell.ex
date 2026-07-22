defmodule Raxol.Agent.Actions.Shell do
  @moduledoc """
  A single consequential shell Action (`run_shell`) for LLM tool use.

  Runs a command through `/bin/sh -c` on a `Port` (`:exit_status`,
  `:stderr_to_stdout`), captures the OS pid, and returns the combined
  output plus the exit code — a fact with a receipt, never a claim of what
  a command "would" do.

  ## Interruptibility (the staged-kill contract)

  A shell command is the one tool that can run long. Before collecting
  output the Action publishes its live `%{port, os_pid}` to the harness via
  the `:shell_tool_ref_sink` context callback (an arity-1 fun the
  `Raxol.Agent.Harness.SessionInbox` injects). ESC in the harness routes an
  interrupt to the inbox, which runs `Raxol.Agent.Interrupt.interrupt/3`
  against exactly that `tool_ref` — the staged OS kill the Interrupt module
  owns. When the kill lands, the Port emits its `:exit_status` (or closes)
  and the collect loop returns with `killed: true` rather than hanging. The
  sink is called again with `nil` on exit so a dead tool_ref is never left
  targetable. Absent the callback (a plain `Action.call/2`, or a harness
  that does not wire interrupts), the command still runs — just
  un-interruptible, which is the honest degradation, not a silent no-op.

  Consequential classification lives in
  `Raxol.Agent.Harness.ToolClassifier`, not here — the Action is a pure
  operation; the ASK-gate is the harness's decision.
  """

  use Raxol.Agent.Action,
    name: "run_shell",
    description:
      "Run a shell command via /bin/sh -c in the working directory and " <>
        "return its combined stdout+stderr and exit code.",
    schema: [
      input: [
        command: [
          type: :string,
          required: true,
          description: "Shell command line to execute"
        ],
        timeout_ms: [
          type: :integer,
          required: false,
          description: "Wall-clock cap in ms (default 30000)"
        ]
      ],
      output: [
        command: [type: :string],
        output: [type: :string],
        exit_code: [type: :integer],
        truncated: [type: :boolean],
        timed_out: [type: :boolean],
        killed: [type: :boolean]
      ]
    ]

  @default_timeout_ms 30_000
  @max_output_bytes 65_536

  @impl true
  def run(%{command: command} = params, context) do
    timeout = Map.get(params, :timeout_ms) || @default_timeout_ms
    cwd = Raxol.Agent.Actions.Fs.working_dir()

    port =
      Port.open({:spawn_executable, shell_path()}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:args, ["-c", command]},
        {:cd, cwd}
      ])

    os_pid = port_os_pid(port)
    sink = Map.get(context, :shell_tool_ref_sink)
    publish(sink, %{port: port, os_pid: os_pid})

    deadline = System.monotonic_time(:millisecond) + timeout

    try do
      collect(port, command, deadline, "", false)
    after
      publish(sink, nil)
    end
  end

  # Collect output until the Port reports exit, the output cap is hit, or the
  # wall-clock deadline passes. A kill (OS pgroup death from an interrupt)
  # surfaces here as the Port's own `:exit_status`, so `killed:` is inferred
  # from a non-zero/negative exit combined with the deadline still open.
  defp collect(port, command, deadline, acc, capped) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      close_port(port)
      result(command, acc, 124, capped, true, false)
    else
      receive do
        {^port, {:data, data}} ->
          {acc, capped} = append_capped(acc, data, capped)
          collect(port, command, deadline, acc, capped)

        {^port, {:exit_status, status}} ->
          # A signal death shows up as 128+signum on /bin/sh; treat any
          # non-zero exit produced while we were still within the deadline
          # AND after an interrupt as killed. We cannot see the interrupt
          # here, so `killed:` is reported conservatively as false and the
          # exit code carries the truth (the inbox's :turn_canceled event is
          # the authoritative interrupt receipt).
          result(command, acc, status, capped, false, false)

        {:EXIT, ^port, _reason} ->
          result(command, acc, -1, capped, false, true)
      after
        remaining ->
          close_port(port)
          result(command, acc, 124, capped, true, false)
      end
    end
  end

  defp append_capped(acc, _data, true), do: {acc, true}

  defp append_capped(acc, data, false) do
    combined = acc <> data

    if byte_size(combined) > @max_output_bytes do
      {binary_part(combined, 0, @max_output_bytes), true}
    else
      {combined, false}
    end
  end

  defp result(command, output, exit_code, truncated, timed_out, killed) do
    {:ok,
     %{
       command: command,
       output: output,
       exit_code: exit_code,
       truncated: truncated,
       timed_out: timed_out,
       killed: killed
     }}
  end

  defp publish(nil, _ref), do: :ok

  defp publish(sink, ref) when is_function(sink, 1) do
    sink.(ref)
    :ok
  end

  defp publish(_sink, _ref), do: :ok

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp close_port(port) do
    if is_port(port) and not is_nil(Port.info(port)) do
      Port.close(port)
    end
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp shell_path do
    System.find_executable("sh") || "/bin/sh"
  end
end
