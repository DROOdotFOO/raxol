defmodule Raxol.Symphony.WorkspaceRemoteTest do
  @moduledoc """
  Host-aware workspace lifecycle (issue #744): the third and last slice of
  #518.

  #743 shipped the SSH transport, which `cd`s into the path it is handed. Until
  this slice that path was the ORCHESTRATOR's, so a remote worker either landed
  in a directory that does not exist on the host, or, worse, in one that does
  and belongs to something else.

  These tests drive the real command strings through
  `Raxol.Symphony.Test.FakeSsh`, which executes them in a local shell against a
  sandbox directory standing in for the host. No SSH server, no Mox.
  """
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Workspace}
  alias Raxol.Symphony.Test.FakeSsh
  alias Raxol.Symphony.Worker.HostSpec

  setup do
    # Two distinct roots throughout: the orchestrator's own, and the host's.
    # Every assertion below turns on which one a path lands under, so they must
    # never be the same directory.
    local_root = tmp("local")
    host_root = tmp("host")
    File.mkdir_p!(local_root)
    File.mkdir_p!(host_root)

    on_exit(fn ->
      File.rm_rf(local_root)
      File.rm_rf(host_root)
    end)

    %{local_root: local_root, host_root: host_root}
  end

  defp tmp(label) do
    Path.join(System.tmp_dir!(), "sym744_#{label}_#{:erlang.unique_integer([:positive])}")
  end

  defp build_config(local_root, hooks \\ %{}) do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory"},
        workspace: %{root: local_root},
        hooks: Map.merge(%{timeout_ms: 5_000}, hooks)
      },
      prompt_template: ""
    })
  end

  defp host(root), do: %HostSpec{host: "build-1", user: "ci", workspace_root: root}

  describe "ensure/3 on a host" do
    test "creates the workspace under the HOST's root, not the orchestrator's", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root)

      assert {:ok, %{path: path, key: "MT-1", created_now: true}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())

      assert path == Path.join(host_root, "MT-1")
      assert File.dir?(path)

      # The regression this slice exists to prevent: nothing is created on the
      # orchestrator for a remote worker.
      refute File.exists?(Path.join(local_root, "MT-1"))
    end

    test "reports created_now=false when the host already has it", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root)
      opts = [host: host(host_root), ssh: FakeSsh.opts()]

      assert {:ok, %{created_now: true}} = Workspace.ensure(config, "MT-1", opts)
      assert {:ok, %{created_now: false}} = Workspace.ensure(config, "MT-1", opts)
    end

    test "falls back to the configured root when the spec declares none", %{
      local_root: local_root
    } do
      config = build_config(local_root)
      spec = %HostSpec{host: "build-1", workspace_root: nil}

      assert {:ok, %{path: path}} =
               Workspace.ensure(config, "MT-1", host: spec, ssh: FakeSsh.opts())

      assert path == Path.join(local_root, "MT-1")
    end

    test "goes through the ssh transport rather than touching the local disk", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root)

      assert {:ok, _} =
               Workspace.ensure(config, "MT-1",
                 host: host(host_root),
                 ssh: FakeSsh.opts(report_to: self())
               )

      assert_receive {:fake_ssh, argv}
      assert "ci@build-1" in argv
      assert List.last(argv) =~ "mkdir -p"
    end

    test "an identifier that would escape the root is refused", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root)

      # `sanitize_key/1` keeps `.`, so `".."` survives as a whole segment and
      # the containment check is the only thing standing between it and the
      # host root's parent.
      assert {:error, :workspace_outside_root} =
               Workspace.ensure(config, "..", host: host(host_root), ssh: FakeSsh.opts())
    end

    test "a `~` root lands under the HOST's home, not in a directory named `~`", %{
      local_root: local_root
    } do
      # Single-quoting a path is what suppresses tilde expansion, so quoting
      # this one whole made `mkdir -p '~/symphony/MT-1'` create a directory
      # literally NAMED `~` wherever the login shell started. HostSpec accepts
      # `~` roots, so this is reachable from ordinary config.
      host_home = tmp("home")
      File.mkdir_p!(host_home)
      on_exit(fn -> File.rm_rf(host_home) end)

      config = build_config(local_root)
      spec = %HostSpec{host: "build-1", workspace_root: "~/symphony"}

      assert {:ok, %{path: "~/symphony/MT-1"}} =
               Workspace.ensure(config, "MT-1", host: spec, ssh: FakeSsh.opts(home: host_home))

      assert File.dir?(Path.join(host_home, "symphony/MT-1"))
      refute File.exists?(Path.join(host_home, "~"))
    end

    test "a relative remote root is refused rather than resolved locally", %{
      local_root: local_root
    } do
      config = build_config(local_root)
      spec = %HostSpec{host: "build-1", workspace_root: "relative/path"}

      assert {:error, :invalid_workspace_root} =
               Workspace.ensure(config, "MT-1", host: spec, ssh: FakeSsh.opts())
    end
  end

  describe "hooks on a host" do
    test "after_create runs in the remote workspace", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root, %{after_create: "touch created_here"})

      assert {:ok, %{path: path}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())

      # Relative to the hook's cwd, so its location proves where it ran.
      assert File.exists?(Path.join(path, "created_here"))
    end

    test "the hook's cwd IS the remote workspace (SPEC s9.5 Invariant 1)", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root, %{after_create: "pwd > where_i_ran"})

      assert {:ok, %{path: path}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())

      assert path |> Path.join("where_i_ran") |> File.read!() |> String.trim() == path
    end

    test "a failing after_create is fatal and unwinds the directory ON THE HOST", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root, %{after_create: "exit 3"})

      assert {:error, {:after_create_hook_failed, {:exit, 3}}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())

      refute File.exists?(Path.join(host_root, "MT-1"))
    end

    test "a hook that outlives hooks.timeout_ms is reported as a timeout", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root, %{after_create: "sleep 5", timeout_ms: 200})

      assert {:error, {:after_create_hook_failed, :timeout}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())
    end

    test "a timed-out hook is STOPPED on the host, not merely abandoned", %{
      local_root: local_root,
      host_root: host_root
    } do
      # Giving up locally does not stop remote work: killing the BEAM process
      # closes the port, and closing a port does not signal the OS process it
      # spawned. Relying on that alone left a timed-out `before_remove` hook
      # still running while the workspace was deleted underneath it.
      witness = Path.join(host_root, "hook_outlived_its_deadline")

      config =
        build_config(local_root, %{after_create: "sleep 4\ntouch #{witness}\n", timeout_ms: 1_000})

      assert {:error, {:after_create_hook_failed, :timeout}} =
               Workspace.ensure(config, "MT-1", host: host(host_root), ssh: FakeSsh.opts())

      # Well past when the hook would have finished had nothing stopped it.
      Process.sleep(5_000)
      refute File.exists?(witness), "the hook kept running on the host after its deadline"
    end

    test "before_run runs against the remote workspace", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root, %{before_run: "touch ran_before"})
      opts = [host: host(host_root), ssh: FakeSsh.opts()]

      assert {:ok, %{path: path}} = Workspace.ensure(config, "MT-1", opts)
      assert :ok = Workspace.run_before_run_hook(config, path, opts)
      assert File.exists?(Path.join(path, "ran_before"))
    end
  end

  describe "remove/3 on a host" do
    test "deletes the workspace on the host", %{local_root: local_root, host_root: host_root} do
      config = build_config(local_root)
      opts = [host: host(host_root), ssh: FakeSsh.opts()]

      assert {:ok, %{path: path}} = Workspace.ensure(config, "MT-1", opts)
      assert File.dir?(path)

      assert :ok = Workspace.remove(config, path, opts)
      refute File.exists?(path)
    end

    test "runs before_remove on the host first", %{
      local_root: local_root,
      host_root: host_root
    } do
      witness = Path.join(host_root, "before_remove_ran")
      config = build_config(local_root, %{before_remove: "touch #{witness}"})
      opts = [host: host(host_root), ssh: FakeSsh.opts()]

      assert {:ok, %{path: path}} = Workspace.ensure(config, "MT-1", opts)
      assert :ok = Workspace.remove(config, path, opts)

      assert File.exists?(witness)
      refute File.exists?(path)
    end

    test "refuses a path outside the host's root", %{
      local_root: local_root,
      host_root: host_root
    } do
      config = build_config(local_root)
      outside = tmp("outside")
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      assert :ok = Workspace.remove(config, outside, host: host(host_root), ssh: FakeSsh.opts())

      # Containment is measured against the HOST's root, so an unrelated
      # directory survives instead of being deleted over SSH.
      assert File.dir?(outside)
    end
  end

  describe "local dispatch is untouched" do
    test "host: nil still creates and removes on the orchestrator", %{local_root: local_root} do
      config = build_config(local_root)

      assert {:ok, %{path: path, created_now: true}} = Workspace.ensure(config, "MT-1", host: nil)
      assert path == Path.join(local_root, "MT-1")
      assert File.dir?(path)

      assert :ok = Workspace.remove(config, path, host: nil)
      refute File.exists?(path)
    end

    test "the arity-2 form behaves exactly as before", %{local_root: local_root} do
      config = build_config(local_root)

      assert {:ok, %{path: path, key: "MT-1", created_now: true}} =
               Workspace.ensure(config, "MT-1")

      assert path == Path.join(local_root, "MT-1")
      assert {:ok, %{created_now: false}} = Workspace.ensure(config, "MT-1")
    end
  end
end
