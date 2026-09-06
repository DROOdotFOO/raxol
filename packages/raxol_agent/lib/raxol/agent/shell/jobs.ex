defmodule Raxol.Agent.Shell.Jobs do
  @moduledoc """
  Background shell jobs that outlive the turn that started them.

  `Raxol.Agent.Actions.Shell` blocks for its whole command, so its 30-second
  wall-clock cap is also the ceiling on what the agent can run at all: a build,
  a test suite, or a deploy is simply unavailable. This module makes a command
  startable in one turn and readable in a later one — start, poll by cursor,
  bounded wait, kill — which is the only shape the react loop can use. An
  action that blocked for ten minutes would be no more useful than the cap.

  ## Why one process owns every port

  A `Port`'s messages go to the process that opened it, and it dies with that
  process, so a job's port must be owned by something longer-lived than a turn.
  One GenServer multiplexing N ports is enough — the work per message is an
  append — and it avoids a per-job process needing a supervisor this library
  does not have (`raxol_agent`'s `:mod` is not even set under `:test`).

  It is started on demand and is safe to supervise: `start_link/1` is
  idempotent, so adding `Raxol.Agent.Shell.Jobs` to a supervision tree takes
  ownership of whatever is already running. Unsupervised, a crash loses the
  bookkeeping — the ports die with the process, and `terminate/2` reaps the OS
  side first.

  ## Why jobs are scoped to a working directory

  There is no session identity in the Action context; the tenancy marker this
  codebase already uses is `:cwd` (each connection's App carries its own, and
  `:jail` refuses the shell surface outright — see
  `Raxol.Agent.Actions.Code.shell_jail_allow/1`). So `:owner` is the resolved
  working directory, and every lookup takes it. Without that, one session could
  read another's command output, or kill its build, through a job id it
  guessed. It is also what makes the tests isolated: a temp dir per test means
  no test can observe another's jobs.

  ## Lifecycle safety

  Three independent bounds, because what they prevent is a leaked OS process or
  an OOM, not a wrong answer:

    * Every job carries a wall-clock deadline (10 minutes by default, one hour
      at most). It fires the same process-tree kill an explicit `kill/2` does,
      so a forgotten job cannot outlive it even with nothing reaping.
    * At most eight jobs run at once and at most sixteen entries are retained.
      Starting past the running cap is refused rather than queued, because a
      refusal the model can see beats an unbounded fan-out it cannot; finished
      entries are pruned oldest-first.
    * Retained output is capped at 128KB per job and the excess is DROPPED
      rather than rotated, which is what keeps a cursor a plain absolute offset
      so a poll is idempotent and replayable. `output_bytes` reports what the
      command actually wrote and `truncated` says bytes were lost, so the cap
      is never silent.

  A kill kills the whole tree. `Raxol.Agent.Interrupt.kill_os_pid/1` probes the
  process group before signalling it, so a pid we merely derived is never the
  target; for a pty job the sessions inside the pty are enumerated and killed
  first (`Raxol.Agent.Shell.Pty.inner_groups/1`), because `script` puts the
  command in a session of its own. `terminate/2` runs the same path for every
  live job, and the process traps exits so an abnormal shutdown reaches it too.
  """

  use GenServer

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Shell.Pty
  alias Raxol.Agent.SpawnedPort

  @max_running 8
  @max_retained 16
  @max_output_bytes 131_072
  @default_timeout_ms 600_000
  @max_timeout_ms 3_600_000
  @default_wait_ms 30_000
  @max_wait_ms 120_000
  @call_timeout_ms 15_000

  @typedoc "Terminal states are everything but `:running`."
  @type status :: :running | :exited | :killed | :timed_out

  @typedoc """
  What the actions report. `output` and `cursor` are added by `poll/3` only;
  `exit_code` is `nil` while running, and stays `nil` for a killed job because
  the port is closed as part of the kill and no status is ever observed.
  """
  @type view :: %{
          job_id: String.t(),
          command: String.t(),
          pty: boolean(),
          status: String.t(),
          running: boolean(),
          exit_code: integer() | nil,
          os_pid: non_neg_integer() | nil,
          runtime_ms: non_neg_integer(),
          output_bytes: non_neg_integer(),
          truncated: boolean()
        }

  @doc "Default wall-clock cap, in ms."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Hard ceiling on a job's wall-clock cap, in ms."
  @spec max_timeout_ms() :: pos_integer()
  def max_timeout_ms, do: @max_timeout_ms

  @doc "Default bounded wait, in ms."
  @spec default_wait_ms() :: pos_integer()
  def default_wait_ms, do: @default_wait_ms

  @doc "Hard ceiling on one `await/3`, in ms."
  @spec max_wait_ms() :: pos_integer()
  def max_wait_ms, do: @max_wait_ms

  @doc "How many jobs may run at once."
  @spec max_running() :: pos_integer()
  def max_running, do: @max_running

  @doc "Retained output cap per job, in bytes."
  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @doc """
  Idempotent supervised start. Returns `{:ok, pid}` for the already-running
  process rather than `{:error, {:already_started, _}}`, because the server is
  also started on demand by the actions and whoever loses that race still
  wants the running one.
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts \\ []) do
    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  @doc """
  Start `command` in the background.

  Options: `:owner` (required), `:cwd` (defaults to the owner), `:pty`,
  `:timeout_ms`. `{:error, :pty_unavailable}` when a pty was asked for and the
  host has no usable `script(1)` — refused rather than silently run on pipes,
  because a tool taking its non-interactive path is a wrong answer the caller
  cannot see.
  """
  @spec start(String.t(), keyword()) :: {:ok, view()} | {:error, term()}
  def start(command, opts) when is_binary(command) and is_list(opts) do
    GenServer.call(server(), {:start, command, opts}, @call_timeout_ms)
  end

  @doc "Output from `cursor` onward, plus the job's state."
  @spec poll(String.t(), String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, :job_not_found}
  def poll(id, owner, cursor) when is_binary(id) and is_integer(cursor) do
    GenServer.call(server(), {:poll, id, owner, cursor})
  end

  @doc """
  Wait for `id` to finish, giving up after `timeout_ms` (clamped to
  `max_wait_ms/0`) and answering with the still-running view. Bounded on
  purpose: the caller is an agent turn, and a turn that cannot come back is
  worse than one reporting "still running".
  """
  @spec await(String.t(), String.t(), pos_integer() | nil) ::
          {:ok, map()} | {:error, :job_not_found}
  def await(id, owner, timeout_ms) when is_binary(id) do
    budget = clamp(timeout_ms, @default_wait_ms, @max_wait_ms)
    GenServer.call(server(), {:await, id, owner, budget}, budget + 5_000)
  end

  @doc "Kill `id`'s whole process tree. Idempotent on a finished job."
  @spec kill(String.t(), String.t()) :: {:ok, map()} | {:error, :job_not_found}
  def kill(id, owner) when is_binary(id) do
    GenServer.call(server(), {:kill, id, owner}, @call_timeout_ms)
  end

  @doc "Every job `owner` started, oldest first."
  @spec list(String.t()) :: [view()]
  def list(owner) when is_binary(owner), do: GenServer.call(server(), {:list, owner})

  @doc """
  Kill and forget every job belonging to `owner`. For a surface tearing a
  session down, and for a test cleaning up after itself.
  """
  @spec reap(String.t()) :: :ok
  def reap(owner) when is_binary(owner),
    do: GenServer.call(server(), {:reap, owner}, @call_timeout_ms)

  # -- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    # Ports are linked to their owner, so one port dying abnormally would take
    # this process -- and every other job -- down with it. Trapping turns that
    # into a message, and makes `terminate/2` run on a shutdown signal, which
    # is what reaps the OS side.
    Process.flag(:trap_exit, true)
    {:ok, %{jobs: %{}, next_id: 1}}
  end

  @impl true
  def handle_call({:start, command, opts}, _from, state) do
    if running_count(state) >= @max_running do
      {:reply, {:error, :job_limit_reached}, state}
    else
      do_start(command, opts, prune(state))
    end
  end

  def handle_call({:poll, id, owner, cursor}, _from, state) do
    with_job(state, id, owner, fn job ->
      {chunk, next} = slice(job, cursor)
      {:reply, {:ok, Map.merge(view(job), %{output: chunk, cursor: next})}, state}
    end)
  end

  def handle_call({:await, id, owner, budget}, from, state) do
    with_job(state, id, owner, fn
      %{status: :running} = job ->
        timer = Process.send_after(self(), {:await_expired, from}, budget)
        {:noreply, put_job(state, %{job | waiters: [{from, timer} | job.waiters]})}

      job ->
        {:reply, {:ok, waited(job)}, state}
    end)
  end

  def handle_call({:kill, id, owner}, _from, state) do
    with_job(state, id, owner, fn
      %{status: :running} = job ->
        job = job |> kill_and_finish(:killed, nil)
        {:reply, {:ok, kill_view(job)}, settle(state, job)}

      job ->
        {:reply, {:ok, kill_view(job)}, state}
    end)
  end

  def handle_call({:list, owner}, _from, state) do
    views =
      state.jobs
      |> Map.values()
      |> Enum.filter(&(&1.owner == owner))
      |> Enum.sort_by(& &1.started_at)
      |> Enum.map(&view/1)

    {:reply, views, state}
  end

  def handle_call({:reap, owner}, _from, state) do
    {mine, others} = Enum.split_with(state.jobs, fn {_id, job} -> job.owner == owner end)
    Enum.each(mine, fn {_id, job} -> terminate_job(job) end)
    {:reply, :ok, %{state | jobs: Map.new(others)}}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case job_by_port(state, port) do
      nil -> {:noreply, state}
      job -> {:noreply, put_job(state, append(job, data))}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) when is_port(port) do
    case job_by_port(state, port) do
      nil -> {:noreply, state}
      job -> {:noreply, settle(state, finish(job, :exited, status))}
    end
  end

  # A port that died abnormally. The status message is the normal path; this is
  # the case where there is none, so the exit code stays `nil` rather than
  # inventing one.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    case job_by_port(state, port) do
      nil -> {:noreply, state}
      job -> {:noreply, settle(state, finish(job, :exited, nil))}
    end
  end

  def handle_info({:deadline, id}, state) do
    case Map.get(state.jobs, id) do
      %{status: :running} = job ->
        # 124 is what a wall-clock timeout is conventionally reported as, and
        # what the foreground action already returns.
        {:noreply, settle(state, kill_and_finish(job, :timed_out, 124))}

      _finished_or_gone ->
        {:noreply, state}
    end
  end

  def handle_info({:await_expired, from}, state) do
    case job_by_waiter(state, from) do
      nil ->
        {:noreply, state}

      job ->
        GenServer.reply(from, {:ok, waited(job)})
        {:noreply, put_job(state, drop_waiter(job, from))}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(Map.values(state.jobs), &terminate_job/1)
    :ok
  end

  # -- start -----------------------------------------------------------------

  defp do_start(command, opts, state) do
    owner = Keyword.fetch!(opts, :owner)
    cwd = Keyword.get(opts, :cwd) || owner
    pty? = Keyword.get(opts, :pty, false) == true
    budget = clamp(Keyword.get(opts, :timeout_ms), @default_timeout_ms, @max_timeout_ms)

    case open_port(command, cwd, pty?) do
      {:error, _reason} = error ->
        {:reply, error, state}

      {:ok, port} ->
        id = "job_#{state.next_id}"
        job = new_job(id, owner, command, cwd, pty?, port, budget)
        {:reply, {:ok, view(job)}, %{put_job(state, job) | next_id: state.next_id + 1}}
    end
  end

  defp new_job(id, owner, command, cwd, pty?, port, budget) do
    %{
      id: id,
      owner: owner,
      command: command,
      cwd: cwd,
      pty: pty?,
      port: port,
      os_pid: os_pid(port),
      output: "",
      produced: 0,
      truncated: false,
      status: :running,
      exit_code: nil,
      killed: false,
      confirmed_dead: false,
      started_at: now_ms(),
      finished_at: nil,
      timer: Process.send_after(self(), {:deadline, id}, budget),
      waiters: []
    }
  end

  # A failed spawn is an error to the caller, never a crash: this process owns
  # every other job's port, so raising here would close all of them.
  defp open_port(command, cwd, pty?) do
    case port_spec(command, pty?) do
      {:error, _reason} = error -> error
      {:ok, executable, args, extra} -> {:ok, spawn_port(executable, args, cwd, extra)}
    end
  rescue
    error -> {:error, {:spawn_failed, Exception.message(error)}}
  end

  defp port_spec(command, false), do: {:ok, sh(), ["-c", command], [:in]}

  defp port_spec(command, true) do
    case Pty.spawn_spec(sh(), command) do
      :unavailable ->
        {:error, :pty_unavailable}

      # No `:in` under a pty: the immediate EOF is echoed back through the line
      # discipline as `^D\b\b`. See `Raxol.Agent.Shell.Pty`.
      {:ok, {executable, args, env}} ->
        {:ok, executable, args, [{:env, env}]}
    end
  end

  defp spawn_port(executable, args, cwd, extra) do
    Port.open(
      {:spawn_executable, executable},
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}, {:cd, cwd}] ++ extra
    )
  end

  defp sh, do: System.find_executable("sh") || "/bin/sh"

  # -- job state -------------------------------------------------------------

  defp append(job, data) do
    produced = job.produced + byte_size(data)
    room = @max_output_bytes - byte_size(job.output)

    cond do
      room <= 0 ->
        %{job | produced: produced, truncated: true}

      byte_size(data) <= room ->
        %{job | output: job.output <> data, produced: produced}

      true ->
        %{
          job
          | output: job.output <> binary_part(data, 0, room),
            produced: produced,
            truncated: true
        }
    end
  end

  defp slice(job, cursor) do
    size = byte_size(job.output)
    from = cursor |> max(0) |> min(size)
    {binary_part(job.output, from, size - from), size}
  end

  defp kill_and_finish(job, status, exit_code) do
    {killed?, confirmed?} = kill_tree(job)

    job
    |> finish(status, exit_code)
    |> Map.merge(%{killed: killed?, confirmed_dead: confirmed?})
  end

  defp finish(job, status, exit_code) do
    cancel_timer(job.timer)
    if job.port, do: SpawnedPort.close(job.port)

    %{
      job
      | status: status,
        exit_code: exit_code,
        port: nil,
        timer: nil,
        finished_at: now_ms()
    }
  end

  # The pty case is not `Interrupt.kill_os_pid/1` on the port program: `script`
  # `setsid`s the command into a session of its own, so that group is what has
  # to die and what the claim is about. `Raxol.Agent.Shell.Pty.kill_tree/1`
  # owns both halves.
  defp kill_tree(%{os_pid: os_pid, pty: true}), do: Pty.kill_tree(os_pid)

  defp kill_tree(%{os_pid: os_pid, pty: false}) do
    {disposition, confirmed?, _os_pid} = Interrupt.kill_os_pid(os_pid)
    {disposition == :killed, confirmed?}
  end

  defp terminate_job(%{status: :running} = job) do
    kill_and_finish(job, :killed, nil)
    :ok
  end

  defp terminate_job(_finished), do: :ok

  # Store a finished job and answer everyone waiting on it.
  defp settle(state, job) do
    reply = {:ok, waited(job)}

    Enum.each(job.waiters, fn {from, timer} ->
      cancel_timer(timer)
      GenServer.reply(from, reply)
    end)

    put_job(state, %{job | waiters: []})
  end

  defp drop_waiter(job, from),
    do: %{job | waiters: Enum.reject(job.waiters, fn {waiter, _} -> waiter == from end)}

  # -- views -----------------------------------------------------------------

  defp view(job) do
    %{
      job_id: job.id,
      command: job.command,
      pty: job.pty,
      status: Atom.to_string(job.status),
      running: job.status == :running,
      exit_code: job.exit_code,
      os_pid: job.os_pid,
      runtime_ms: (job.finished_at || now_ms()) - job.started_at,
      output_bytes: job.produced,
      truncated: job.truncated
    }
  end

  defp waited(job), do: Map.put(view(job), :waited, true)

  defp kill_view(job),
    do: Map.merge(view(job), %{killed: job.killed, confirmed_dead: job.confirmed_dead})

  # -- lookups ---------------------------------------------------------------

  # An id belonging to another owner answers exactly as a missing one does:
  # "no such job" must not double as an existence oracle for someone else's.
  defp with_job(state, id, owner, fun) do
    case Map.get(state.jobs, id) do
      %{owner: ^owner} = job -> fun.(job)
      _ -> {:reply, {:error, :job_not_found}, state}
    end
  end

  defp job_by_port(state, port),
    do: Enum.find_value(state.jobs, fn {_id, job} -> job.port == port && job end)

  defp job_by_waiter(state, from) do
    Enum.find_value(state.jobs, fn {_id, job} ->
      Enum.any?(job.waiters, fn {waiter, _timer} -> waiter == from end) && job
    end)
  end

  defp put_job(state, job), do: %{state | jobs: Map.put(state.jobs, job.id, job)}

  defp running_count(state),
    do: Enum.count(state.jobs, fn {_id, job} -> job.status == :running end)

  # Retention is bounded by dropping the oldest FINISHED entries; a running job
  # is never pruned, because its port would be closed under it.
  defp prune(state) do
    over = map_size(state.jobs) - @max_retained + 1

    if over > 0 do
      dropped =
        state.jobs
        |> Map.values()
        |> Enum.reject(&(&1.status == :running))
        |> Enum.sort_by(& &1.finished_at)
        |> Enum.take(over)
        |> Enum.map(& &1.id)

      %{state | jobs: Map.drop(state.jobs, dropped)}
    else
      state
    end
  end

  # -- misc ------------------------------------------------------------------

  defp server do
    case Process.whereis(__MODULE__) do
      nil -> lazy_start()
      pid -> pid
    end
  end

  defp lazy_start do
    # `start`, not `start_link`: the caller is an agent turn, and linking would
    # make a turn's death close every background job's port -- the exact
    # cross-turn survival this module exists to provide.
    case GenServer.start(__MODULE__, [], name: __MODULE__) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp clamp(value, _default, ceiling) when is_integer(value) and value > 0,
    do: min(value, ceiling)

  defp clamp(_value, default, ceiling), do: min(default, ceiling)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      _ -> nil
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
