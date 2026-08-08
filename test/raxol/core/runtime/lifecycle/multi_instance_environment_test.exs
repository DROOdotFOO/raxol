defmodule Raxol.Core.Runtime.Lifecycle.MultiInstanceEnvironmentTest do
  @moduledoc """
  Regression coverage for the chat-surface environments (`:telegram`,
  `:gateway`): one Lifecycle per chat means the SAME app module starts many
  times concurrently, so neither the Lifecycle nor its Dispatcher may fall
  back to a derived registered name, and `:gateway` must run driverless and
  without a plugin manager.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Lifecycle
  alias Raxol.Core.Runtime.Rendering.Backends

  defmodule ChatApp do
    @moduledoc false
    def init(_), do: {:ok, %{}}
    def update(_msg, model), do: {model, []}
    def view(_), do: %{type: :text, content: "ok"}
  end

  defp start_one(environment) do
    Lifecycle.start_link(ChatApp,
      environment: environment,
      width: 40,
      height: 10,
      io_writer: fn _ -> :ok end
    )
  end

  defp start_pair(environment),
    do: {start_one(environment), start_one(environment)}

  defp responsive?(pid) do
    _ = :sys.get_state(pid, 5_000)
    true
  catch
    :exit, _ -> false
  end

  defp stop_started(results) do
    for {:ok, pid} <- results do
      Process.unlink(pid)

      try do
        Lifecycle.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  for environment <- [:telegram, :gateway] do
    test "two concurrent #{environment} Lifecycles of the same app module do not collide" do
      {a, b} = start_pair(unquote(environment))

      try do
        assert {:ok, pid_a} = a
        assert {:ok, pid_b} = b
        assert pid_a != pid_b

        dispatcher = fn pid -> :sys.get_state(pid, 5_000).dispatcher_pid end
        assert dispatcher.(pid_a) != dispatcher.(pid_b)
      after
        stop_started([a, b])
      end
    end
  end

  # PluginLifecycle registers `name: __MODULE__`, so the FIRST Lifecycle to
  # start one holds the LINK and every later one merely adopts the pid -- while
  # terminate/2 stops it unconditionally. A per-session environment that owns it
  # therefore lets any one session's disconnect send :shutdown down that link and
  # kill a concurrent session mid-turn. Every multi-instance environment is
  # per-session, so none of them may own it.
  for environment <- [:liveview, :agent, :ssh, :telegram, :gateway] do
    test "a #{environment} Lifecycle owns no plugin manager" do
      result = start_one(unquote(environment))

      try do
        assert {:ok, pid} = result
        assert :sys.get_state(pid, 5_000).plugin_manager == nil
      after
        stop_started([result])
      end
    end

    test "stopping one #{environment} Lifecycle leaves a concurrent one alive" do
      # Trap exits so a cross-kill surfaces as a failed assertion instead of
      # travelling up start_link's link and killing the test process.
      Process.flag(:trap_exit, true)
      {a, b} = start_pair(unquote(environment))

      try do
        assert {:ok, pid_a} = a
        assert {:ok, pid_b} = b

        ref = Process.monitor(pid_b)
        Process.unlink(pid_b)
        Lifecycle.stop(pid_b)
        assert_receive {:DOWN, ^ref, :process, ^pid_b, _}, 5_000

        # A shared manager dies inside B's terminate/2, before B's DOWN is sent,
        # so any resulting exit signal is already queued for A by now and this
        # synchronous call orders behind it. No sleep needed.
        assert responsive?(pid_a),
               "a concurrent session died when its peer disconnected"
      after
        stop_started([a, b])
      end
    end
  end

  test ":gateway starts no terminal driver and no plugin manager" do
    result =
      Lifecycle.start_link(ChatApp,
        environment: :gateway,
        width: 40,
        height: 10,
        io_writer: fn _ -> :ok end
      )

    assert {:ok, pid} = result

    try do
      state = :sys.get_state(pid, 5_000)
      assert state.driver_pid == nil
      assert state.plugin_manager == nil
      assert is_pid(state.dispatcher_pid)
    after
      stop_started([result])
    end
  end

  describe "Backends.render_to_io_writer/3" do
    test "delivers the buffer to the io_writer" do
      test_pid = self()

      state = %{
        width: 10,
        height: 3,
        buffer: nil,
        io_writer: fn data -> send(test_pid, {:frame, data}) end
      }

      cells = [{0, 0, "h", :white, :black, []}, {1, 0, "i", :white, :black, []}]

      assert {:ok, new_state} = Backends.render_to_io_writer(cells, state)
      assert_received {:frame, %{buffer: buffer, view_tree: nil}}
      assert buffer == new_state.buffer
    end

    test "delivers an explicitly passed view tree" do
      test_pid = self()

      state = %{
        width: 10,
        height: 3,
        buffer: nil,
        io_writer: fn data -> send(test_pid, {:frame, data}) end
      }

      view = %{type: :button, id: "ok", content: "OK"}

      assert {:ok, _} =
               Backends.render_to_io_writer(
                 [{0, 0, "x", :white, :black, []}],
                 state,
                 view
               )

      assert_received {:frame, %{view_tree: ^view}}
    end

    test "accepts the engine's struct state (Access-on-struct regression)" do
      # The engine passes %Engine.State{}, which does not implement Access;
      # the old state[:view_tree] raised UndefinedFunctionError here. A plain
      # map cannot reproduce that, so this case pins the struct path.
      test_pid = self()

      state =
        struct(Raxol.Core.Runtime.Rendering.Engine.State,
          width: 10,
          height: 3,
          buffer: nil,
          io_writer: fn data -> send(test_pid, {:frame, data}) end
        )

      view = %{type: :text, content: "hi"}

      assert {:ok, _} =
               Backends.render_to_io_writer(
                 [{0, 0, "h", :white, :black, []}],
                 state,
                 view
               )

      assert_received {:frame, %{buffer: _, view_tree: ^view}}

      assert {:ok, _} =
               Backends.render_to_io_writer(
                 [{0, 0, "h", :white, :black, []}],
                 state
               )

      assert_received {:frame, %{view_tree: nil}}
    end

    test "render_to_telegram delegates to the same path" do
      test_pid = self()

      state = %{
        width: 10,
        height: 3,
        buffer: nil,
        io_writer: fn data -> send(test_pid, {:frame, data}) end
      }

      cells = [{0, 0, "x", :white, :black, []}]

      assert {:ok, _} = Backends.render_to_telegram(cells, state, %{type: :row})
      assert_received {:frame, %{buffer: _, view_tree: %{type: :row}}}
    end

    test "a missing io_writer does not crash" do
      state = %{width: 10, height: 3, buffer: nil, io_writer: nil}

      assert {:ok, _} =
               Backends.render_to_io_writer(
                 [{0, 0, "x", :white, :black, []}],
                 state
               )
    end
  end
end
