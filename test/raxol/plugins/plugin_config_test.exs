defmodule Raxol.Plugins.PluginConfigTest do
  use ExUnit.Case, async: false

  @moduledoc """
  Tests for plugin configuration functionality including loading, saving,
  and managing plugin settings.
  """

  alias Raxol.Plugins.PluginConfig

  setup do
    temp_dir = Path.join(System.tmp_dir!(), "raxol_plugin_config_test")
    real_home = System.user_home!()
    real_config_dir = Path.join([real_home, ".config/raxol/plugins"])
    temp_config_dir = Path.join([temp_dir, ".config/raxol/plugins"])
    # Clean up both temp and real config dirs
    File.rm_rf!(temp_config_dir)
    File.rm_rf!(real_config_dir)
    File.mkdir_p!(temp_dir)
    System.put_env("HOME", temp_dir)

    on_exit(fn ->
      File.rm_rf!(temp_config_dir)
      File.rm_rf!(real_config_dir)
    end)

    {:ok, temp_dir: temp_dir, real_home: real_home}
  end

  describe "plugin configuration" do
    test "creates a new plugin configuration" do
      config = PluginConfig.new()
      assert config.plugin_configs == %{}
      assert config.enabled_plugins == []
    end

    test "loads and saves plugin configuration", %{_temp_dir: temp_dir} do
      # Create initial config
      config = PluginConfig.new()

      config =
        PluginConfig.update_plugin_config(config, "test_plugin", %{
          setting: "value"
        })

      config = PluginConfig.enable_plugin(config, "test_plugin")

      # Save config
      {:ok, saved_config} = PluginConfig.save(config)
      assert saved_config.plugin_configs["test_plugin"] == %{setting: "value"}
      assert "test_plugin" in saved_config.enabled_plugins

      # Load config
      {:ok, loaded_config} = PluginConfig.load()

      assert loaded_config.plugin_configs["test_plugin"] == %{
               "setting" => "value"
             }

      assert "test_plugin" in loaded_config.enabled_plugins
    end

    test "gets plugin configuration" do
      config = PluginConfig.new()

      config =
        PluginConfig.update_plugin_config(config, "test_plugin", %{
          setting: "value"
        })

      plugin_config = PluginConfig.get_plugin_config(config, "test_plugin")
      assert plugin_config == %{setting: "value"}

      # Non-existent plugin should return empty map
      plugin_config = PluginConfig.get_plugin_config(config, "nonexistent")
      assert plugin_config == %{}
    end

    test "updates plugin configuration" do
      config = PluginConfig.new()

      config =
        PluginConfig.update_plugin_config(config, "test_plugin", %{
          setting: "value"
        })

      config =
        PluginConfig.update_plugin_config(config, "test_plugin", %{
          setting: "new_value"
        })

      plugin_config = PluginConfig.get_plugin_config(config, "test_plugin")
      assert plugin_config == %{setting: "new_value"}
    end

    test "enables and disables plugins" do
      config = PluginConfig.new()

      # Enable plugin
      config = PluginConfig.enable_plugin(config, "test_plugin")
      assert PluginConfig.plugin_enabled?(config, "test_plugin")

      # Enable again (should not duplicate)
      config = PluginConfig.enable_plugin(config, "test_plugin")
      assert length(config.enabled_plugins) == 1

      # Disable plugin
      config = PluginConfig.disable_plugin(config, "test_plugin")
      refute PluginConfig.plugin_enabled?(config, "test_plugin")
    end

    test "handles loading non-existent configuration file" do
      # Set HOME to a fixed temporary directory to ensure clean state
      temp_dir = Path.join(System.tmp_dir!(), "raxol_plugin_config_test")
      File.rm_rf!(temp_dir)
      File.mkdir_p!(temp_dir)
      System.put_env("HOME", temp_dir)

      {:ok, config} = PluginConfig.load()
      assert config.plugin_configs == %{}
      assert config.enabled_plugins == []
    end
  end
end
