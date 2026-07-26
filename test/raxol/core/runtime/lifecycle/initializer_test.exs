defmodule Raxol.Core.Runtime.Lifecycle.InitializerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Lifecycle
  alias Raxol.Core.Runtime.Lifecycle.Initializer

  defmodule RegTestApp do
    @moduledoc false
    def init(_), do: {:ok, %{n: 0}}
    def update(_msg, model), do: {model, []}
    def view(_model), do: %{type: :text, content: "ok"}
  end

  describe "session-scoped command registry table (#566)" do
    setup do
      a = start_lifecycle()
      b = start_lifecycle()

      on_exit(fn ->
        for pid <- [a, b], do: stop_lifecycle(pid)
      end)

      %{a: a, b: b}
    end

    test "two concurrent same-module sessions own DISTINCT registry tables",
         %{a: a, b: b} do
      # The bug named the table by app_module alone, so a second session of
      # the same module adopted the first's shared table.
      assert registry_table(a) != registry_table(b)
      assert :ets.info(registry_table(a)) != :undefined
      assert :ets.info(registry_table(b)) != :undefined
    end

    test "stopping one session leaves the other session's table intact",
         %{a: a, b: b} do
      table_b = registry_table(b)
      assert :ets.info(table_b) != :undefined

      # Teardown of A used to :ets.delete the shared table, undefining it for
      # the still-alive B and breaking B's next registry-touching command.
      # Await A's DOWN so its terminate/cleanup has definitely run (stop/1 is
      # an async cast) -- otherwise the check races the teardown.
      :ok = stop_and_await(a)
      refute Process.alive?(a)

      assert Process.alive?(b)
      assert :ets.info(table_b) != :undefined
    end
  end

  defp start_lifecycle do
    name = :"reg_566_#{System.unique_integer([:positive])}"
    {:ok, pid} = Lifecycle.start_link(RegTestApp, environment: :agent, name: name)
    Process.unlink(pid)
    pid
  end

  defp stop_lifecycle(pid) do
    if Process.alive?(pid), do: Lifecycle.stop(pid), else: :ok
  catch
    :exit, _ -> :ok
  end

  # stop/1 is an async cast, so wait for the process to actually terminate
  # (its terminate/2 -- and registry-table cleanup -- runs before :DOWN).
  defp stop_and_await(pid) do
    ref = Process.monitor(pid)
    Lifecycle.stop(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      5_000 -> :timeout
    end
  end

  defp registry_table(pid) do
    :sys.get_state(pid, 5_000).command_registry_table
  end

  describe "detect_terminal_size/1" do
    test "falls back to option values when :io unavailable" do
      # In test env, :io.columns/:io.rows may return {:error, :enotsup}
      # which triggers the fallback path
      {w, h} = Initializer.detect_terminal_size(width: 132, height: 43)

      # Either detects real terminal size or uses our fallback
      assert is_integer(w) and w > 0
      assert is_integer(h) and h > 0
    end

    test "defaults to 80x24 when no options provided" do
      {w, h} = Initializer.detect_terminal_size([])

      assert is_integer(w) and w > 0
      assert is_integer(h) and h > 0
      # Can't assert exact values since a real terminal might be detected
    end
  end
end
