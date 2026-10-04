defmodule Raxol.Broker.KeyProvider.Keychain do
  @moduledoc """
  The credential-wrapping key as a generic password in the macOS login
  keychain, through `/usr/bin/security`.

  Reading is `security find-generic-password -s raxol.broker.credential-key
  -a robinhood -w`, run with `Raxol.Agent.Backend.Credentials.run_executable/3`
  (bounded, stdin on `/dev/null`). The key is printed on the child's stdout,
  which is this process's pipe.

  Writing must not put the key on argv, where any process of the same user
  can read it from the process table. `security add-generic-password -w KEY`
  would, so the command line is written to `security -i` over STDIN instead,
  behind `head -n 1` so the child sees end-of-file after one line and exits
  with the command's status. Only the fixed script and the executable path
  appear in any argv. The add never uses `-U`: an existing item is never
  replaced (that would orphan the stored ciphertext), and losing a race to
  another writer just means reading back the key it stored.

  What the keychain protects against is a copy of `~/.raxol` leaving the
  machine (a backup, a dotfile sync). It does not stop code already running
  as this user: an item created by `security` trusts that binary, so any
  same-user process can read it without a prompt.

  Options: `:executable` (default `/usr/bin/security`), `:timeout_ms`.
  Errors are `{:error, {:keychain_unavailable, reason}}` and carry no
  command output.
  """

  @behaviour Raxol.Broker.KeyProvider

  alias Raxol.Agent.Backend.Credentials
  alias Raxol.Broker.KeyProvider

  @service "raxol.broker.credential-key"
  @account "robinhood"
  @executable "/usr/bin/security"
  @timeout_ms 15_000

  # `security` exits 44 when the item does not exist, 45 when an add finds
  # one already there.
  @not_found 44
  @duplicate 45

  @impl true
  def load_key(opts) do
    with {:ok, exe} <- executable(opts) do
      read(exe, timeout(opts))
    end
  end

  @impl true
  def create_key(opts) do
    with {:ok, exe} <- executable(opts),
         :ok <- add(exe, :crypto.strong_rand_bytes(32), timeout(opts)) do
      case read(exe, timeout(opts)) do
        {:ok, key} -> {:ok, key}
        :none -> {:error, {:keychain_unavailable, :not_stored}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp executable(opts) do
    exe = Keyword.get(opts, :executable, @executable)

    if File.regular?(exe),
      do: {:ok, exe},
      else: {:error, {:keychain_unavailable, :no_security_cli}}
  end

  defp timeout(opts), do: Keyword.get(opts, :timeout_ms, @timeout_ms)

  defp read(exe, timeout) do
    args = ["find-generic-password", "-s", @service, "-a", @account, "-w"]

    case Credentials.run_executable(exe, args, timeout) do
      {:error, :op_timeout} ->
        {:error, {:keychain_unavailable, :timeout}}

      # Carries no command output: `:op_spawn_failed` or `{:op_spawn_failed, posix}`.
      {:error, spawn_failed} ->
        {:error, {:keychain_unavailable, spawn_failed}}

      {out, 0} ->
        case KeyProvider.decode_hex(out) do
          {:ok, key} -> {:ok, key}
          :error -> {:error, {:keychain_unavailable, :malformed_key}}
        end

      {_out, @not_found} ->
        :none

      {_out, status} ->
        {:error, {:keychain_unavailable, {:exit, status}}}
    end
  end

  defp add(exe, key, timeout) do
    hex = Base.encode16(key, case: :lower)

    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [:binary, :exit_status, :stderr_to_stdout, args: ["-c", ~S(head -n 1 | "$0" -i), exe]]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _gone -> nil
      end

    true = Port.command(port, "add-generic-password -s #{@service} -a #{@account} -w #{hex}\n")

    case await_exit(port, System.monotonic_time(:millisecond) + timeout) do
      {:ok, status} when status in [0, @duplicate] ->
        :ok

      {:ok, status} ->
        {:error, {:keychain_unavailable, {:exit, status}}}

      :timeout ->
        kill(port, os_pid)
        {:error, {:keychain_unavailable, :timeout}}
    end
  end

  # Output is drained and dropped: it can only be an error message, and an
  # error term here never carries command output.
  defp await_exit(port, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, _chunk}} -> await_exit(port, deadline)
      {^port, {:exit_status, status}} -> {:ok, status}
    after
      remaining -> :timeout
    end
  end

  defp kill(port, os_pid) do
    if os_pid, do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
    Port.close(port)
    :ok
  catch
    _kind, _reason -> :ok
  end
end
