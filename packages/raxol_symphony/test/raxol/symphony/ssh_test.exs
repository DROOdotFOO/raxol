defmodule Raxol.Symphony.SshTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Ssh
  alias Raxol.Symphony.Worker.HostSpec

  # Mirrors `Ssh.@reap_poll_seconds`, which is private. The orphan test has to
  # know which `sleep` the watcher spawns in order to look for it; if the two
  # drift, that test stops looking at anything and silently passes, so the
  # generated command is asserted to still carry this value.
  @reap_poll_seconds 5

  defp spec(fields \\ []), do: struct(%HostSpec{host: "build-1"}, fields)

  describe "target/1" do
    test "is host alone or user@host" do
      assert Ssh.target(spec()) == "build-1"
      assert Ssh.target(spec(user: "ci")) == "ci@build-1"
    end
  end

  describe "option_args/1" do
    test "always includes non-interactive base options and keepalive" do
      args = Ssh.option_args(spec())
      assert "BatchMode=yes" in args
      assert "ConnectTimeout=15" in args
      assert "ServerAliveInterval=30" in args
      assert "ServerAliveCountMax=3" in args
      # Default host-key policy is unchanged (trust-on-first-use).
      assert "StrictHostKeyChecking=accept-new" in args
    end

    # `Workspace` budgets its local wait on `connect_timeout_ms/0`, because the
    # remote deadline is a `sleep` that does not start until the connection is
    # up. If the two ever drift, the local half silently starts winning the race
    # again and a host that never accepted reads as a hook that ran too long.
    test "connect_timeout_ms/0 is the same bound the ssh args carry" do
      assert "ConnectTimeout=#{div(Ssh.connect_timeout_ms(), 1000)}" in Ssh.option_args(spec())
    end

    test "honors a forced host-key mode and a known_hosts file" do
      args =
        Ssh.option_args(spec(strict_host_key_checking: :yes, known_hosts: "/etc/ssh/known_hosts"))

      assert "StrictHostKeyChecking=yes" in args
      assert "UserKnownHostsFile=/etc/ssh/known_hosts" in args
      refute "StrictHostKeyChecking=accept-new" in args
    end

    test "maps the :no mode and omits UserKnownHostsFile when absent" do
      args = Ssh.option_args(spec(strict_host_key_checking: :no))
      assert "StrictHostKeyChecking=no" in args
      refute Enum.any?(args, &String.starts_with?(&1, "UserKnownHostsFile="))
    end

    test "adds -p for a port and -i for an identity file" do
      args = Ssh.option_args(spec(port: 2222, identity_file: "/keys/id_ci"))
      assert ["-p", "2222"] == Enum.slice(args, -4, 2)
      assert ["-i", "/keys/id_ci"] == Enum.slice(args, -2, 2)
    end

    test "omits -p and -i when absent" do
      args = Ssh.option_args(spec())
      refute "-p" in args
      refute "-i" in args
    end
  end

  describe "reap_on_disconnect/1" do
    test "ties the command to the ssh connection without touching its stdio" do
      wrapped = Ssh.reap_on_disconnect("codex app-server")

      # The command runs with stdin preserved (<&0), backgrounded, and a
      # watcher polls the shell's parent, signalling the command when it dies.
      # The `{ …; }` group makes the redirect and `&` bind to the whole script.
      assert wrapped =~ "{ codex app-server\n} <&0 &"
      assert wrapped =~ "__rx_ppid=$PPID"
      assert wrapped =~ "ps -p $__rx_ppid"
      assert wrapped =~ "kill $__rx_pid"
      assert wrapped =~ "wait $__rx_pid"
      # Job control is on for the fork (so the group kill can reach children)
      # and off immediately after (so bash does not narrate job transitions
      # into the command's own output).
      assert wrapped =~ "set -m"
      assert wrapped =~ "set +m"
      assert wrapped =~ "kill -- -$__rx_pid"
      # Framing-safe: no pty request, no single quotes to break remote_bash.
      refute wrapped =~ "-t"
      refute wrapped =~ "'"
    end

    test "is syntactically valid bash" do
      # `-n` parses without executing: a syntax error would be non-zero.
      {_out, status} = System.cmd("bash", ["-n", "-c", Ssh.reap_on_disconnect("codex")])
      assert status == 0
    end

    test "a short command returns as soon as it exits, not a poll interval later" do
      # The watcher polls on a multi-second interval. Two ways that interval
      # can leak into a fast command's runtime, both of which have bitten:
      # polling inline (so `wait` is unreachable until the sleep elapses), and
      # letting the watcher inherit stdout (so the reader waits for EOF on a
      # pipe the lingering `sleep` still holds open).
      wrapped = Ssh.reap_on_disconnect("echo done")

      {elapsed_us, {output, status}} =
        :timer.tc(fn -> System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true) end)

      assert status == 0
      assert output =~ "done"

      # The bound sits in the gap between correct (tens of ms) and either
      # regression (a full 5s poll interval), with room for a loaded CI runner
      # on both sides. Tightening it to what the happy path actually costs
      # would buy no extra detection and would flake.
      assert elapsed_us < 3_000_000, "took #{div(elapsed_us, 1000)}ms, expected well under 5s"
    end

    test "the command's real exit status survives the wrapper" do
      wrapped = Ssh.reap_on_disconnect("exit 7")
      assert {_out, 7} = System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true)
    end

    test "a MULTI-LINE script reports its own status, not a trailing null command's" do
      # A hook is normally multi-line and ends in a newline. Without the
      # `{ …; }` group the appended ` <&0 & …` parses as a separate null
      # command, `wait` returns ITS status, and a hook that failed on its last
      # line was reported as success. SPEC s9.4 makes those failures fatal.
      wrapped = Ssh.reap_on_disconnect("echo start\nfalse\n")

      assert {output, 1} = System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true)
      assert output =~ "start"
    end

    test "a deadline kills the command AND its children, then returns at once" do
      marker = Path.join(System.tmp_dir!(), "rx_deadline_#{:erlang.unique_integer([:positive])}")
      on_exit(fn -> File.rm(marker) end)

      wrapped = Ssh.reap_on_disconnect("sleep 6\ntouch #{marker}\n", deadline_seconds: 1)

      {elapsed_us, {_out, status}} =
        :timer.tc(fn -> System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true) end)

      refute status == 0
      refute File.exists?(marker), "the hook kept running past its deadline"

      # Killing only the subshell would leave `sleep` holding the inherited
      # stdout pipe, so the read would block for the command's full 6s even
      # though it was "killed". The group kill is what makes this prompt. The
      # bound discriminates 1s from 6s with headroom for a loaded runner.
      assert elapsed_us < 4_500_000, "took #{div(elapsed_us, 1000)}ms, expected ~1s"
    end

    test "a command inside its deadline is left alone" do
      wrapped = Ssh.reap_on_disconnect("echo fine\n", deadline_seconds: 5)
      assert {output, 0} = System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true)
      assert String.trim(output) == "fine"
    end

    test "the watcher and the deadline do not orphan their own sleeps" do
      # `kill $__rx_watch $__rx_dead` reaches the two helper SUBSHELLS. Each has
      # a `sleep` as a child, and `set +m` has already run by then, so a group
      # kill is not available -- killing the subshell left the `sleep` running,
      # reparented to init, for the rest of its interval. On every invocation:
      # after a one-second hook with a sixty-second deadline, two survived.
      #
      # A distinctive deadline so this cannot see another test's `sleep`, and a
      # long one so a survivor would still be there when this looks.
      #
      # The command has to take long enough for the helpers to actually reach
      # their `sleep`. An instant command wins the race and leaves nothing
      # behind even unfixed, so it would prove nothing.
      deadline = 900 + :rand.uniform(89)
      wrapped = Ssh.reap_on_disconnect("echo hi; sleep 1\n", deadline_seconds: deadline)

      assert {output, 0} = System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true)
      assert String.trim(output) == "hi"

      # `pgrep -f` matches the full command line, so this finds the `sleep`
      # itself rather than the shell that spawned it.
      # `pgrep` exits 1 when it matches nothing, which is what "reaped" means.
      assert reaped?(fn ->
               match?(
                 {_, 1},
                 System.cmd("pgrep", ["-f", "sleep #{deadline}"], stderr_to_stdout: true)
               )
             end),
             "the deadline's sleep outlived the command it was bounding"
    end

    # The watcher is asserted STRUCTURALLY, not by watching the process table.
    #
    # Its poll interval is a fixed constant shared by every invocation, so a
    # process-table scan for `sleep 5` is global by construction: this file is
    # `async: true` and several of its tests spawn watchers, so a sibling's
    # transiently-reparented sleep counts as this test's leak. Polling for the
    # count to settle was not enough -- it still flaked about one full-suite run
    # in four.
    #
    # What is actually being claimed is that the watcher's sleep goes through
    # the same reaping shape the deadline's does. That shape is `reap_own_sleep/1`
    # plus `interruptible_sleep/2`, and the test above proves it works
    # end-to-end against a deadline whose interval IS unique. Asserting the
    # watcher carries it too closes the pair without a global scan.
    test "the watcher's poll sleep is reaped by the same mechanism" do
      wrapped = Ssh.reap_on_disconnect("true")

      # Backgrounded and waited on, rather than run inline: `wait` is what makes
      # the TERM arrive as an interrupt instead of being deferred until the
      # sleep finishes on its own.
      assert wrapped =~ "sleep #{@reap_poll_seconds} & __rx_ws=$!; wait $__rx_ws;"

      # And a trap that kills it, expanded at FIRE time -- `\$` keeps the pid
      # variable unexpanded at definition, when it is still unset.
      assert wrapped =~ ~s|trap "kill \\$__rx_ws 2>/dev/null; exit" TERM;|
    end

    # Polled rather than asserted once, because `kill` is asynchronous: between
    # a helper exiting and the signal landing on its `sleep`, that `sleep` is
    # briefly reparented to init and looks exactly like the leak. This file is
    # `async: true`, so a sibling test tearing down at the wrong moment produced
    # the same transient. A single sample flaked roughly one run in three.
    #
    # It does not weaken the assertion. A genuine leak lasts the deadline's
    # whole interval, which this picks in the hundreds of seconds, so a window
    # this short still separates the two cleanly.
    @reap_window_ms 1_500
    @reap_poll_ms 25

    defp reaped?(check), do: reaped?(check, System.monotonic_time(:millisecond) + @reap_window_ms)

    defp reaped?(check, deadline) do
      cond do
        check.() ->
          true

        System.monotonic_time(:millisecond) >= deadline ->
          false

        true ->
          Process.sleep(@reap_poll_ms)
          reaped?(check, deadline)
      end
    end

    test "job control does not narrate itself into the command's output" do
      # `set -m` is required for the group kill, and left on it makes bash write
      # `[1]  Done …` into the very output a hook's result is read from.
      wrapped = Ssh.reap_on_disconnect("echo hello\n", deadline_seconds: 5)
      {output, 0} = System.cmd("bash", ["-lc", wrapped], stderr_to_stdout: true)

      assert String.trim(output) == "hello"
      refute output =~ "Done"
      refute output =~ "[1]"
    end
  end

  describe "quote_path/1" do
    test "leaves a leading ~ bare so the remote shell still expands it" do
      # Single-quoting is exactly what suppresses tilde expansion, so
      # `mkdir -p '~/ws'` makes a directory literally NAMED `~`.
      assert Ssh.quote_path("~/symphony/MT-1") == "~/'symphony/MT-1'"
      assert Ssh.quote_path("~") == "~"
      assert Ssh.quote_path("~ci/ws") == "~ci/'ws'"
    end

    test "quotes an absolute path whole" do
      assert Ssh.quote_path("/var/lib/ws") == "'/var/lib/ws'"
    end

    test "a tilde prefix it does not understand is quoted whole, not expanded" do
      # Fails closed: an unrecognized prefix stays inert rather than reaching
      # the remote shell bare.
      assert Ssh.quote_path("~;touch /tmp/x") == "'~;touch /tmp/x'"
      assert Ssh.quote_path("~$(whoami)/ws") == "'~$(whoami)/ws'"
    end

    # Bash's tilde prefixes are not all home directories: `~-` is $OLDPWD, `~+`
    # is $PWD, and `~N`/`~-N` are directory-stack entries. HostSpec's path
    # pattern accepts every one of these as a workspace_root, so leaving them
    # bare pointed the root at whatever directory the login shell happened to
    # have been in -- a different place per connection, and outside the root
    # containment was measured against.
    test "a tilde prefix bash would expand to somewhere other than a home is inert" do
      for path <- ["~-/ws", "~+/ws", "~0/ws", "~-2/ws", "~1", "~-"] do
        assert Ssh.quote_path(path) == "'#{path}'",
               "#{path} was left bare for the remote shell to expand"
      end
    end

    test "an ordinary username prefix is still expanded" do
      assert Ssh.quote_path("~ci/ws") == "~ci/'ws'"
      assert Ssh.quote_path("~_build/ws") == "~_build/'ws'"
      assert Ssh.quote_path("~ci2/ws") == "~ci2/'ws'"
    end

    test "a tilde path with an embedded quote is still escaped" do
      assert Ssh.quote_path("~/it's/ws") == "~/'it'\\''s/ws'"
    end
  end

  describe "remote_bash/2" do
    test "wraps a login shell that cds into a quoted workspace then runs the command" do
      assert Ssh.remote_bash("/ws/app", "codex app-server") ==
               ~s(bash -lc 'cd '\\''/ws/app'\\'' && { codex app-server\n}')
    end

    # `&&` binds to the next COMMAND, not to the rest of the line, so an
    # ungrouped `cd WS && A; B` runs `B` whatever `cd` did. Every real caller
    # passes `reap_on_disconnect/2` output, which begins `set -m;` -- so without
    # the group a failed `cd` skipped only the `set -m` and ran the workload in
    # the login shell's home, reporting exit 0 because `wait` returned the
    # backgrounded group's status.
    test "a failed cd runs nothing, even when the command has its own separators" do
      sandbox = Path.join(System.tmp_dir!(), "sym_cd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(sandbox)
      on_exit(fn -> File.rm_rf(sandbox) end)

      command = Ssh.reap_on_disconnect("touch ./ESCAPED", deadline_seconds: 30)
      remote = Ssh.remote_bash(Path.join(sandbox, "missing"), command)

      {_out, status} = System.cmd("bash", ["-lc", remote], stderr_to_stdout: true, cd: sandbox)

      refute status == 0, "a failed cd reported success"
      refute File.exists?(Path.join(sandbox, "ESCAPED")), "the command ran outside its workspace"
    end

    test "quoting survives two shell parses (ssh remote shell then bash -lc)" do
      # A workspace path with a space AND a single quote is the hard case.
      dir = Path.join(System.tmp_dir!(), "sym ssh 'q' #{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      # `bash -c <remote_bash>` simulates ssh handing the command to the
      # remote login shell, which then runs the inner `bash -lc 'cd … && …'`.
      {out, 0} = System.cmd("bash", ["-c", Ssh.remote_bash(dir, "pwd")])
      assert String.trim(out) == dir
    end
  end

  describe "command_args/2" do
    test "is [options, target, remote_command] with the command as one element" do
      remote = Ssh.remote_bash("/ws", "codex")
      args = Ssh.command_args(spec(user: "ci", port: 22), remote)

      assert List.last(args) == remote
      assert Enum.at(args, -2) == "ci@build-1"
      # the remote command is a single argv element (never split on spaces)
      assert Enum.count(args, &(&1 == remote)) == 1
    end
  end

  describe "executable/0" do
    test "resolves ssh or refuses when unavailable" do
      case Ssh.executable() do
        {:ok, path} -> assert Path.basename(path) == "ssh"
        {:error, :ssh_not_allowed} -> :ok
      end
    end
  end

  describe "exec/3" do
    test "runs ssh with the built argv through an injected executor" do
      test = self()

      exec_fn = fn ssh, args, opts ->
        send(test, {:ran, ssh, args, opts})
        {"remote output\n", 0}
      end

      assert {"remote output\n", 0} =
               Ssh.exec(spec(user: "ci"), "uptime",
                 exec_fn: exec_fn,
                 executable: "/usr/bin/ssh"
               )

      assert_received {:ran, "/usr/bin/ssh", args, stderr_to_stdout: true}
      assert List.last(args) == "uptime"
      assert "ci@build-1" in args
    end

    test "returns {:error, :ssh_not_allowed} when the executable can't be resolved" do
      # A blank PATH makes the default resolver fail; the injected exec_fn
      # must never be reached.
      System.put_env("SYM_SSH_TEST_OLD_PATH", System.get_env("PATH") || "")
      System.put_env("PATH", "")

      assert Ssh.exec(spec(), "noop", exec_fn: fn _, _, _ -> flunk("should not run") end) ==
               {:error, :ssh_not_allowed}
    after
      System.put_env("PATH", System.get_env("SYM_SSH_TEST_OLD_PATH") || "")
      System.delete_env("SYM_SSH_TEST_OLD_PATH")
    end
  end
end
