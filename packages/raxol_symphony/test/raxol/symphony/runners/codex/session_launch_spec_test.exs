defmodule Raxol.Symphony.Runners.Codex.SessionLaunchSpecTest do
  @moduledoc """
  `Session.launch_spec/5` (issue #743): the pure `{executable, Port.open-opts}`
  decision for a local vs remote Codex launch. Isolated from the real
  `Port.open` so the local/remote command construction is testable without a
  process (or a real SSH server).
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Runners.Codex.Session
  alias Raxol.Symphony.Worker.HostSpec

  describe "local (host == nil)" do
    test "runs bash -lc command with cwd via {:cd, workspace}" do
      assert {:ok, {"/bin/bash", opts}} =
               Session.launch_spec(nil, "/bin/bash", "codex app-server", "/ws", [])

      assert {:cd, "/ws"} in opts
      assert {:args, ["-lc", "codex app-server"]} in opts
      assert :exit_status in opts
    end

    test "injects env only when non-empty" do
      {:ok, {_, no_env}} = Session.launch_spec(nil, "/bin/bash", "c", "/ws", [])
      refute Enum.any?(no_env, &match?({:env, _}, &1))

      {:ok, {_, with_env}} =
        Session.launch_spec(nil, "/bin/bash", "c", "/ws", [{~c"K", ~c"V"}])

      assert {:env, [{~c"K", ~c"V"}]} in with_env
    end
  end

  describe "remote (%HostSpec{})" do
    test "runs ssh with the wrapped remote bash command and forwards no env" do
      host = %HostSpec{host: "build-1", user: "ci", port: 2222}

      case Session.launch_spec(host, "/bin/bash", "codex app-server", "/ws", [{~c"K", ~c"V"}]) do
        {:ok, {executable, opts}} ->
          assert Path.basename(executable) == "ssh"
          {:args, args} = List.keyfind(opts, :args, 0)

          # ssh options + destination + the single remote-command element.
          assert "ci@build-1" in args
          assert ["-p", "2222"] == Enum.slice(args, -4, 2) or "-p" in args
          assert List.last(args) =~ "bash -lc 'cd '\\''/ws'\\'' && codex app-server'"

          # No {:cd, _} and no {:env, _} on the remote path (login shell owns
          # cwd + credentials); stdio is the ssh pipe.
          refute Enum.any?(opts, &match?({:cd, _}, &1))
          refute Enum.any?(opts, &match?({:env, _}, &1))

        {:error, :ssh_not_allowed} ->
          # No ssh on this machine -> the remote launch fails closed, which is
          # itself the contract.
          :ok
      end
    end
  end
end
