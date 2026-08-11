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

    {:ok, pid} =
      Lifecycle.start_link(RegTestApp, environment: :agent, name: name)

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

  # `Application.init/1` is declared `{model, [command]} | {model, command} |
  # model | {:error, term}` -- model FIRST, mirroring `update/2`. A blanket
  # `{_, model}` clause bound the SECOND element instead, so a lawful
  # `{%{...}, []}` handed the runtime `[]` as its model and the first update to
  # touch it raised `%BadMapError{term: []}`.
  describe "init/1 return shapes" do
    defmodule TupleInitApp do
      @moduledoc false
      def init(_), do: {%{n: 7}, []}
      def update(_msg, model), do: {Map.put(model, :touched, true), []}
      def view(_model), do: %{type: :text, content: "ok"}
    end

    defmodule BareMapInitApp do
      @moduledoc false
      def init(_), do: %{n: 8}
      def update(_msg, model), do: {model, []}
      def view(_model), do: %{type: :text, content: "ok"}
    end

    defmodule OkTupleInitApp do
      @moduledoc false
      def init(_), do: {:ok, %{n: 9}}
      def update(_msg, model), do: {model, []}
      def view(_model), do: %{type: :text, content: "ok"}
    end

    defmodule ErrorInitApp do
      @moduledoc false
      def init(_), do: {:error, :nope}
      def update(_msg, model), do: {model, []}
      def view(_model), do: %{type: :text, content: "ok"}
    end

    test "{model, commands} keeps the MODEL, not the command list" do
      pid = start_app!(TupleInitApp)
      assert model(pid) == %{n: 7}
    end

    # The exact path Symphony took: an `{:agent_message, from, payload}` cast
    # goes straight to update/2, where `Map.put/3` on the command list raised
    # %BadMapError{term: []} and the update was dropped.
    test "the model survives into update/2 as a map" do
      pid = start_app!(TupleInitApp)
      send_agent_message(pid, {:symphony_start, %{}})

      assert %{n: 7, touched: true} = model(pid)
    end

    test "a bare map model is taken as-is" do
      pid = start_app!(BareMapInitApp)
      assert model(pid) == %{n: 8}
    end

    test "{:ok, model} is still honored" do
      pid = start_app!(OkTupleInitApp)
      assert model(pid) == %{n: 9}
    end

    test "{:error, reason} stops the lifecycle instead of becoming the model" do
      Process.flag(:trap_exit, true)

      assert {:error, {:app_init_failed, :nope}} =
               Lifecycle.start_link(ErrorInitApp,
                 environment: :agent,
                 name: :"init_err_#{System.unique_integer([:positive])}"
               )
    end

    defp start_app!(module) do
      name = :"init_shape_#{System.unique_integer([:positive])}"
      {:ok, pid} = Lifecycle.start_link(module, environment: :agent, name: name)
      Process.unlink(pid)
      on_exit(fn -> stop_lifecycle(pid) end)
      pid
    end

    defp model(pid) do
      :sys.get_state(dispatcher(pid), 5_000).model
    end

    defp dispatcher(pid), do: :sys.get_state(pid, 5_000).dispatcher_pid

    defp send_agent_message(pid, payload) do
      GenServer.cast(
        dispatcher(pid),
        {:dispatch, {:agent_message, "test", payload}}
      )

      # Fold the cast through the dispatcher before reading its state back.
      _ = :sys.get_state(dispatcher(pid), 5_000)
      :ok
    end
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
