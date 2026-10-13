defmodule Raxol.Terminal.StandaloneBootTest do
  @moduledoc """
  raxol_terminal depends on raxol_core only (docs/PACKAGES.md), so every public
  function must work with just those two applications loaded. This suite runs
  in the package's own `mix test`, where main raxol is absent: a function that
  reaches into `lib/` of the root app raises `UndefinedFunctionError` here and
  nowhere else, which is how these three sites went unnoticed.
  """
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Config.Capabilities
  alias Raxol.Terminal.Config.Schema
  alias Raxol.Terminal.Script.ScriptServer
  alias Raxol.Terminal.Theme.Manager

  describe "Capabilities.optimized_config/0" do
    test "detects capabilities through the in-package environment adapter" do
      config = Capabilities.optimized_config()

      assert is_map(config)
      assert config.width == 80
      assert config.height == 24

      for key <- Map.keys(config) do
        assert Map.has_key?(Schema.schema(), key), "#{key} is not a schema key"
      end
    end
  end

  describe "Theme.Manager registry access" do
    test "list_registry_themes/0 lists the raxol_core registry" do
      themes = Manager.list_registry_themes()

      assert :dracula in themes
      assert themes == Enum.sort(themes)
    end

    test "load_from_registry/2 installs a registry theme" do
      manager = Manager.new()

      assert {:ok, manager} = Manager.load_from_registry(manager, :dracula)
      assert manager.current_theme.name == "dracula"
      assert %{r: _, g: _, b: _, a: 1.0} = manager.current_theme.colors.red
      assert Map.has_key?(manager.themes, "dracula")

      assert {:error, :theme_not_found} =
               Manager.load_from_registry(manager, :no_such_theme)
    end
  end

  describe "ScriptServer auto_load" do
    test "keeps scripts found on script_paths in the server's own state" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "raxol_script_autoload_#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      File.write!(Path.join(dir, "greet.exs"), ~s|IO.puts("hi")|)
      File.write!(Path.join(dir, "notes.md"), "not a script")

      case Process.whereis(ScriptServer) do
        nil -> :ok
        pid -> GenServer.stop(pid)
      end

      {:ok, pid} =
        ScriptServer.start_link(
          name: ScriptServer,
          script_paths: [dir],
          auto_load: true
        )

      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end)

      assert {:ok, scripts} = ScriptServer.get_scripts()
      assert [{_id, script}] = Map.to_list(scripts)
      assert script.type == :elixir
      assert script.source == ~s|IO.puts("hi")|
      assert script.status == :idle
    end
  end
end
