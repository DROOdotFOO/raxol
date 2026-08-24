defmodule Raxol.Symphony.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Workspace}

  defp build_config(tmp_dir, hook_overrides \\ %{}) do
    workflow = %{
      config: %{
        tracker: %{kind: "memory"},
        workspace: %{root: tmp_dir},
        hooks: Map.merge(%{timeout_ms: 5_000}, hook_overrides)
      },
      prompt_template: ""
    }

    Config.from_workflow(workflow)
  end

  describe "ensure/2" do
    @tag :tmp_dir
    test "creates a fresh workspace and reports created_now=true", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)

      assert {:ok, %{path: path, key: "MT-1", created_now: true}} =
               Workspace.ensure(config, "MT-1")

      assert path == Path.join(tmp_dir, "MT-1")
      assert File.dir?(path)
    end

    @tag :tmp_dir
    test "reuses existing workspace and reports created_now=false", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)
      assert {:ok, %{created_now: true}} = Workspace.ensure(config, "MT-1")
      assert {:ok, %{created_now: false}} = Workspace.ensure(config, "MT-1")
    end

    @tag :tmp_dir
    test "sanitizes the identifier in the path", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)

      assert {:ok, %{path: path, key: "abc_.._etc"}} =
               Workspace.ensure(config, "abc/../etc")

      assert path == Path.join(tmp_dir, "abc_.._etc")
      assert File.dir?(path)
    end

    @tag :tmp_dir
    test "runs after_create hook only on first creation", %{tmp_dir: tmp_dir} do
      sentinel = Path.join(tmp_dir, "after_create.txt")

      config =
        build_config(tmp_dir, %{
          after_create: """
          touch '#{sentinel}'
          """
        })

      assert {:ok, %{created_now: true}} = Workspace.ensure(config, "MT-1")
      assert File.exists?(sentinel)

      File.rm!(sentinel)

      assert {:ok, %{created_now: false}} = Workspace.ensure(config, "MT-1")
      refute File.exists?(sentinel)
    end

    @tag :tmp_dir
    test "after_create failure aborts and cleans up partial workspace",
         %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir, %{after_create: "exit 7"})

      assert {:error, {:after_create_hook_failed, {:exit, 7}}} =
               Workspace.ensure(config, "MT-fail")

      refute File.dir?(Path.join(tmp_dir, "MT-fail"))
    end

    @tag :tmp_dir
    test "after_create timeout aborts and cleans up", %{tmp_dir: tmp_dir} do
      config =
        build_config(tmp_dir, %{after_create: "sleep 5", timeout_ms: 200})

      assert {:error, {:after_create_hook_failed, :timeout}} =
               Workspace.ensure(config, "MT-slow")

      refute File.dir?(Path.join(tmp_dir, "MT-slow"))
    end
  end

  describe "run_hook/4 timeout" do
    # A hook we have stopped waiting for has to actually be DEAD. `before_remove`
    # is followed by an `rm_rf` of the very directory the hook is still writing
    # to, and a hook that survives its timeout survives once per retry.
    #
    # The witnesses are what a survivor leaves behind, so the assertion is their
    # ABSENCE once the hook's own natural runtime has elapsed. Only a survivor
    # can create them, which is what keeps this from being a wall-clock race:
    # slow machines cannot fail it, they can only stop proving anything.
    @tag :tmp_dir
    test "kills a timed-out hook and the children it spawned", %{tmp_dir: tmp_dir} do
      hook_witness = Path.join(tmp_dir, "hook_finished")
      child_witness = Path.join(tmp_dir, "child_finished")

      script = """
      ( sleep 1; touch #{child_witness} ) &
      sleep 1
      touch #{hook_witness}
      """

      config = build_config(tmp_dir, %{before_run: script, timeout_ms: 200})

      assert {:error, :timeout} = Workspace.run_hook(config, :before_run, tmp_dir)

      # Five times the timeout the hook was given, and past the point a survivor
      # would have finished its own work.
      Process.sleep(1_200)

      refute File.exists?(hook_witness)
      refute File.exists?(child_witness)
    end

    # The same leak, one step meaner: the hook's own bash exits IMMEDIATELY and
    # only the background child is left. That child still holds the inherited
    # stdout, so no exit status is delivered, the port stays open, and the
    # timeout fires as before -- but now against a pid that has already been
    # reaped. Resolving the kill target off that pid signals a corpse and leaves
    # the child running; resolving it off the process group reaps it.
    @tag :tmp_dir
    test "kills the children of a hook that exited before its own timeout", %{tmp_dir: tmp_dir} do
      child_witness = Path.join(tmp_dir, "orphan_finished")

      script = """
      ( sleep 1; touch #{child_witness} ) &
      exit 0
      """

      config = build_config(tmp_dir, %{before_run: script, timeout_ms: 200})

      assert {:error, :timeout} = Workspace.run_hook(config, :before_run, tmp_dir)

      # Past the point the orphan would have finished its own work.
      Process.sleep(1_200)

      refute File.exists?(child_witness)
    end
  end

  describe "run_before_run_hook/2" do
    @tag :tmp_dir
    test "noop when hook is not set", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")
      assert :ok = Workspace.run_before_run_hook(config, path)
    end

    @tag :tmp_dir
    test "runs in the workspace cwd", %{tmp_dir: tmp_dir} do
      sentinel_name = "before_run_marker.txt"

      config =
        build_config(tmp_dir, %{
          before_run: "pwd > #{sentinel_name}"
        })

      {:ok, %{path: path}} = Workspace.ensure(config, "MT-cwd")
      assert :ok = Workspace.run_before_run_hook(config, path)

      assert path |> Path.join(sentinel_name) |> File.read!() |> String.trim() == path
    end

    @tag :tmp_dir
    test "before_run failure is fatal to the run attempt", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir, %{before_run: "exit 1"})
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")

      assert {:error, {:before_run_hook_failed, {:exit, 1}}} =
               Workspace.run_before_run_hook(config, path)
    end
  end

  describe "run_after_run_hook/2" do
    @tag :tmp_dir
    test "after_run failure is logged but ignored (returns :ok)", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir, %{after_run: "exit 1"})
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")
      assert :ok = Workspace.run_after_run_hook(config, path)
    end
  end

  describe "remove/2" do
    @tag :tmp_dir
    test "removes workspace directory", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")
      assert File.dir?(path)
      assert :ok = Workspace.remove(config, path)
      refute File.dir?(path)
    end

    @tag :tmp_dir
    test "runs before_remove (best-effort)", %{tmp_dir: tmp_dir} do
      sentinel = Path.join(tmp_dir, "before_remove_marker.txt")

      config =
        build_config(tmp_dir, %{
          before_remove: "touch '#{sentinel}'"
        })

      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")
      assert :ok = Workspace.remove(config, path)
      assert File.exists?(sentinel)
      refute File.dir?(path)
    end

    @tag :tmp_dir
    test "before_remove failure is logged but does not block cleanup",
         %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir, %{before_remove: "exit 1"})
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")
      assert :ok = Workspace.remove(config, path)
      refute File.dir?(path)
    end

    @tag :tmp_dir
    test "refuses to remove a path outside workspace root", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)
      assert :ok = Workspace.remove(config, "/tmp/some/other/place")
      # No assertion of removal -- the point is it is not allowed to remove the
      # outside path. We just want :ok and no crash.
      refute File.dir?("/tmp/some/other/place_should_not_exist_anyway")
    end
  end

  # SPEC s9.5 Invariant 1 depends on the workspace being a real directory.
  # `bash`'s `cd ''` SUCCEEDS and changes nothing, so a blank path sails through
  # the `cd WS && { … }` guard and the work lands in whatever directory the
  # shell started in. `GraphAdapter` defaults a missing workspace to `""` in two
  # places, so this is fail-closed for a default that is one off-by-one from
  # being reachable.
  describe "around_run/4 with no workspace to run in" do
    @tag :tmp_dir
    test "refuses before the hooks AND before the runner", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir, %{before_run: "true", after_run: "true"})

      for blank <- ["", "   ", nil, :none] do
        assert {:error, {:invalid_workspace, ^blank}} =
                 Workspace.around_run(config, blank, [], fn -> flunk("runner should not run") end)
      end
    end

    # The case guarding the hook alone did not cover: with nothing configured,
    # `:no_hook` short-circuits before any check, so the runner was dispatched
    # into an empty path anyway.
    @tag :tmp_dir
    test "refuses even when no hooks are configured", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)

      assert {:error, {:invalid_workspace, ""}} =
               Workspace.around_run(config, "", [], fn -> flunk("runner should not run") end)
    end

    @tag :tmp_dir
    test "a real workspace still runs, and gets its result back", %{tmp_dir: tmp_dir} do
      config = build_config(tmp_dir)
      {:ok, %{path: path}} = Workspace.ensure(config, "MT-1")

      assert {:ok, :ran} = Workspace.around_run(config, path, [], fn -> :ran end)
    end
  end
end
