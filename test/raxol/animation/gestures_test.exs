defmodule Raxol.Animation.GesturesTest do
  use ExUnit.Case, async: false

  alias Raxol.Animation.Gestures
  alias Raxol.Animation.Gestures.GestureServer

  setup do
    %{server: start_supervised!(GestureServer)}
  end

  test "the public API reaches the supervised server" do
    assert :ok = Gestures.init()
    assert %GestureServer.State{active: false} = Gestures.get_state()
  end

  test "a process that only moves is dropped when it exits", %{server: server} do
    test = self()

    mover =
      spawn(fn ->
        :ok = Gestures.touch_move({1, 1}, 0)
        send(test, :moved)
        receive do: (:stop -> :ok)
      end)

    assert_receive :moved
    assert Map.has_key?(:sys.get_state(server).process_states, mover)

    ref = Process.monitor(mover)
    Process.exit(mover, :kill)
    assert_receive {:DOWN, ^ref, :process, ^mover, :killed}

    refute Map.has_key?(:sys.get_state(server).process_states, mover)
  end
end
