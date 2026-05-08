defmodule Raxol.Symphony.WorkflowStoreTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, WorkflowStore}

  @workflow """
  ---
  tracker:
    kind: memory
  agent:
    max_concurrent_agents: 4
  ---
  Hello from Symphony.
  """

  @workflow_v2 """
  ---
  tracker:
    kind: memory
  agent:
    max_concurrent_agents: 8
  ---
  Hello from Symphony, version two.
  """

  @workflow_invalid """
  ---
  tracker:
    kind: linear
  ---
  No api key, no project slug -- schema validation must reject.
  """

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "symphony_workflow_store_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_workflow(dir, name \\ "WORKFLOW.md", contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  # -- Initial load -----------------------------------------------------------

  describe "initial load" do
    test "loads + validates the workflow at start", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_init1"}
        )

      assert %Config{} = config = WorkflowStore.get(pid)
      assert config.tracker.kind == "memory"
      assert config.agent.max_concurrent_agents == 4
      assert WorkflowStore.last_error(pid) == nil
    end

    test "records last_error when initial load fails", %{dir: dir} do
      path = write_workflow(dir, @workflow_invalid)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_init2"}
        )

      assert WorkflowStore.get(pid) == nil
      assert WorkflowStore.last_error(pid) != nil
    end

    test "starts in static mode when :config is given without :path" do
      cfg =
        Config.from_workflow(%{
          config: %{tracker: %{kind: "memory"}},
          prompt_template: ""
        })

      pid =
        start_supervised!({WorkflowStore, config: cfg, name: :"#{__MODULE__}_init3"})

      assert WorkflowStore.get(pid) == cfg
      refute WorkflowStore.watching?(pid)
    end

    test "without :path or :config records :no_path_or_config error" do
      pid = start_supervised!({WorkflowStore, name: :"#{__MODULE__}_init4"})

      assert WorkflowStore.get(pid) == nil
      assert WorkflowStore.last_error(pid) == :no_path_or_config
    end
  end

  # -- Manual reload ----------------------------------------------------------

  describe "reload/1" do
    test "picks up edits to the workflow file", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_reload1"}
        )

      assert WorkflowStore.get(pid).agent.max_concurrent_agents == 4

      File.write!(path, @workflow_v2)
      assert {:ok, %Config{} = new_cfg} = WorkflowStore.reload(pid)
      assert new_cfg.agent.max_concurrent_agents == 8
      assert WorkflowStore.get(pid).agent.max_concurrent_agents == 8
    end

    test "keeps last-known-good when reload validates fail", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_reload2"}
        )

      good_cfg = WorkflowStore.get(pid)
      assert good_cfg.tracker.kind == "memory"

      File.write!(path, @workflow_invalid)
      assert {:error, _reason} = WorkflowStore.reload(pid)

      # Cached config is unchanged
      assert WorkflowStore.get(pid) == good_cfg
      assert WorkflowStore.last_error(pid) != nil
    end

    test "keeps last-known-good when the file disappears", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_reload3"}
        )

      good_cfg = WorkflowStore.get(pid)
      File.rm!(path)

      assert {:error, :missing_workflow_file} = WorkflowStore.reload(pid)
      assert WorkflowStore.get(pid) == good_cfg
    end
  end

  # -- Subscribe + notify -----------------------------------------------------

  describe "subscribe/1" do
    test "notifies subscribers on successful debounced reload", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, debounce_ms: 5, name: :"#{__MODULE__}_sub1"}
        )

      :ok = WorkflowStore.subscribe(pid)
      File.write!(path, @workflow_v2)

      # Simulate file_system event
      send(pid, {:file_event, self(), {Path.expand(path), [:modified]}})

      assert_receive {:workflow_store, :reloaded, %Config{} = config}, 500
      assert config.agent.max_concurrent_agents == 8
    end

    test "does not notify on failed reload", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, debounce_ms: 5, name: :"#{__MODULE__}_sub2"}
        )

      :ok = WorkflowStore.subscribe(pid)
      File.write!(path, @workflow_invalid)

      send(pid, {:file_event, self(), {Path.expand(path), [:modified]}})

      refute_receive {:workflow_store, :reloaded, _}, 100
      assert WorkflowStore.last_error(pid) != nil
    end
  end

  # -- Coalescing -------------------------------------------------------------

  describe "debounce coalescing" do
    test "many rapid file events produce a single reload", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore,
           path: path, watch?: false, debounce_ms: 30, name: :"#{__MODULE__}_coalesce"}
        )

      :ok = WorkflowStore.subscribe(pid)
      File.write!(path, @workflow_v2)

      # Burst of events as if an editor wrote, renamed, then touched mtime.
      for _ <- 1..10 do
        send(pid, {:file_event, self(), {Path.expand(path), [:modified]}})
      end

      assert_receive {:workflow_store, :reloaded, %Config{}}, 500

      # Only ONE notification should land within the next debounce window.
      refute_receive {:workflow_store, :reloaded, _}, 100
    end

    test "ignores events for unrelated paths", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore,
           path: path, watch?: false, debounce_ms: 5, name: :"#{__MODULE__}_unrelated"}
        )

      :ok = WorkflowStore.subscribe(pid)

      # An event for a different file in the watched dir
      other = Path.join(dir, "OTHER.md")
      send(pid, {:file_event, self(), {other, [:modified]}})

      refute_receive {:workflow_store, :reloaded, _}, 100
    end
  end

  # -- Watcher lifecycle ------------------------------------------------------

  describe "watcher" do
    test "starts a FileSystem watcher when watch?: true and dep is present", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: true, name: :"#{__MODULE__}_watcher_on"}
        )

      assert WorkflowStore.watching?(pid)
    end

    test "watch?: false keeps the watcher off even when dep is present", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: false, name: :"#{__MODULE__}_watcher_off"}
        )

      refute WorkflowStore.watching?(pid)
    end

    test "marks watcher_enabled=false when the watcher process stops", %{dir: dir} do
      path = write_workflow(dir, @workflow)

      pid =
        start_supervised!(
          {WorkflowStore, path: path, watch?: true, name: :"#{__MODULE__}_watcher_stop"}
        )

      assert WorkflowStore.watching?(pid)

      send(pid, {:file_event, self(), :stop})

      # Give the message time to be processed
      _ = :sys.get_state(pid)
      refute WorkflowStore.watching?(pid)
    end
  end
end
