defmodule Raxol.Core.Runtime.Events.DispatcherResizeTest do
  @moduledoc """
  Regression tests for the terminal resize chain at the Dispatcher level.

  A `%Event{type: :resize}` must (a) reach the application's `update/2`
  so apps can reflow (e.g. Playground tracks `available_width`), and
  (b) notify the Rendering Engine to resize its screen buffer. Before
  the fix, (a) never happened: resize was classified as a system event
  and consumed by the dispatcher without ever calling `update/2`.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Events.Dispatcher
  alias Raxol.Core.Runtime.Events.Dispatcher.State

  defmodule ResizeAwareApp do
    @moduledoc false
    def update(%Event{type: :resize, data: %{width: w, height: h}}, model) do
      {%{model | width: w, height: h, resizes: model.resizes + 1}, []}
    end

    def update(_message, model), do: {model, []}
  end

  defmodule NoResizeClauseApp do
    @moduledoc false
    # Deliberately no catch-all: a resize event raises FunctionClauseError.
    def update(:noop, model), do: {model, []}
  end

  defp base_state(app_module) do
    %State{
      runtime_pid: self(),
      app_module: app_module,
      model: %{width: 0, height: 0, resizes: 0},
      width: 80,
      height: 24,
      # self() stands in for the Rendering Engine GenServer: the
      # dispatcher's cast lands in our mailbox as a plain message.
      rendering_engine: self()
    }
  end

  test "resize event reaches the app's update/2" do
    event = %Event{type: :resize, data: %{width: 120, height: 40}}

    assert {:ok, new_state, _commands} =
             Dispatcher.process_system_event(event, base_state(ResizeAwareApp))

    assert new_state.model.width == 120
    assert new_state.model.height == 40
    assert new_state.model.resizes == 1
  end

  test "resize event updates dispatcher dimensions and rendering engine buffer" do
    event = %Event{type: :resize, data: %{width: 132, height: 43}}

    assert {:ok, new_state, _commands} =
             Dispatcher.process_system_event(event, base_state(ResizeAwareApp))

    assert new_state.width == 132
    assert new_state.height == 43

    # Rendering Engine received the buffer resize cast
    assert_receive {:"$gen_cast", {:update_size, %{width: 132, height: 43}}}

    # A re-render was requested from the runtime
    assert_receive :render_needed
  end

  test "consecutive resizes each reach the app" do
    state = base_state(ResizeAwareApp)

    {:ok, state, _} =
      Dispatcher.process_system_event(
        %Event{type: :resize, data: %{width: 100, height: 30}},
        state
      )

    {:ok, state, _} =
      Dispatcher.process_system_event(
        %Event{type: :resize, data: %{width: 90, height: 25}},
        state
      )

    assert state.model.resizes == 2
    assert state.model.width == 90
    assert state.width == 90 and state.height == 25

    assert_receive {:"$gen_cast", {:update_size, %{width: 100, height: 30}}}
    assert_receive {:"$gen_cast", {:update_size, %{width: 90, height: 25}}}
  end

  test "resize still resizes engine and dimensions when app has no resize clause" do
    event = %Event{type: :resize, data: %{width: 100, height: 30}}

    assert {:ok, new_state, []} =
             Dispatcher.process_system_event(
               event,
               base_state(NoResizeClauseApp)
             )

    # App model untouched (update/2 clause missing), but the runtime
    # still adapts: dimensions tracked, engine buffer resized, re-render.
    assert new_state.model.resizes == 0
    assert new_state.width == 100
    assert new_state.height == 30

    assert_receive {:"$gen_cast", {:update_size, %{width: 100, height: 30}}}

    assert_receive :render_needed
  end

  test "resize with nil rendering engine does not crash" do
    state = %{base_state(ResizeAwareApp) | rendering_engine: nil}
    event = %Event{type: :resize, data: %{width: 100, height: 30}}

    assert {:ok, new_state, _} = Dispatcher.process_system_event(event, state)
    assert new_state.model.width == 100
  end
end
