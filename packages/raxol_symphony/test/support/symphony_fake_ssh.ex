defmodule Raxol.Symphony.Test.FakeSsh do
  @moduledoc """
  A stand-in for the far end of an SSH connection (issue #744).

  This is a fake at an external boundary, not a mock of our own code: it runs
  the EXACT remote command string `Raxol.Symphony.Ssh` built, through a local
  `bash -lc`. The "remote host" is a local directory. So a quoting defect, a
  missing `cd`, or a malformed `mkdir -p` fails here the same way it would fail
  against a real sshd, and the resulting directories are real enough to assert
  on with `File.dir?/1`.

  What it does not reproduce is the network: auth, host-key policy, and
  connection loss are the transport's own concern (issue #743).
  """

  @doc """
  An `:exec_fn` for `Raxol.Symphony.Ssh.exec/3`.

  Pass `report_to:` to receive `{:fake_ssh, argv}` for each invocation, so a
  test can assert on the argv the transport constructed.
  """
  @spec exec_fn(keyword()) :: (binary(), [binary()], keyword() -> {binary(), non_neg_integer()})
  def exec_fn(opts \\ []) do
    report_to = Keyword.get(opts, :report_to)

    fn _ssh, argv, cmd_opts ->
      if is_pid(report_to), do: send(report_to, {:fake_ssh, argv})

      # The transport puts the remote command last, as a single element, so
      # sshd hands it to the login shell verbatim. Running it through a local
      # `bash -lc` is what a remote shell would do with it.
      System.cmd("bash", ["-lc", List.last(argv)], cmd_opts)
    end
  end

  @doc """
  The `:ssh` option list to hand `Raxol.Symphony.Orchestrator` or
  `Raxol.Symphony.Workspace`.

  `:executable` is stubbed too, so a machine without `ssh` on PATH still runs
  these tests.
  """
  @spec opts(keyword()) :: keyword()
  def opts(overrides \\ []) do
    [exec_fn: exec_fn(overrides), executable: "/usr/bin/ssh"]
  end
end
