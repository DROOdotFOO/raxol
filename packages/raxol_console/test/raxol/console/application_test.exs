defmodule Raxol.Console.ApplicationTest do
  @moduledoc """
  The container entrypoint plans a boot from config + env and boots the real
  runtime from a materialized package. `plan/1` is pure; `boot/2` is tested
  against a real `Boot`/`Supervisor`/`Scheduler` with a capture backend. Not
  async: `boot/2` uses the singleton `Raxol.Console` process names.
  """
  use ExUnit.Case, async: false

  alias Raxol.Console.Application
  alias Raxol.Console.Test.CaptureBackend

  setup do
    dir = Path.join(System.tmp_dir!(), "raxol_console_app_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write_package(dir, tasks) do
    File.write!(Path.join(dir, "soul.md"), "# AppBot\n\nYou help.")
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"runtime" => "raxol"}))
    File.write!(Path.join(dir, "tasks.json"), Jason.encode!(%{"tasks" => tasks}))
    dir
  end

  defp task(name, prompt),
    do: %{"name" => name, "description" => "d", "cron" => "0 9 * * *", "prompt" => prompt}

  describe "plan/1" do
    test "is a no-op when no package is located" do
      assert Application.plan([]) == :none
    end

    test "locates the package via :package_dir and fills defaults" do
      assert {:ok, "/srv/agent", opts} = Application.plan(package_dir: "/srv/agent")
      assert opts[:channels] == []
      assert opts[:agent_opts] == []
    end

    test "falls back to the RAXOL_CONSOLE_PACKAGE env var" do
      System.put_env("RAXOL_CONSOLE_PACKAGE", "/from/env")
      on_exit(fn -> System.delete_env("RAXOL_CONSOLE_PACKAGE") end)

      assert {:ok, "/from/env", _opts} = Application.plan([])
    end

    test "carries deployment channels and inference through" do
      config = [
        package_dir: "/srv/agent",
        agent_opts: [backend: CaptureBackend],
        default_target: "telegram:home"
      ]

      assert {:ok, _dir, opts} = Application.plan(config)
      assert opts[:agent_opts] == [backend: CaptureBackend]
      assert opts[:default_target] == "telegram:home"
    end
  end

  describe "boot/2" do
    test "boots the runtime from a package and reconciles its jobs", %{dir: dir} do
      write_package(dir, [task("digest", "produce the digest")])

      opts = [
        agent_opts: [backend: CaptureBackend, backend_opts: [response: "ok"]],
        bundle_default_mcp: false
      ]

      assert {:ok, report} = Application.boot(dir, opts)
      on_exit(fn -> stop(report.supervisor) end)

      assert report.jobs.created == ["digest"]
      assert report.channels == []
    end

    test "returns a typed error for a missing package", %{dir: dir} do
      assert {:error, {:package_load_failed, _}} =
               Application.boot(Path.join(dir, "nope"), bundle_default_mcp: false)
    end

    test "returns a typed error for a package with an empty soul", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"runtime" => "raxol"}))
      File.write!(Path.join(dir, "soul.md"), "")

      # The parser rejects a non-empty soul before RuntimeConfig runs, so this
      # surfaces as a load failure; the :runtime_config_failed mapping stays as
      # defensive coverage for a package that parses but yields no persona.
      assert {:error, {:package_load_failed, {:invalid_package, "soul.md", _}}} =
               Application.boot(dir, bundle_default_mcp: false)
    end
  end

  defp stop(sup) do
    Supervisor.stop(sup)
  catch
    :exit, _ -> :ok
  end
end
