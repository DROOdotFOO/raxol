defmodule Raxol.Symphony.CLITest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.CLI

  @workflow """
  ---
  tracker:
    kind: memory
    active_states: ["Todo"]
    terminal_states: ["Done"]
  agent:
    max_concurrent_agents: 1
  ---
  Hello.
  """

  @workflow_invalid """
  ---
  tracker:
    kind: linear
  ---
  Missing api_key + project_slug -> validation rejects.
  """

  setup do
    # CLI starts a Supervisor.start_link, which links to the test process.
    # Trap exits so a graceful supervisor shutdown does not kill the test.
    Process.flag(:trap_exit, true)

    dir =
      Path.join(System.tmp_dir!(), "symphony_cli_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
      stop_supervisor()
    end)

    %{dir: dir}
  end

  defp stop_supervisor do
    case Process.whereis(Raxol.Symphony.Supervisor) do
      nil ->
        :ok

      pid ->
        # Graceful: ask the supervisor to terminate; ignore the resulting
        # :EXIT in our trap_exit'd test process.
        try do
          :ok = Supervisor.stop(pid, :shutdown, 1_000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  defp write_workflow(dir, contents) do
    path = Path.join(dir, "WORKFLOW.md")
    File.write!(path, contents)
    path
  end

  describe "start/1" do
    test "boots the supervisor and skips the surface in headless mode", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      assert {:ok, %{supervisor: sup, surface: nil}} =
               CLI.start(workflow: path, headless: true, watch: false, auto_start_tick: false)

      assert Process.alive?(sup)
      stop_supervisor()
    end

    test "returns :workflow_not_found when path is missing" do
      assert {:error, {:workflow_not_found, full}} =
               CLI.start(workflow: "/nonexistent/path/WORKFLOW.md", headless: true)

      assert is_binary(full)
    end

    test "returns the validation error when the workflow is invalid", %{dir: dir} do
      path = write_workflow(dir, @workflow_invalid)

      assert {:error, :missing_tracker_api_key} =
               CLI.start(workflow: path, headless: true, watch: false, auto_start_tick: false)
    end

    test "supplies a fake surface module when one is given", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      defmodule FakeSurface do
        def boot, do: spawn(fn -> Process.sleep(:infinity) end)
      end

      # The surface_module path uses Raxol.start_link internally; if Raxol
      # isn't available at runtime, the launcher returns nil for surface.
      assert {:ok, %{supervisor: sup, surface: surface}} =
               CLI.start(
                 workflow: path,
                 headless: false,
                 watch: false,
                 auto_start_tick: false,
                 surface_module: FakeSurface
               )

      assert Process.alive?(sup)
      assert is_nil(surface) or is_pid(surface)
      stop_supervisor()
    end
  end

  describe "run/1" do
    test "returns :workflow_not_found error without blocking" do
      assert {:error, {:workflow_not_found, _}} =
               CLI.run(workflow: "/nope/WORKFLOW.md", headless: true)
    end
  end
end
