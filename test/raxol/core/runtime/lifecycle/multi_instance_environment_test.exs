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

  defp start_pair(environment) do
    opts = [
      environment: environment,
      width: 40,
      height: 10,
      io_writer: fn _ -> :ok end
    ]

    a = Lifecycle.start_link(ChatApp, opts)
    b = Lifecycle.start_link(ChatApp, opts)
    {a, b}
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
               Backends.render_to_io_writer([{0, 0, "x", :white, :black, []}], state, view)

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
               Backends.render_to_io_writer([{0, 0, "h", :white, :black, []}], state, view)

      assert_received {:frame, %{buffer: _, view_tree: ^view}}

      assert {:ok, _} =
               Backends.render_to_io_writer([{0, 0, "h", :white, :black, []}], state)

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
