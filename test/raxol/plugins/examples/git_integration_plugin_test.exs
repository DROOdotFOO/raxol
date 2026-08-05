defmodule Raxol.Plugins.Examples.GitIntegrationPluginTest do
  use Raxol.Plugins.Testing.PluginTestFramework, async: false

  alias Raxol.Plugins.Examples.GitIntegrationPlugin

  # Helper to safely stop a GenServer process
  defp safe_stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal, 5000)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp safe_stop(_), do: :ok

  # Note: create_temp_directory, cleanup_temp_directory, with_temp_directory,
  # and capture_plugin_logs are provided by PluginTestFramework

  describe "plugin manifest" do
    test "has valid manifest structure" do
      assert {:ok, manifest} = validate_manifest(GitIntegrationPlugin)

      assert manifest.name == "git-integration"
      assert manifest.version == "1.0.0"
      assert is_binary(manifest.description)
      assert manifest.author == "Raxol Team"

      # Check capabilities
      expected_capabilities = [
        :shell_command,
        :file_watcher,
        :ui_panel,
        :keyboard_input,
        :status_line
      ]

      assert Enum.all?(expected_capabilities, &(&1 in manifest.capabilities))
    end

    test "has valid configuration schema" do
      manifest = GitIntegrationPlugin.manifest()

      # Check required config fields exist
      assert Map.has_key?(manifest.config_schema, :auto_refresh)
      assert Map.has_key?(manifest.config_schema, :refresh_interval)
      assert Map.has_key?(manifest.config_schema, :hotkey)

      # Check field types and defaults
      auto_refresh = manifest.config_schema.auto_refresh
      assert auto_refresh.type == :boolean
      assert auto_refresh.default == true

      refresh_interval = manifest.config_schema.refresh_interval
      assert refresh_interval.type == :integer
      assert refresh_interval.default == 2000
    end
  end

  describe "plugin initialization" do
    test "starts successfully with valid config" do
      config =
        create_git_test_config(%{
          name: GitIntegrationPlugin,
          auto_refresh: false,
          refresh_interval: 5000,
          show_untracked: true
        })

      assert {:ok, pid} = GitIntegrationPlugin.start_link(config)
      assert Process.alive?(pid)

      # Clean up
      safe_stop(pid)
    end

    test "initializes with default config when no git repo found" do
      # Test in directory without git repo
      with_temp_directory(fn temp_dir ->
        File.cd!(temp_dir, fn ->
          config = create_git_test_config(%{name: GitIntegrationPlugin})
          {:ok, pid} = GitIntegrationPlugin.start_link(config)

          status = GitIntegrationPlugin.get_status()
          assert status.repo_path == nil

          safe_stop(pid)
        end)
      end)
    end
  end

  describe "git repository detection" do
    test "finds git repository in current directory" do
      # Skip if no git repo in test environment
      case System.cmd("git", ["rev-parse", "--show-toplevel"]) do
        {_path, 0} ->
          config = create_git_test_config(%{name: GitIntegrationPlugin})
          {:ok, pid} = GitIntegrationPlugin.start_link(config)

          status = GitIntegrationPlugin.get_status()
          assert is_binary(status.repo_path)

          safe_stop(pid)

        _ ->
          # No git repo, skip test
          :ok
      end
    end

    test "initializes correctly in git repository" do
      with_temp_directory(fn temp_dir ->
        # Initialize git repo
        File.cd!(temp_dir, fn ->
          System.cmd("git", ["init"])
          System.cmd("git", ["config", "user.email", "test@example.com"])
          System.cmd("git", ["config", "user.name", "Test User"])
          # Ensure we have a default branch and initial commit
          File.write!("README.md", "# Test repo")
          System.cmd("git", ["add", "README.md"])
          System.cmd("git", ["commit", "-m", "Initial commit"])

          config = create_git_test_config(%{name: GitIntegrationPlugin})
          {:ok, pid} = GitIntegrationPlugin.start_link(config)

          # Wait for initialization
          Process.sleep(100)

          status = GitIntegrationPlugin.get_status()
          # Normalize paths to handle /private/tmp vs /tmp symlinks on macOS
          repo_path_resolved = Path.expand(status.repo_path)
          temp_dir_resolved = Path.expand(temp_dir)

          # Handle macOS /private/tmp symlink by normalizing both paths
          normalized_repo =
            String.replace(repo_path_resolved, "/private/tmp", "/tmp")

          normalized_temp =
            String.replace(temp_dir_resolved, "/private/tmp", "/tmp")

          assert normalized_repo == normalized_temp

          assert status.current_branch == "master" or
                   status.current_branch == "main"

          safe_stop(pid)
        end)
      end)
    end
  end

  describe "git operations" do
    setup do
      # Create temp directory that will persist for the test
      temp_dir = create_temp_directory()

      # Set up git repo with initial commit
      File.cd!(temp_dir, fn ->
        System.cmd("git", ["init"])
        System.cmd("git", ["config", "user.email", "test@example.com"])
        System.cmd("git", ["config", "user.name", "Test User"])

        # Create initial file and commit
        File.write!("README.md", "# Test Repository")
        System.cmd("git", ["add", "README.md"])
        System.cmd("git", ["commit", "-m", "Initial commit"])

        # Initialize plugin from within the git repository
        config = create_git_test_config(%{auto_refresh: false})

        {:ok, pid} =
          GitIntegrationPlugin.start_link(
            [
              name: Raxol.Plugins.Examples.GitIntegrationPlugin
            ] ++ config
          )

        on_exit(fn ->
          if Process.alive?(pid) do
            safe_stop(pid)
          end

          cleanup_temp_directory(temp_dir)
        end)

        {:ok, plugin: pid, repo_path: temp_dir}
      end)
    end

    test "stages files correctly", %{plugin: _plugin, repo_path: repo_path} do
      File.cd!(repo_path, fn ->
        # Create new file
        File.write!("new_file.txt", "Hello, World!")

        # Refresh to detect changes
        GitIntegrationPlugin.refresh()
        Process.sleep(100)

        # Stage the file
        assert :ok = GitIntegrationPlugin.stage_file("new_file.txt")

        # Verify file is staged
        status = GitIntegrationPlugin.get_status()
        assert status.staged_changes > 0
      end)
    end

    test "unstages files correctly", %{plugin: _plugin, repo_path: repo_path} do
      File.cd!(repo_path, fn ->
        # Modify an existing file and stage it
        File.write!("README.md", "# Modified Test Repository")
        System.cmd("git", ["add", "README.md"])

        GitIntegrationPlugin.refresh()
        Process.sleep(100)

        # Unstage the file
        assert :ok = GitIntegrationPlugin.unstage_file("README.md")

        # Verify file is unstaged (shows as modified but not staged)
        status = GitIntegrationPlugin.get_status()
        assert status.unstaged_changes > 0
      end)
    end

    test "creates commits with message", %{
      plugin: _plugin,
      repo_path: repo_path
    } do
      File.cd!(repo_path, fn ->
        # Stage a change
        File.write!("commit_test.txt", "Content to commit")
        System.cmd("git", ["add", "commit_test.txt"])

        # Make commit
        assert {:ok, output} =
                 GitIntegrationPlugin.commit("Test commit message")

        assert is_binary(output)

        # Verify commit was created
        {log_output, 0} = System.cmd("git", ["log", "--oneline", "-1"])
        assert String.contains?(log_output, "Test commit message")
      end)
    end

    test "creates new branches", %{plugin: _plugin, repo_path: repo_path} do
      File.cd!(repo_path, fn ->
        branch_name = "feature/test-branch"

        # Create new branch
        assert :ok = GitIntegrationPlugin.create_branch(branch_name)

        # Verify we're on new branch
        status = GitIntegrationPlugin.get_status()
        assert status.current_branch == branch_name
      end)
    end

    test "switches between branches", %{plugin: _plugin, repo_path: repo_path} do
      File.cd!(repo_path, fn ->
        # Get the default branch name (could be main or master)
        {default_branch, 0} = System.cmd("git", ["branch", "--show-current"])
        default_branch = String.trim(default_branch)

        # Create a new branch
        System.cmd("git", ["checkout", "-b", "test-branch"])

        # Switch back to default branch
        assert :ok = GitIntegrationPlugin.checkout_branch(default_branch)

        status = GitIntegrationPlugin.get_status()
        assert status.current_branch == default_branch
      end)
    end
  end

  describe "UI rendering" do
    test "renders status view correctly" do
      terminal = create_mock_terminal(width: 80, height: 24)

      config = create_git_test_config()
      {:ok, _plugin} = load_plugin(terminal, GitIntegrationPlugin, config)

      # Mock some git status data
      state = %GitIntegrationPlugin{
        config: config,
        repo_path: "/test/repo",
        current_branch: "main",
        staged_changes: [%{status: "A", path: "new_file.txt"}],
        unstaged_changes: [%{status: "M", path: "modified_file.txt"}],
        untracked_files: [%{status: "??", path: "untracked.txt"}]
      }

      # Test rendering
      rendered = GitIntegrationPlugin.render_panel(state, 40, 20)

      assert is_list(rendered)
      assert length(rendered) == 20

      # Check that rendered lines have proper structure
      Enum.each(rendered, fn line ->
        assert Map.has_key?(line, :text)
        assert Map.has_key?(line, :style)
        assert String.length(line.text) == 40
      end)
    end

    test "renders different view modes" do
      config = create_git_test_config()

      test_states = [
        %{view_mode: :status, branches: [], commit_history: []},
        %{
          view_mode: :branches,
          branches: [%{name: "main", current: true, remote: false}]
        },
        %{
          view_mode: :history,
          commit_history: [%{hash: "abc123", message: "Test commit"}]
        }
      ]

      Enum.each(test_states, fn state_overrides ->
        state =
          struct(
            GitIntegrationPlugin,
            Map.merge(%{config: config}, state_overrides)
          )

        rendered = GitIntegrationPlugin.render_panel(state, 50, 15)

        assert is_list(rendered)
        assert length(rendered) == 15
      end)
    end
  end

  describe "keyboard handling" do
    test "handles view mode switching" do
      config = create_git_test_config()
      state = %GitIntegrationPlugin{config: config, view_mode: :status}

      # Test switching to branches view
      new_state = GitIntegrationPlugin.handle_keypress("2", state)
      assert new_state.view_mode == :branches

      # Test switching to history view
      new_state = GitIntegrationPlugin.handle_keypress("3", new_state)
      assert new_state.view_mode == :history

      # Test switching back to status
      new_state = GitIntegrationPlugin.handle_keypress("1", new_state)
      assert new_state.view_mode == :status
    end

    test "handles refresh command" do
      config = create_git_test_config(%{name: GitIntegrationPlugin})
      {:ok, plugin} = GitIntegrationPlugin.start_link(config)

      state = %GitIntegrationPlugin{config: config}

      # Test refresh keypress (should return unchanged state but trigger refresh)
      new_state = GitIntegrationPlugin.handle_keypress("r", state)
      assert new_state == state

      safe_stop(plugin)
    end
  end

  describe "status line integration" do
    test "provides status line info for clean repo" do
      state = %GitIntegrationPlugin{
        repo_path: "/test/repo",
        current_branch: "main",
        staged_changes: [],
        unstaged_changes: [],
        untracked_files: []
      }

      status_info = GitIntegrationPlugin.status_line_info(state)
      assert status_info == " main [OK]"
    end

    test "provides status line info with changes" do
      state = %GitIntegrationPlugin{
        repo_path: "/test/repo",
        current_branch: "develop",
        # 2 staged
        staged_changes: [%{}, %{}],
        # 1 unstaged
        unstaged_changes: [%{}],
        # 3 untracked
        untracked_files: [%{}, %{}, %{}]
      }

      status_info = GitIntegrationPlugin.status_line_info(state)
      assert status_info == " develop +2 ~1 ?3"
    end

    test "handles no repository gracefully" do
      state = %GitIntegrationPlugin{repo_path: nil}
      status_info = GitIntegrationPlugin.status_line_info(state)
      assert status_info == ""
    end
  end

  # Removed: stub test "full workflow in mock terminal" (uses undefined helpers)

  describe "performance tests" do
    # Wall-clock bound (100ms for 100 renders); flakes on loaded CI runners.
    @tag :skip_on_ci
    test "render performance is acceptable" do
      config = create_git_test_config(%{name: GitIntegrationPlugin})
      {:ok, plugin} = GitIntegrationPlugin.start_link(config)

      # Create state with some data
      state = %GitIntegrationPlugin{
        config: config,
        repo_path: "/test/repo",
        current_branch: "main",
        branches:
          Enum.map(
            1..50,
            &%{name: "branch-#{&1}", current: false, remote: false}
          ),
        commit_history:
          Enum.map(1..100, &%{hash: "hash#{&1}", message: "Commit #{&1}"}),
        staged_changes: Enum.map(1..10, &%{status: "M", path: "file#{&1}.txt"}),
        unstaged_changes:
          Enum.map(1..20, &%{status: "M", path: "modified#{&1}.txt"}),
        untracked_files:
          Enum.map(1..5, &%{status: "??", path: "untracked#{&1}.txt"})
      }

      # Benchmark rendering
      {time, _result} =
        :timer.tc(fn ->
          Enum.each(1..100, fn _ ->
            GitIntegrationPlugin.render_panel(state, 80, 24)
          end)
        end)

      # Should render 100 times in under 100ms (less than 1ms per render)
      assert time < 100_000,
             "Rendering took #{time}μs for 100 iterations, should be < 100ms"

      safe_stop(plugin)
    end

    # Wall-clock bound (1s for 10 status calls); flakes on loaded CI runners.
    @tag :skip_on_ci
    test "git command execution performance" do
      # Test with actual git repo if available
      case System.cmd("git", ["rev-parse", "--show-toplevel"]) do
        {_path, 0} ->
          config =
            create_git_test_config(%{
              name: GitIntegrationPlugin,
              auto_refresh: false
            })

          {:ok, plugin} = GitIntegrationPlugin.start_link(config)

          # Benchmark status fetching
          {time, _result} =
            :timer.tc(fn ->
              Enum.each(1..10, fn _ ->
                GitIntegrationPlugin.get_status()
              end)
            end)

          # Should complete 10 status calls in reasonable time
          assert time < 1_000_000,
                 "Status calls took #{time}μs for 10 iterations"

          safe_stop(plugin)

        _ ->
          # No git repo available, skip performance test
          :ok
      end
    end
  end

  describe "error handling" do
    test "handles invalid git commands gracefully" do
      with_temp_directory(fn temp_dir ->
        File.cd!(temp_dir, fn ->
          # Initialize repo
          System.cmd("git", ["init"])
          System.cmd("git", ["config", "user.email", "test@example.com"])
          System.cmd("git", ["config", "user.name", "Test User"])

          config = create_git_test_config(%{name: GitIntegrationPlugin})
          {:ok, plugin} = GitIntegrationPlugin.start_link(config)

          # Try to stage non-existent file
          assert {:error, _reason} =
                   GitIntegrationPlugin.stage_file("non_existent_file.txt")

          # Try to checkout non-existent branch
          assert {:error, _reason} =
                   GitIntegrationPlugin.checkout_branch("non-existent-branch")

          safe_stop(plugin)
        end)
      end)
    end

    test "logs errors appropriately" do
      logs =
        capture_plugin_logs(fn ->
          config = create_git_test_config(%{name: GitIntegrationPlugin})
          {:ok, plugin} = GitIntegrationPlugin.start_link(config)

          # Trigger an error condition
          {:error, _} = GitIntegrationPlugin.stage_file("non_existent_file.txt")

          safe_stop(plugin)
        end)

      assert String.contains?(logs, "Failed to stage file")
    end
  end
end
