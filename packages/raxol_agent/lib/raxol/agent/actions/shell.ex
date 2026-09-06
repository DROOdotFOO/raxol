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

  ## Wall-clock timeout is also a kill, not just a hangup

  `Port.close/1` alone only tears down the BEAM's side of the pipe — the OS
  process on the other end (and anything it forked) survives, detached, the
  exact failure mode `Raxol.Agent.Interrupt`'s moduledoc documents as the
  reason a plain port close is insufficient. So a wall-clock timeout runs
  the SAME OS process-group kill the interrupt path uses
  (`Raxol.Agent.Interrupt.kill_os_pid/1`) before closing the port — a timed-
  out `run_shell "sleep 600"` does not leave `sh` (or anything it spawned)
  running after the Action returns.

  ## A pty is available; a job that outlives the turn is a different action

  `pty: true` runs the command under a controlling terminal, so a tool that
  checks `isatty` takes its interactive path — progress output, colour,
  prompts. It is not a privilege escalation: the privilege here is running
  arbitrary code, which this Action already has, and the identical
  `shell_allow/2` gate decides both. What it does change is the bytes.
  Output carries CR-LF and whatever escape sequences the command emits, and
  a terminal does not EOF, so a command that reads stdin blocks until the
  deadline rather than seeing an empty stdin. `Raxol.Agent.Shell.Pty` holds
  how the terminal is allocated and why killing one needs an extra step.

  This Action blocks for the whole command, so its cap is also a ceiling on
  what the agent can run. A command that may outlast a turn belongs in
  `Raxol.Agent.Shell.Jobs`, reachable through `background_actions/0`.

  Consequential classification lives in
  `Raxol.Agent.Harness.ToolClassifier`, not here — the Action is a pure
  operation; the ASK-gate is the harness's decision.
  """

  use Raxol.Agent.Action,
    name: "run_shell",
    description:
      "Run a shell command via /bin/sh -c in the working directory and " <>
        "return its combined stdout+stderr and exit code. Set `pty: true` " <>
        "for a command that only behaves correctly on a terminal.",
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
        ],
        pty: [
          type: :boolean,
          required: false,
          description: "Attach a pseudo-terminal (default false)"
        ]
      ],
      output: [
        command: [type: :string],
        output: [type: :string],
        exit_code: [type: :integer],
        truncated: [type: :boolean],
        timed_out: [type: :boolean],
        killed: [type: :boolean],
        pty: [type: :boolean]
      ]
    ]

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Shell.Pty

  @default_timeout_ms 30_000
  @max_output_bytes 65_536

  @doc """
  The background-job Actions: `shell_start`, `shell_poll`, `shell_wait`,
  `shell_kill`, `shell_jobs`.

  `run_shell` is deliberately absent. A toolset registering these already has
  a foreground shell (`Raxol.Agent.Actions.Code.Bash`), and two identical
  foreground shells only split the model's choice between them.
  """
  @spec background_actions() :: [module()]
  def background_actions,
    do: [
      Raxol.Agent.Actions.Shell.Start,
      Raxol.Agent.Actions.Shell.Poll,
      Raxol.Agent.Actions.Shell.Wait,
      Raxol.Agent.Actions.Shell.Kill,
      Raxol.Agent.Actions.Shell.JobList
    ]

  @doc """
  The job-ownership key for `context`, or the jail refusal.

  Reading and killing a background job pass the jail half of the shell gate
  but not the sandbox half: there is no command string left to match a policy
  against, and a jailed session has no shell surface at all — so it must not
  be able to read another tenant's build output through a guessed job id
  either. The key is the resolved working directory, this codebase's tenancy
  marker. Starting a job passes the whole gate, `shell_allow/2` included.
  """
  @spec job_owner(map()) :: {:ok, String.t()} | {:error, :shell_disabled_in_jail}
  def job_owner(context) do
    case Raxol.Agent.Actions.Code.shell_jail_allow(context) do
      :ok -> {:ok, Raxol.Agent.Actions.Fs.working_dir(context)}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def run(%{command: command} = params, context) do
    case Raxol.Agent.Actions.Code.shell_allow(context, command) do
      :ok -> run_allowed(params, context, command)
      {:error, _} = error -> error
    end
  end

  # This action had NO policy at all: no jail check, no sandbox check, while
  # the sibling `bash` tool had both. It is not in `Code.all()` and no shipped
  # toolset registers it, so it was a hazard for an embedder rather than a live
  # escape -- but "the gate depends on which of two shell tools you wired" is
  # not a property worth keeping.
  defp run_allowed(params, context, command) do
    timeout = Map.get(params, :timeout_ms) || @default_timeout_ms
    cwd = Raxol.Agent.Actions.Fs.working_dir(context)
    pty? = Map.get(params, :pty, false) == true

    case open_port(command, cwd, pty?) do
      {:error, _reason} = error ->
        error

      {:ok, port} ->
        os_pid = port_os_pid(port)
        sink = Map.get(context, :shell_tool_ref_sink)
        publish(sink, %{port: port, os_pid: os_pid})

        deadline = System.monotonic_time(:millisecond) + timeout

        try do
          collect(port, os_pid, command, pty?, deadline, "", false)
        after
          publish(sink, nil)
        end
    end
  end

  # `:in` closes the command's stdin; see `Raxol.Agent.SpawnedPort` for why.
  defp open_port(command, cwd, false) do
    {:ok, spawn_port(shell_path(), ["-c", command], cwd, [:in])}
  end

  # A pty leaves stdin open instead: the EOF would be echoed back through the
  # line discipline into the command's own output. Asking for a terminal on a
  # host that cannot provide one is refused rather than quietly downgraded --
  # a tool silently taking its non-interactive path is a wrong answer the
  # caller has no way to see.
  defp open_port(command, cwd, true) do
    case Pty.spawn_spec(shell_path(), command) do
      {:ok, {executable, args, env}} ->
        {:ok, spawn_port(executable, args, cwd, [{:env, env}])}

      :unavailable ->
        {:error, :pty_unavailable}
    end
  end

  defp spawn_port(executable, args, cwd, extra) do
    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, cwd}] ++ extra
    )
  end

  # Collect output until the Port reports exit, the output cap is hit, or the
  # wall-clock deadline passes.
  #
  # The loop process does NOT trap exits, so an abnormal port crash delivers
  # a real exit *signal* (killing this process), never an `{:EXIT, port,
  # reason}` *message* — there is deliberately no such receive clause here;
  # trying to catch it as a message would be dead code.
  defp collect(port, os_pid, command, pty?, deadline, acc, capped) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      timed_out(port, os_pid, command, pty?, acc, capped)
    else
      receive do
        {^port, {:data, data}} ->
          {acc, capped} = append_capped(acc, data, capped)
          collect(port, os_pid, command, pty?, deadline, acc, capped)

        {^port, {:exit_status, status}} ->
          # A signal death shows up as 128+signum on /bin/sh; treat any
          # non-zero exit produced while we were still within the deadline
          # AND after an interrupt as killed. We cannot see the interrupt
          # here, so `killed:` is reported conservatively as false and the
          # exit code carries the truth (the inbox's :turn_canceled event is
          # the authoritative interrupt receipt).
          result(command, acc, status, capped, false, false, pty?)
      after
        remaining ->
          timed_out(port, os_pid, command, pty?, acc, capped)
      end
    end
  end

  defp timed_out(port, os_pid, command, pty?, acc, capped) do
    killed? = kill_and_close(port, os_pid, pty?)
    result(command, acc, 124, capped, true, killed?, pty?)
  end

  # A wall-clock timeout means the caller is done waiting -- but "done
  # waiting" must not mean "the OS process keeps running unattended". Fire
  # the same OS process-group kill `Raxol.Agent.Interrupt` uses so a rogue
  # `sleep 600` (and every child it spawned) is actually dead, not orphaned,
  # THEN close the port. Reports `killed: true` only when the group kill was
  # confirmed to land -- never claiming a kill that wasn't established (same
  # honesty rule `Interrupt` follows).
  #
  # Under a pty the port program is `script`, which `setsid`s the command into
  # a session of its own, so a group kill of the port program reaches `script`
  # and nothing else. `Raxol.Agent.Shell.Pty.kill_tree/1` owns that case.
  defp kill_and_close(port, os_pid, pty?) do
    killed? = kill_process_tree(os_pid, pty?)
    close_port(port)
    killed?
  end

  defp kill_process_tree(os_pid, true) do
    {killed?, _confirmed?} = Pty.kill_tree(os_pid)
    killed?
  end

  defp kill_process_tree(os_pid, false) do
    {disposition, _confirmed?, _os_pid} = Interrupt.kill_os_pid(os_pid)
    disposition == :killed
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

  defp result(command, output, exit_code, truncated, timed_out, killed, pty?) do
    {:ok,
     %{
       command: command,
       output: output,
       exit_code: exit_code,
       truncated: truncated,
       timed_out: timed_out,
       killed: killed,
       pty: pty?
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
    Raxol.Agent.SpawnedPort.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp shell_path do
    System.find_executable("sh") || "/bin/sh"
  end
end
