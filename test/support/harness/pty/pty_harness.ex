defmodule Raxol.Test.PtyHarness do
  @moduledoc """
  Elixir wrapper around the vendored `pty_spawn.py` helper (unit TP,
  `docs/proposals/in-flight/harness-ui-roadmap.md`).

  Canonical location: `test/support/harness/pty/` (this directory). The
  03-lifecycle design doc's earlier draft said `test/support/pty/`; this
  path is the one that shipped -- consumers (T2d/T2a/T25 suites) should
  `alias Raxol.Test.PtyHarness` and not care about the directory.

  Spawns a command under a fresh pty via a `Port`, delivers signals to its
  process group, tees its combined stdout/stderr byte stream to a capture
  file, and takes a post-mortem `stty -a` snapshot of the pty's kernel line
  discipline. This is Tier B of
  `docs/proposals/in-flight/harness-ui-testing/03-lifecycle.md` -- the tier
  reserved for facts that need a *real* controlling tty (signal delivery,
  kernel line-discipline residual, kill-9 recovery, job control) that a pure
  byte-capture harness cannot observe.

  Requires `python3` on `PATH`. Call `available?/0` from a test's
  `setup_all` and return `{:skip, reason}` when it's absent so CI images
  without python3 skip cleanly instead of failing:

      setup_all do
        if Raxol.Test.PtyHarness.available?() do
          :ok
        else
          {:skip, "python3 not found on PATH"}
        end
      end

  ## Example

      {:ok, session} = PtyHarness.start(["sh", "-c", "echo READY; sleep 30"])
      :ok = PtyHarness.await_capture(session, "READY", 2_000)
      :ok = PtyHarness.signal(session, :term)
      {:ok, {:exit, 143}} = PtyHarness.await(session)
      {:ok, output} = PtyHarness.read_output(session)
      :ok = PtyHarness.stop(session)

  ## Capture completeness

  A successful `await/2` exit result (`{:exit, _}` / `{:signaled, _}`) is a
  DRAIN BARRIER: the wrapper drains the pty master to EOF and closes the
  capture file before replying, so `read_output/1` after such an `await`
  sees the complete byte stream including trailing teardown bytes. Do not
  assert capture completeness without an intervening successful `await`.

  ## Failure taxonomy

  Every public function returns `:ok`/`{:ok, value}` or `{:error, reason}`
  where `reason` is an atom or a `{atom, detail}` tuple -- never a bare
  string:

    * `:python3_not_found` -- `start/2` only; no `python3` on PATH
    * `:spawn_timeout` -- wrapper never sent its `SPAWNED` handshake
    * `:timeout` -- the wrapper didn't reply in time, or `await/2`'s child
      didn't change state within its bound
    * `:wrapper_exited` -- command attempted on a closed/dead wrapper port
    * `{:wrapper_exited, exit_status}` -- wrapper died mid-command
    * `{:wrapper_error, message}` -- the wrapper replied `ERR <message>`
      (e.g. no such process, bad signal, stty failure)
    * `:bad_protocol` -- a wrapper reply failed to parse (malformed number)
    * `:short_write` -- `write/2` reported fewer bytes than sent (should
      not happen; the wrapper loops until drained)
    * `{:unexpected_response, line}` -- reply outside the protocol grammar
    * `File.read/1` posix reasons pass through from `read_output/1`

  ## Concurrency contract

  A session is NOT reentrant: one in-flight command at a time, from the
  process that called `start/2` (the Port owner -- replies are delivered
  to it, so cross-process calls hang). Calling `stop/1` while another
  command (e.g. a long `await/2`) is in flight is undefined behavior --
  sequence your commands.
  """

  defstruct [:port, :capture_path, :os_pid]

  @type t :: %__MODULE__{
          port: port(),
          capture_path: Path.t(),
          os_pid: pos_integer()
        }

  @type signal ::
          :term | :int | :kill | :tstp | :stop | :cont | :hup | :usr1 | :usr2
  @type wait_result ::
          {:exit, non_neg_integer()}
          | {:signaled, non_neg_integer()}
          | {:stopped, non_neg_integer()}

  @wrapper_path Path.join(__DIR__, "pty_spawn.py")
  @spawn_timeout_ms 5_000
  @default_command_timeout_ms 5_000

  @doc """
  Is `python3` on `PATH`? Use from `setup_all` to skip Tier B tests cleanly
  (via `{:skip, reason}`) rather than failing on images without it.
  """
  @spec available? :: boolean()
  def available? do
    System.find_executable("python3") != nil
  end

  @doc """
  Spawn `argv` (a non-empty list, `argv` head is the executable resolved via
  the child's own `PATH` lookup) under a fresh pty.

  Options:
    * `:capture_path` -- where the tee'd byte stream is written. Defaults to
      a fresh path under `System.tmp_dir!/0`.
    * `:spawn_timeout_ms` -- how long to wait for the wrapper's initial
      `SPAWNED <pid>` handshake. Defaults to #{@spawn_timeout_ms}.
    * `:winsize` -- `{rows, cols}` pty window size, applied via TIOCSWINSZ
      before exec. Defaults to `{24, 80}` (never the kernel's 0x0 default).
    * `:cwd` -- child working directory.
    * `:env` -- map of extra child environment variables (string keys and
      values), merged over the inherited environment.
  """
  @spec start([String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(argv, opts \\ [])

  def start(argv, opts) when is_list(argv) and argv != [] do
    case System.find_executable("python3") do
      nil ->
        {:error, :python3_not_found}

      python3 ->
        capture_path =
          Keyword.get_lazy(opts, :capture_path, &tmp_capture_path/0)

        spawn_timeout = Keyword.get(opts, :spawn_timeout_ms, @spawn_timeout_ms)

        wrapper_args =
          Enum.concat([
            ["--capture", capture_path],
            winsize_args(opts),
            cwd_args(opts),
            env_args(opts),
            ["--" | argv]
          ])

        port =
          Port.open({:spawn_executable, python3}, [
            :binary,
            :exit_status,
            {:line, 65_536},
            args: [@wrapper_path | wrapper_args]
          ])

        handle_spawn_handshake(port, capture_path, spawn_timeout)
    end
  end

  defp handle_spawn_handshake(port, capture_path, timeout) do
    case receive_line(port, timeout) do
      {:ok, "SPAWNED " <> pid_str} ->
        case parse_int(pid_str) do
          {:ok, os_pid} ->
            {:ok,
             %__MODULE__{
               port: port,
               capture_path: capture_path,
               os_pid: os_pid
             }}

          :error ->
            safe_close(port)
            {:error, :bad_protocol}
        end

      {:ok, "ERR " <> reason} ->
        safe_close(port)
        {:error, {:wrapper_error, reason}}

      {:error, :timeout} ->
        safe_close(port)
        {:error, :spawn_timeout}

      {:error, other} ->
        safe_close(port)
        {:error, other}
    end
  end

  @doc """
  Deliver `sig` to the child's process group (covers `sh -c` subshell
  chains).

  Job-control caveat: the spawned child is a session leader whose process
  group is orphaned (its parent -- the wrapper -- lives in another session),
  and POSIX discards default-action stop signals (SIGTSTP/SIGTTIN/SIGTTOU)
  sent to orphaned process groups. So `:tstp` only stops a child that
  handles the signal -- which real inline apps do (03-lifecycle §1.3
  requires the app to catch SIGTSTP, release raw+region, then re-raise).
  Use `:stop` (SIGSTOP, uncatchable and undiscardable) to stop an
  arbitrary child unconditionally.
  """
  @spec signal(t(), signal()) :: :ok | {:error, term()}
  def signal(session, sig)
      when sig in [:term, :int, :kill, :tstp, :stop, :cont, :hup, :usr1, :usr2] do
    case command(session, "SIG #{sig}") do
      {:ok, "OK SIG " <> _} -> :ok
      {:ok, "ERR " <> reason} -> {:error, {:wrapper_error, reason}}
      {:error, _} = err -> err
      {:ok, other} -> {:error, {:unexpected_response, other}}
    end
  end

  @doc "Inject `bytes` into the pty master, as if typed (e.g. `<<3>>` for Ctrl-C)."
  @spec write(t(), binary()) :: :ok | {:error, term()}
  def write(session, bytes) when is_binary(bytes) do
    hex = Base.encode16(bytes, case: :lower)
    expected = byte_size(bytes)

    case command(session, "WRITE #{hex}") do
      {:ok, "OK WRITE " <> count} ->
        case parse_int(count) do
          {:ok, ^expected} -> :ok
          {:ok, _short} -> {:error, :short_write}
          :error -> {:error, :bad_protocol}
        end

      {:ok, "ERR " <> reason} ->
        {:error, {:wrapper_error, reason}}

      {:error, _} = err ->
        err

      {:ok, other} ->
        {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Post-mortem `stty -a` against the pty *slave* -- kernel line-discipline
  state, independent of whether the child process is still alive.
  """
  @spec post_mortem(t()) :: {:ok, String.t()} | {:error, term()}
  def post_mortem(session) do
    case command(session, "STTY") do
      {:ok, "STTY " <> b64} -> Base.decode64(b64) |> wrap_decode_result()
      {:ok, "ERR " <> reason} -> {:error, {:wrapper_error, reason}}
      {:error, _} = err -> err
      {:ok, other} -> {:error, {:unexpected_response, other}}
    end
  end

  defp wrap_decode_result({:ok, bin}), do: {:ok, bin}
  defp wrap_decode_result(:error), do: {:error, :bad_base64}

  @doc """
  The documented kill-9 recovery one-liner: `ESC [ r` (reset scroll region)
  then `stty sane`, run directly against the pty slave.
  """
  @spec recover(t()) :: :ok | {:error, term()}
  def recover(session) do
    case command(session, "RECOVER") do
      {:ok, "OK RECOVER"} -> :ok
      {:ok, "ERR " <> reason} -> {:error, {:wrapper_error, reason}}
      {:error, _} = err -> err
      {:ok, other} -> {:error, {:unexpected_response, other}}
    end
  end

  @doc """
  Block (bounded by `timeout_ms`) until the child changes state.

  A SIGTSTP/SIGSTOP-stopped child reports as `{:stopped, signum}` (WUNTRACED)
  -- distinct from `{:error, :timeout}` -- so job-control tests (T25 Ctrl-Z /
  `fg`) can observe the stop. Each stop transition is reported once; the
  child is NOT reaped by it, so a later `await/2` still observes the eventual
  exit after `signal(session, :cont)`. Exit results are idempotent: calling
  again after a reap returns the same status instead of erroring.
  """
  @spec await(t(), non_neg_integer()) :: {:ok, wait_result()} | {:error, term()}
  def await(session, timeout_ms \\ @default_command_timeout_ms) do
    # The wrapper's WAIT drain-joins the capture pump for +5s max on exit,
    # so give the port reply 6s of headroom beyond the child-state bound.
    case command(session, "WAIT #{timeout_ms}", timeout_ms + 6_000) do
      {:ok, "EXIT " <> code} -> tag_int(:exit, code)
      {:ok, "SIGNALED " <> sig} -> tag_int(:signaled, sig)
      {:ok, "STOPPED " <> sig} -> tag_int(:stopped, sig)
      {:ok, "TIMEOUT"} -> {:error, :timeout}
      {:ok, "ERR " <> reason} -> {:error, {:wrapper_error, reason}}
      {:error, _} = err -> err
      {:ok, other} -> {:error, {:unexpected_response, other}}
    end
  end

  defp tag_int(tag, str) do
    case parse_int(str) do
      {:ok, n} -> {:ok, {tag, n}}
      :error -> {:error, :bad_protocol}
    end
  end

  @doc "Read everything captured from the child's pty output so far."
  @spec read_output(t()) :: {:ok, binary()} | {:error, term()}
  def read_output(session), do: File.read(session.capture_path)

  @doc """
  Poll `read_output/1` (bounded by `timeout_ms`) until `substring` appears --
  the "no sleeps" way to know a child has reached an armed/ready state before
  driving the next step (e.g. waiting for a `READY` sentinel before sending
  a signal).
  """
  @spec await_capture(t(), binary(), non_neg_integer()) ::
          :ok | {:error, :timeout}
  def await_capture(session, substring, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_capture(session, substring, deadline)
  end

  defp poll_capture(session, substring, deadline) do
    case read_output(session) do
      {:ok, content} ->
        if String.contains?(content, substring),
          do: :ok,
          else: retry_or_timeout(session, substring, deadline)

      {:error, _} ->
        retry_or_timeout(session, substring, deadline)
    end
  end

  defp retry_or_timeout(session, substring, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :timeout}
    else
      Process.sleep(20)
      poll_capture(session, substring, deadline)
    end
  end

  @doc """
  Stop the harness: closes the port, which signals EOF to the wrapper's
  stdin. The wrapper best-effort SIGKILLs the child's process group before
  exiting, so nothing is left running even if the test never reaped it.
  """
  @spec stop(t()) :: :ok
  def stop(session), do: safe_close(session.port)

  # -- protocol plumbing --

  defp command(session, line, timeout \\ @default_command_timeout_ms) do
    # A closed/exited wrapper port must surface as an error tuple, not an
    # ArgumentError crash (Port.command to a dead port raises badarg). The
    # Port.info check catches the common case; the rescue closes the
    # alive-at-check-dead-at-command race.
    if Port.info(session.port) == nil do
      {:error, :wrapper_exited}
    else
      Port.command(session.port, line <> "\n")
      receive_line(session.port, timeout)
    end
  rescue
    ArgumentError -> {:error, :wrapper_exited}
  end

  defp receive_line(port, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {:ok, line}

      {^port, {:data, {:noeol, partial}}} ->
        accumulate_line(port, partial, timeout)

      {^port, {:exit_status, status}} ->
        {:error, {:wrapper_exited, status}}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp accumulate_line(port, acc, timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {:ok, acc <> line}

      {^port, {:data, {:noeol, more}}} ->
        accumulate_line(port, acc <> more, timeout)

      {^port, {:exit_status, status}} ->
        {:error, {:wrapper_exited, status}}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp tmp_capture_path do
    unique =
      "#{:erlang.unique_integer([:positive, :monotonic])}_#{System.os_time(:microsecond)}"

    Path.join(System.tmp_dir!(), "raxol_pty_capture_#{unique}.bin")
  end

  # -- start/2 option -> wrapper argv translation --

  defp winsize_args(opts) do
    {rows, cols} = Keyword.get(opts, :winsize, {24, 80})

    if is_integer(rows) and is_integer(cols) and rows > 0 and cols > 0 do
      ["--winsize", "#{rows}x#{cols}"]
    else
      raise ArgumentError,
            ":winsize must be {rows, cols} positive integers, got: " <>
              inspect(Keyword.get(opts, :winsize))
    end
  end

  defp cwd_args(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> []
      cwd when is_binary(cwd) -> ["--cwd", cwd]
    end
  end

  defp env_args(opts) do
    opts
    |> Keyword.get(:env, %{})
    |> Enum.flat_map(fn {key, val} ->
      ["--env", "#{key}=#{val}"]
    end)
  end
end
