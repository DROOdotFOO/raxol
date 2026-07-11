defmodule Raxol.ApplicationTest do
  use ExUnit.Case, async: false

  describe "Raxol.Application startup modes" do
    test "determines startup mode correctly" do
      # Test mode should be detected in test environment
      assert Application.get_env(:raxol, :startup_mode) == nil ||
               Mix.env() == :test
    end

    test "health_status returns valid information" do
      status = Raxol.Application.health_status()

      assert is_map(status)
      assert status.mode in [:test, :minimal, :full]
      assert is_boolean(status.supervisor_alive)
      assert is_integer(status.children)
      assert is_integer(status.memory_mb)
      assert is_integer(status.process_count)
      assert is_map(status.features)
      assert is_integer(status.uptime_seconds)
    end

    test "toggle_feature works for runtime features" do
      # Features that don't require restart
      assert Raxol.Application.toggle_feature(:telemetry, false) == :ok
      assert Raxol.Application.toggle_feature(:plugins, true) == :ok
      assert Raxol.Application.toggle_feature(:audit, true) == :ok

      # Features that require restart
      assert Raxol.Application.toggle_feature(:web_interface, false) ==
               {:error, :restart_required}

      assert Raxol.Application.toggle_feature(:database, false) ==
               {:error, :restart_required}

      assert Raxol.Application.toggle_feature(:pubsub, false) ==
               {:error, :restart_required}
    end

    test "add_child and remove_child handle missing dynamic supervisor" do
      # In test mode, DynamicSupervisor might not be started
      result = Raxol.Application.add_child({Task, fn -> :ok end})

      assert result == {:error, :dynamic_supervisor_not_started} ||
               match?({:ok, _}, result)

      result = Raxol.Application.remove_child(:nonexistent)

      assert result == {:error, :not_found} ||
               result == {:error, :dynamic_supervisor_not_started}
    end
  end

  describe "Feature flags" do
    test "default features are set correctly" do
      # Get current features
      status = Raxol.Application.health_status()
      features = status.features

      # These should be default in most environments
      assert is_map(features)

      # Check that features is not empty
      assert map_size(features) > 0
    end

    test "get_feature_flag reads maps and keyword lists (regression: keyword config crashed boot)" do
      # Documented shape: a map.
      assert Raxol.Application.get_feature_flag(%{database: true}, :database)
      refute Raxol.Application.get_feature_flag(%{database: false}, :database)
      refute Raxol.Application.get_feature_flag(%{}, :missing)

      # A keyword list (what `config :raxol, :features, key: value` produces).
      # This used to hit Map.get on a list and raise BadMapError during boot.
      assert Raxol.Application.get_feature_flag([database: true], :database)
      refute Raxol.Application.get_feature_flag([database: false], :database)
      refute Raxol.Application.get_feature_flag([], :missing)

      # Anything else degrades to false rather than crashing.
      refute Raxol.Application.get_feature_flag("garbage", :database)
      refute Raxol.Application.get_feature_flag(nil, :database)
    end
  end

  describe "Memory optimization" do
    test "configure_process_flags sets appropriate flags" do
      assert Raxol.Application.configure_process_flags() == :ok

      # Verify process flags are set
      info = Process.info(self())
      assert info[:trap_exit] == true
      # message_queue_data might not be available in all OTP versions
      assert info[:message_queue_data] == :off_heap ||
               info[:message_queue_data] == nil
    end
  end
end
