defmodule Raxol.Symphony.SshTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Ssh
  alias Raxol.Symphony.Worker.HostSpec

  defp spec(fields \\ []), do: struct(%HostSpec{host: "build-1"}, fields)

  describe "target/1" do
    test "is host alone or user@host" do
      assert Ssh.target(spec()) == "build-1"
      assert Ssh.target(spec(user: "ci")) == "ci@build-1"
    end
  end

  describe "option_args/1" do
    test "always includes non-interactive base options" do
      args = Ssh.option_args(spec())
      assert "BatchMode=yes" in args
      assert "StrictHostKeyChecking=accept-new" in args
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

  describe "remote_bash/2" do
    test "wraps a login shell that cds into a quoted workspace then runs the command" do
      assert Ssh.remote_bash("/ws/app", "codex app-server") ==
               ~s(bash -lc 'cd '\\''/ws/app'\\'' && codex app-server')
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
