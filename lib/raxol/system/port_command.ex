defmodule Raxol.System.PortCommand do
  @moduledoc """
  Utility for running external commands with stdin input via Port.

  This module provides a way to execute external commands and pass
  data to their stdin, which System.cmd/3 doesn't support directly.

  ## Why the stdin goes through a temp file

  A `:spawn_executable` port cannot half-close: the only way to signal
  EOF on the child's stdin is `Port.close/1`, which also tears the port
  down before its `{:exit_status, _}` is delivered. Commands that read
  stdin to EOF (`pbcopy`, `xclip`, `flamegraph.pl`) therefore never
  finished under a plain command/close sequence, and the caller blocked
  the full timeout. Feeding stdin from a temporary file via a shell
  redirect gives the child a real EOF, so it exits on its own and the
  port reports its status like any self-terminating process.
  """

  @doc """
  Runs a command with the given arguments, passing input to stdin.

  Returns `{:ok, output}` on success (exit code 0) or `{:error, output}` on failure.

  ## Options

  - `:timeout` - Maximum time to wait for the command in milliseconds (default: 30000)

  ## Examples

      iex> PortCommand.run("cat", [], "hello")
      {:ok, "hello"}

      iex> PortCommand.run("grep", ["pattern"], "no match here")
      {:error, ""}
  """
  @spec run(String.t(), [String.t()], String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(command, args, input, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, executable} <- find_executable(command),
         {:ok, shell} <- find_shell(),
         {:ok, stdin_path} <- write_stdin(input) do
      try do
        run_with_stdin_file(shell, executable, args, stdin_path, timeout)
      after
        _ = File.rm(stdin_path)
      end
    else
      {:error, _} = error -> error
    end
  end

  defp find_executable(command) do
    case System.find_executable(command) do
      nil -> {:error, "command not found: #{command}"}
      executable -> {:ok, executable}
    end
  end

  # The shell is only the vehicle for the stdin redirect; the actual command
  # and its arguments are still passed as separate argv entries (`"$0" "$@"`
  # on POSIX), never re-parsed by the shell, so caller args cannot inject.
  defp find_shell do
    case :os.type() do
      {:win32, _} -> find_windows_shell()
      _ -> find_posix_shell()
    end
  end

  defp find_posix_shell do
    cond do
      shell = System.find_executable("sh") -> {:ok, shell}
      File.exists?("/bin/sh") -> {:ok, "/bin/sh"}
      true -> {:error, "no POSIX shell available to redirect stdin"}
    end
  end

  defp find_windows_shell do
    case System.get_env("COMSPEC") || System.find_executable("cmd") do
      nil -> {:error, "no command shell available to redirect stdin"}
      shell -> {:ok, shell}
    end
  end

  # Exclusive (O_EXCL) create so a pre-planted symlink in a shared tmp dir
  # cannot redirect the write or leak the input; chmod tightens to owner-only.
  defp write_stdin(input) do
    dir = System.tmp_dir!()

    name =
      "raxol_portcmd_#{:erlang.unique_integer([:positive])}_#{:os.system_time(:nanosecond)}"

    path = Path.join(dir, name)

    case File.write(path, input, [:exclusive, :binary]) do
      :ok ->
        _ = File.chmod(path, 0o600)
        {:ok, path}

      {:error, reason} ->
        {:error, "failed to buffer stdin: #{:file.format_error(reason)}"}
    end
  end

  defp run_with_stdin_file(shell, executable, args, stdin_path, timeout) do
    port = spawn_port(shell, executable, args, stdin_path)
    collect_output(port, "", timeout)
  end

  defp spawn_port(shell, executable, args, stdin_path) do
    spawn_args =
      case :os.type() do
        {:win32, _} -> windows_args(executable, args, stdin_path)
        _ -> posix_args(executable, args, stdin_path)
      end

    Port.open(
      {:spawn_executable, shell},
      [:binary, :exit_status, :stderr_to_stdout, {:args, spawn_args}]
    )
  end

  # `exec "$0" "$@" < <stdin_path>`: the redirect target is single-quoted so a
  # tmp dir with spaces is safe; the command and args ride in argv, unquoted by
  # the shell, so there is no argument-injection surface.
  defp posix_args(executable, args, stdin_path) do
    redirect = "exec \"$0\" \"$@\" < #{posix_single_quote(stdin_path)}"
    ["-c", redirect, executable | args]
  end

  defp posix_single_quote(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  # cmd.exe cannot pass argv through a variable the way POSIX `"$@"` does, so
  # the command line is assembled and each token double-quoted. Callers here
  # are internal (fixed clipboard invocations), not attacker-controlled.
  defp windows_args(executable, args, stdin_path) do
    command_line =
      [executable | args]
      |> Enum.map_join(" ", &windows_quote/1)

    ["/c", "#{command_line} < #{windows_quote(stdin_path)}"]
  end

  defp windows_quote(value) do
    "\"" <> String.replace(value, "\"", "\"\"") <> "\""
  end

  @spec collect_output(port(), String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defp collect_output(port, acc, timeout) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout)

      {^port, {:exit_status, 0}} ->
        {:ok, acc}

      {^port, {:exit_status, _status}} ->
        {:error, acc}
    after
      timeout ->
        kill_child(port)
        _ = safe_close(port)
        {:error, "timeout waiting for command"}
    end
  end

  # On timeout the caller has stopped waiting, but "stopped waiting" must not
  # orphan the child: `Port.close/1` closes the port yet leaves the OS process
  # alive. The `sh -c 'exec ...'` shell replaces itself with the command, so the
  # port's os_pid IS the command — kill it. Best-effort, Unix only.
  defp kill_child(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid),
         kill when is_binary(kill) <- System.find_executable("kill") do
      _ = System.cmd(kill, ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    end
  rescue
    _ -> :ok
  end

  defp safe_close(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end
end
