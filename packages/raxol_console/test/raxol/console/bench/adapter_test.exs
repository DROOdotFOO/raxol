defmodule Raxol.Console.Bench.AdapterTest do
  @moduledoc """
  The native Console bench boots the real runtime from a materialized package
  and returns evidence, or a typed failure that blocks delivery. Only the LLM is
  a capture double; `Boot`, `Supervisor`, `Scheduler`, `Fire`, and `Stream` are
  all real.
  """
  use ExUnit.Case, async: true

  alias Raxol.Earn.Console.Spec
  alias Raxol.Console.Bench.Adapter
  alias Raxol.Console.Test.CaptureBackend

  @spec_stub %Spec{purpose: "bench", runtime: :raxol, agent_name: "benchbot"}

  setup context do
    dir =
      Path.join(System.tmp_dir!(), "raxol_console_bench_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    backend_opts = Map.get(context, :backend_opts, response: "I am BenchBot, here to help.")

    Application.put_env(:raxol_console, :bench,
      agent_opts: [backend: CaptureBackend, backend_opts: backend_opts],
      prompt: "Introduce yourself.",
      timeout_ms: 30_000
    )

    on_exit(fn -> Application.delete_env(:raxol_console, :bench) end)

    {:ok, dir: dir}
  end

  defp write_package(dir, opts) do
    File.write!(Path.join(dir, "soul.md"), Keyword.get(opts, :soul, "# BenchBot\n\nYou help."))
    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"runtime" => "raxol"}))

    tasks = Keyword.get(opts, :tasks, [])
    File.write!(Path.join(dir, "tasks.json"), Jason.encode!(%{"tasks" => tasks}))
    dir
  end

  defp task(name, prompt),
    do: %{"name" => name, "description" => "d", "cron" => "0 9 * * *", "prompt" => prompt}

  describe "run/2" do
    test "passes boot, prompt, and task-dry-run for a package with tasks", %{dir: dir} do
      write_package(dir, tasks: [task("digest", "produce the daily digest")])

      assert {:ok, evidence} = Adapter.run(dir, @spec_stub)
      assert evidence.checks == [boot: :ok, prompt: :ok, task_dry_run: :ok]
      assert evidence.transcript =~ "== boot =="
      assert evidence.transcript =~ "== prompt =="
      assert evidence.transcript =~ "== task_dry_run =="
      assert evidence.transcript =~ "I am BenchBot"
      assert evidence.transcript =~ "created=[\"digest\"]"
    end

    test "skips the task-dry-run check when the package has no tasks", %{dir: dir} do
      write_package(dir, tasks: [])

      assert {:ok, evidence} = Adapter.run(dir, @spec_stub)
      assert evidence.checks == [boot: :ok, prompt: :ok]
      refute evidence.transcript =~ "== task_dry_run =="
    end

    test "does not leave the bench supervisor running", %{dir: dir} do
      write_package(dir, tasks: [])

      assert {:ok, _} = Adapter.run(dir, @spec_stub)
      refute Enum.any?(Process.registered(), &(&1 |> Atom.to_string() =~ "Raxol.Console.Bench."))
    end

    @tag backend_opts: [error: :model_unavailable]
    test "fails the prompt check when the turn errors", %{dir: dir} do
      write_package(dir, tasks: [])

      assert {:error, {:bench_failed, :prompt, :model_unavailable}} = Adapter.run(dir, @spec_stub)
    end

    test "returns a typed load error for a missing package", %{dir: dir} do
      missing = Path.join(dir, "nope")

      assert {:error, {:bench_load_failed, _}} = Adapter.run(missing, @spec_stub)
    end

    test "returns a typed config error for a package with no soul", %{dir: dir} do
      File.write!(Path.join(dir, "manifest.json"), Jason.encode!(%{"runtime" => "raxol"}))
      File.write!(Path.join(dir, "soul.md"), "")

      assert {:error, _} = Adapter.run(dir, @spec_stub)
    end
  end
end
