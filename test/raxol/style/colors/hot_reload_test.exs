defmodule Raxol.Style.Colors.HotReloadTest do
  # Run tests serially to avoid GenServer name conflict
  use ExUnit.Case

  alias Raxol.Style.Colors.HotReload

  @test_theme %{
    name: "Test Theme",
    colors: %{
      primary: "#FF0000",
      secondary: "#00FF00",
      background: "#000000",
      foreground: "#FFFFFF"
    },
    ui_mappings: %{
      app_background: :background,
      app_foreground: :foreground
    },
    dark_mode: true,
    high_contrast: false
  }

  # Helper to receive a theme_reloaded message for a specific theme name
  defp receive_theme_with_name(expected_name, timeout \\ 5000) do
    receive do
      {:theme_reloaded, theme} when theme.name == expected_name ->
        theme

      {:theme_reloaded, _other} ->
        receive_theme_with_name(expected_name, timeout)
    after
      timeout ->
        flunk(
          "Did not receive theme_reloaded for #{inspect(expected_name)} within #{timeout}ms"
        )
    end
  end

  # setup runs before each test
  setup do
    # Create temporary directory for theme files
    tmp_dir =
      Path.join(System.tmp_dir!(), "raxol_test_#{:rand.uniform(1_000_000)}")

    File.mkdir_p!(tmp_dir)

    # Stop any existing HotReload process to avoid conflicts
    case Process.whereis(HotReload) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          try do
            GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end
        end
    end

    # Start the hot-reload server for this test
    {:ok, pid} = HotReload.start_link(name: HotReload)

    # Ensure the server is watching the test path
    HotReload.watch_path(tmp_dir)

    # Subscribe this test process to the HotReload server
    HotReload.subscribe()

    # Cleanup after each test
    on_exit(fn ->
      # Stop the server if still alive
      if Process.alive?(pid) do
        try do
          GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end
      end

      # Clean up temp directory
      File.rm_rf!(tmp_dir)
    end)

    # Pass tmp_dir to the test case
    %{tmp_dir: tmp_dir}
  end

  describe "theme hot-reloading" do
    @tag :skip_on_ci
    test "detects and reloads theme changes", %{tmp_dir: tmp_dir} do
      # Create initial theme file
      theme_path = Path.join(tmp_dir, "test_theme.json")
      File.write!(theme_path, Jason.encode!(@test_theme))

      # Wait for test theme to be loaded (ignore Default)
      theme = receive_theme_with_name("Test Theme")
      assert theme.name == "Test Theme"

      # Modify theme file
      updated_theme = %{@test_theme | name: "Updated Theme"}
      File.write!(theme_path, Jason.encode!(updated_theme))
      # Set mtime 2 seconds into the future
      now = :calendar.local_time()
      {{y, m, d}, {h, min, s}} = now
      File.touch!(theme_path, {{y, m, d}, {h, min, s + 2}})

      # Wait for updated theme to be reloaded
      theme = receive_theme_with_name("Updated Theme", 7000)
      assert theme.name == "Updated Theme"
    end

    @tag :skip_on_ci
    test "handles multiple theme files", %{tmp_dir: tmp_dir} do
      # Create multiple theme files
      theme1_path = Path.join(tmp_dir, "theme1.json")
      theme2_path = Path.join(tmp_dir, "theme2.json")

      File.write!(theme1_path, Jason.encode!(%{@test_theme | name: "Theme 1"}))
      File.write!(theme2_path, Jason.encode!(%{@test_theme | name: "Theme 2"}))

      # Wait for both themes to be loaded (ignore Default)
      theme1 = receive_theme_with_name("Theme 1")
      theme2 = receive_theme_with_name("Theme 2")

      assert theme1.name == "Theme 1"
      assert theme2.name == "Theme 2"

      # Modify one theme
      File.write!(
        theme1_path,
        Jason.encode!(%{@test_theme | name: "Updated Theme 1"})
      )

      # Set mtime 2 seconds into the future
      now = :calendar.local_time()
      {{y, m, d}, {h, min, s}} = now
      File.touch!(theme1_path, {{y, m, d}, {h, min, s + 2}})

      # Wait for the updated theme to be loaded
      theme = receive_theme_with_name("Updated Theme 1", 7000)
      assert theme.name == "Updated Theme 1"
    end

    test "handles invalid theme files", %{tmp_dir: tmp_dir} do
      # Create invalid theme file
      theme_path = Path.join(tmp_dir, "invalid_theme.json")
      File.write!(theme_path, "invalid json")

      # Should not receive any test theme reloaded messages
      receive do
        {:theme_reloaded, theme} ->
          if theme.name == "invalid_theme" do
            flunk("Unexpectedly received theme_reloaded for invalid_theme")
          else
            # Ignore other themes (e.g., Default)
            :ok
          end
      after
        1000 -> :ok
      end
    end

    test "handles file deletion", %{tmp_dir: tmp_dir} do
      # Create theme file
      theme_path = Path.join(tmp_dir, "test_theme.json")
      File.write!(theme_path, Jason.encode!(@test_theme))

      # Wait for test theme to be loaded (ignore Default)
      theme = receive_theme_with_name("Test Theme")
      assert theme.name == "Test Theme"

      # Delete theme file
      File.rm!(theme_path)

      # Should not receive any test theme reloaded messages
      receive do
        {:theme_reloaded, theme} ->
          if theme.name == "Test Theme" do
            flunk(
              "Unexpectedly received theme_reloaded for Test Theme after deletion"
            )
          else
            # Ignore other themes (e.g., Default)
            :ok
          end
      after
        1000 -> :ok
      end
    end
  end

  describe "subscriber management" do
    test "handles multiple subscribers", %{tmp_dir: tmp_dir} do
      test = self()

      spawn_link(fn ->
        :ok = HotReload.subscribe()
        send(test, :subscribed)
        send(test, {:other_received, receive_theme_with_name("Test Theme")})
      end)

      assert_receive :subscribed

      # Create theme file
      theme_path = Path.join(tmp_dir, "test_theme.json")
      File.write!(theme_path, Jason.encode!(@test_theme))

      # Both subscribers should receive the test theme (ignore Default)
      assert receive_theme_with_name("Test Theme").name == "Test Theme"
      assert_receive {:other_received, %{name: "Test Theme"}}, 5000
    end

    test "notifies a process that subscribed twice once", %{tmp_dir: tmp_dir} do
      :ok = HotReload.subscribe()

      theme_path = Path.join(tmp_dir, "test_theme.json")
      File.write!(theme_path, Jason.encode!(@test_theme))

      assert receive_theme_with_name("Test Theme").name == "Test Theme"
      refute_receive {:theme_reloaded, %{name: "Test Theme"}}, 300
    end

    test "drops a subscriber that exits" do
      test = self()

      subscriber =
        spawn(fn ->
          :ok = HotReload.subscribe()
          send(test, :subscribed)
          receive do: (:stop -> :ok)
        end)

      assert_receive :subscribed
      assert subscriber in :sys.get_state(HotReload).subscribers

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      refute subscriber in :sys.get_state(HotReload).subscribers
    end

    test "handles subscriber unsubscribe", %{tmp_dir: tmp_dir} do
      # Unsubscribe
      HotReload.unsubscribe()

      # Create theme file
      theme_path = Path.join(tmp_dir, "test_theme.json")
      File.write!(theme_path, Jason.encode!(@test_theme))

      # Should not receive any test theme reloaded messages
      receive do
        {:theme_reloaded, theme} ->
          if theme.name == "Test Theme" do
            flunk(
              "Unexpectedly received theme_reloaded for Test Theme after unsubscribe"
            )
          else
            # Ignore other themes (e.g., Default)
            :ok
          end
      after
        1000 -> :ok
      end
    end
  end
end
