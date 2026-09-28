#!/usr/bin/env elixir

# Plugin Memory Benchmark
# Measures memory usage for plugin manager operations.
# Run with `mix run bench/memory/plugin_memory_benchmark.exs`
# Emit machine-readable output with `-- --json`.

defmodule PluginMemoryBenchmark do
  @moduledoc """
  Memory benchmarks for the canonical plugin runtime: loading, the
  enable/disable cycle, reload, config updates, and unloading.

  The runtime supervisor is started once. Scenarios clean up any plugin left by
  the preceding Benchee iteration before measuring the next lifecycle operation.
  """

  alias Raxol.Plugins.Manager

  alias Raxol.Core.Runtime.Plugins.{PluginLifecycle, PluginSupervisor}

  @scenarios %{
    "manager_create" => :manager_create,
    "single_plugin_load" => :single_plugin_load,
    "multiple_plugin_load" => :multiple_plugin_load,
    "plugin_lifecycle" => :plugin_lifecycle,
    "plugin_reload" => :plugin_reload,
    "dependency_resolution" => :dependency_resolution
  }

  def run_benchmarks(opts \\ []) do
    ensure_plugin_runtime_started()

    config =
      [
        time: 3,
        memory_time: 2,
        warmup: 1,
        formatters: [Benchee.Formatters.Console]
      ]
      |> Keyword.merge(opts)

    IO.puts("Running Plugin Memory Benchmarks...")

    jobs =
      Map.new(@scenarios, fn {name, fun} ->
        {name, fn -> apply(__MODULE__, fun, []) end}
      end)

    Benchee.run(jobs, config)
  end

  def manager_create do
    {:ok, manager} = Manager.new()
    manager
  end

  def single_plugin_load do
    unload_if_loaded("hyperlink")
    {:ok, manager} = Manager.new()
    {:ok, manager} = Manager.load_plugin(manager, Raxol.Plugins.HyperlinkPlugin)
    manager
  end

  def multiple_plugin_load do
    Enum.each(plugin_modules(), fn module ->
      module
      |> plugin_name()
      |> unload_if_loaded()
    end)

    {:ok, manager} = Manager.new()

    Enum.reduce(plugin_modules(), manager, fn module, acc ->
      case Manager.load_plugin(acc, module) do
        {:ok, updated} -> updated
        {:error, _reason} -> acc
      end
    end)
  end

  def plugin_lifecycle do
    unload_if_loaded("hyperlink")
    {:ok, manager} = Manager.new()
    {:ok, manager} = Manager.load_plugin(manager, Raxol.Plugins.HyperlinkPlugin)
    {:ok, manager} = Manager.disable_plugin(manager, "hyperlink")
    {:ok, manager} = Manager.enable_plugin(manager, "hyperlink")
    {:ok, manager} = Manager.unload_plugin(manager, "hyperlink")
    manager
  end

  def plugin_reload do
    unload_if_loaded("hyperlink")
    {:ok, manager} = Manager.new()

    Enum.reduce(1..5, manager, fn _i, acc ->
      {:ok, acc} = Manager.load_plugin(acc, Raxol.Plugins.HyperlinkPlugin)
      {:ok, acc} = Manager.unload_plugin(acc, "hyperlink")
      acc
    end)
  end

  # Exercises the topological sort and cycle check restored in #799.
  def dependency_resolution do
    plugins =
      Enum.map(1..20, fn i ->
        deps = if i > 1, do: [{"plugin_#{i - 1}", ">= 1.0.0"}], else: []

        %Raxol.Plugins.Plugin{
          name: "plugin_#{i}",
          version: "1.0.0",
          dependencies: deps,
          enabled: true
        }
      end)

    {:ok, order} =
      Raxol.Plugins.Lifecycle.Dependencies.resolve_plugin_order(plugins)

    order
  end

  defp ensure_plugin_runtime_started do
    if Process.whereis(PluginSupervisor) == nil do
      {:ok, _pid} = PluginSupervisor.start_link()
    end

    if Process.whereis(PluginLifecycle) == nil do
      {:ok, _pid} = PluginLifecycle.start_link()
    end
  end

  defp unload_if_loaded(plugin_name) do
    case PluginLifecycle.get_status(plugin_name) do
      nil -> :ok
      _status -> PluginLifecycle.unload(plugin_name)
    end
  end

  defp plugin_name(module) do
    module
    |> Raxol.Plugins.Lifecycle.Initialization.get_plugin_id_from_metadata()
  end

  defp plugin_modules do
    [
      Raxol.Plugins.HyperlinkPlugin,
      Raxol.Plugins.ImagePlugin,
      Raxol.Plugins.ThemePlugin,
      Raxol.Plugins.SearchPlugin
    ]
    |> Enum.filter(&Code.ensure_loaded?/1)
  end
end

# `mix run file.exs -- --json` leaves the literal "--" in argv, and
# OptionParser reads that as end-of-options, dropping every flag after it.
argv =
  case System.argv() do
    ["--" | rest] -> rest
    argv -> argv
  end

{opts, _args, _invalid} =
  OptionParser.parse(argv,
    switches: [
      json: :boolean,
      time: :integer,
      memory_time: :integer,
      warmup: :integer
    ]
  )

# Build the option list in one pass. Rebinding inside `if` does not escape the
# block in Elixir, which is how this file previously ignored every flag.
benchmark_opts =
  Enum.reduce(opts, [], fn
    {:json, true}, acc ->
      Keyword.put(acc, :formatters, [
        {Benchee.Formatters.JSON, file: "/dev/stdout"}
      ])

    {:time, value}, acc ->
      Keyword.put(acc, :time, value)

    {:memory_time, value}, acc ->
      Keyword.put(acc, :memory_time, value)

    {:warmup, value}, acc ->
      Keyword.put(acc, :warmup, value)

    _other, acc ->
      acc
  end)

File.mkdir_p("bench/output")

PluginMemoryBenchmark.run_benchmarks(benchmark_opts)
