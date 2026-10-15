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
    test "multiple rapid file events produce one recompile" do
      {:ok, pid} = CodeReloader.start_link(self())

      # Simulate rapid file change events
      send(pid, {:file_event, self(), {"lib/test.ex", [:modified]}})
      send(pid, {:file_event, self(), {"lib/test2.ex", [:modified]}})
      send(pid, {:file_event, self(), {"lib/test3.ex", [:modified]}})

      # Wait for debounce (500ms) + recompile time with generous margin.
      # recompile() may return :ok (sends :render_needed) or :noop (no changes).
      # Use assert_receive with timeout to handle variable recompile duration.
      assert_receive :render_needed, 3000

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
