defmodule Raxol.Dev.CodeReloaderTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Dev.CodeReloader

  setup do
    # Ensure no leftover CodeReloader from a previous test
    case Process.whereis(CodeReloader) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, 1000)
    end

    :ok
  end

  describe "init/1" do
    test "starts with lifecycle_pid" do
      {:ok, pid} = CodeReloader.start_link(self())
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "debouncing" do
    @tag timeout: 120_000
    test "multiple rapid file events produce one recompile" do
      {:ok, pid} = CodeReloader.start_link(self())

      # Simulate rapid file change events
      send(pid, {:file_event, self(), {"lib/test.ex", [:modified]}})
      send(pid, {:file_event, self(), {"lib/test2.ex", [:modified]}})
      send(pid, {:file_event, self(), {"lib/test3.ex", [:modified]}})

      # After the debounce, `IEx.Helpers.recompile/0` runs a real Mix compile
      # of this project and only then sends :render_needed. On nightly's macOS
      # runner that outlasted the former 3s bound (2026-10-20, "Recompiling..."
      # logged, no message). The bound is a hang detector, not a speed check.
      assert_receive :render_needed, 60_000

      GenServer.stop(pid)
    end
  end

  describe "file filtering" do
    test "ignores non-.ex files" do
      {:ok, pid} = CodeReloader.start_link(self())

      send(pid, {:file_event, self(), {"lib/test.txt", [:modified]}})

      # :sys.get_state is served after the event; a non-.ex path must not
      # have armed the debounce timer, so no :recompile can ever fire.
      assert %{timer_ref: nil} = :sys.get_state(pid)
      refute_received :render_needed

      GenServer.stop(pid)
    end
  end
end
