defmodule Raxol.Gateway.Handler.LifecycleTest do
  # async: false - each test starts a full Raxol Lifecycle (engine + dispatcher).
  use ExUnit.Case, async: false

  alias Raxol.Gateway.Handler
  alias Raxol.Gateway.Route

  # The handler runs inside the session process; in these tests the test
  # process plays that role, so io_writer frames arrive in our mailbox.

  defmodule EchoApp do
    @moduledoc false
    use Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{last: "ready"}

    @impl true
    def update(message, model) do
      case message do
        %Raxol.Core.Events.Event{type: :paste, data: %{text: text}} ->
          {%{model | last: text}, []}

        %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}} ->
          {%{model | last: char}, []}

        _ ->
          {model, []}
      end
    end

    @impl true
    def view(model) do
      Raxol.Core.Renderer.View.text("last: #{model.last}")
    end

    @impl true
    def subscriptions(_model), do: []
  end

  defp route do
    Route.new(%{platform: :in_memory, chat_type: :dm, chat_id: "chat-1"})
  end

  defp init_handler!(opts \\ []) do
    assert {:ok, state} =
             Handler.Lifecycle.init(route(), Keyword.put_new(opts, :app_module, EchoApp))

    on_exit(fn -> Handler.Lifecycle.terminate(:normal, state) end)

    # Consume the app's startup frame so every turn below is strictly
    # request -> response (otherwise the first turn can race it).
    assert_receive {Handler.Lifecycle, :render, _initial}, 5_000
    state
  end

  describe "init/2" do
    test "starts a Lifecycle with a live dispatcher" do
      state = init_handler!()

      assert is_pid(state.lifecycle_pid)
      assert Process.alive?(state.lifecycle_pid)
      assert is_pid(state.dispatcher_pid)
    end

    test "two handlers for the same app module coexist" do
      # The regression this environment exists for: derived process names
      # made two same-module chat sessions collide.
      state_a = init_handler!()
      state_b = init_handler!()

      assert state_a.lifecycle_pid != state_b.lifecycle_pid
      assert state_a.dispatcher_pid != state_b.dispatcher_pid
    end
  end

  describe "handle_event/2" do
    test "a text event replies with the app's rendered frame" do
      state = init_handler!()

      assert {:reply, rendered, _state} =
               Handler.Lifecycle.handle_event(%{text: "hello world"}, state)

      assert rendered =~ "last: hello world"
    end

    test "a single grapheme dispatches as a char key event" do
      state = init_handler!()

      assert {:reply, rendered, _state} = Handler.Lifecycle.handle_event(%{text: "q"}, state)

      assert rendered =~ "last: q"
    end

    test "an untranslatable event is absorbed" do
      state = init_handler!()

      assert {:noreply, _state} =
               Handler.Lifecycle.handle_event(%{media: %{kind: :voice}}, state)

      assert {:noreply, _state} = Handler.Lifecycle.handle_event(:not_a_gateway_event, state)
    end

    test "a nil dispatcher absorbs events instead of crashing" do
      state = init_handler!()

      assert {:noreply, _state} =
               Handler.Lifecycle.handle_event(%{text: "hi"}, %{state | dispatcher_pid: nil})
    end

    test "a custom format_fn shapes the reply" do
      state =
        init_handler!(format_fn: fn %{buffer: _} -> "custom frame" end)

      assert {:reply, "custom frame", _state} =
               Handler.Lifecycle.handle_event(%{text: "x"}, state)
    end

    test "a custom event_fn can drop events" do
      state = init_handler!(event_fn: fn _ -> nil end)

      assert {:noreply, _state} = Handler.Lifecycle.handle_event(%{text: "ignored"}, state)
    end
  end

  describe "terminate/2" do
    test "stops the Lifecycle so it cannot outlive the session" do
      assert {:ok, state} = Handler.Lifecycle.init(route(), app_module: EchoApp)
      lifecycle_pid = state.lifecycle_pid
      ref = Process.monitor(lifecycle_pid)

      assert Handler.Lifecycle.terminate(:normal, state) == :ok
      assert_receive {:DOWN, ^ref, :process, ^lifecycle_pid, _reason}, 2_000
    end

    test "a dead Lifecycle does not crash teardown" do
      assert {:ok, state} = Handler.Lifecycle.init(route(), app_module: EchoApp)

      assert Handler.Lifecycle.terminate(:normal, state) == :ok
      # Second run: the pid is already down.
      assert Handler.Lifecycle.terminate(:normal, state) == :ok
    end
  end

  describe "session integration" do
    test "a Session invokes the handler's terminate on clean stop" do
      # The Lifecycle is linked to the session process, but a session's
      # :normal exit does not propagate over links -- only the terminate
      # hook prevents a leaked per-chat app.
      {:ok, session} =
        Raxol.Gateway.Session.start_link(
          route: route(),
          handler: {Handler.Lifecycle, [app_module: EchoApp]}
        )

      {:links, links} = Process.info(session, :links)
      lifecycles = links -- [self()]

      assert lifecycles != []
      refs = Enum.map(lifecycles, &{&1, Process.monitor(&1)})

      GenServer.stop(session, :normal)

      for {pid, ref} <- refs do
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 2_000
      end
    end
  end
end
