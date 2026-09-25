defmodule Raxol.ProfilerTest do
  # The profiler is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Performance.Profiler

  # A server left running by an earlier test would hide an unnamed start.
  setup do
    if pid = Process.whereis(Profiler), do: GenServer.stop(pid)
    :ok
  end

  test "enable/0 starts a profiler the rest of the API reaches" do
    assert :ok = Raxol.Profiler.enable()
    assert :ok = Raxol.Profiler.disable()

    GenServer.stop(Profiler)
  end
end
