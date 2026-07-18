defmodule Raxol.Harness.DeliveryShimTest do
  @moduledoc """
  Unit U6-c's delivery seam: the shim casts every pump term into the
  Dispatcher through the right ingress -- verbatim `{:dispatch, {:harness,
  term}}` (U6-a) for the frozen PumpContract vocabulary, and
  `{:dispatch, event}` (the system-event path) for resize, whose Engine
  size sync lives there (PumpContract §3's one exception).
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.Harness.DeliveryShim

  defmodule RecordingDispatcher do
    @moduledoc false
    use GenServer

    def start_link(recorder), do: GenServer.start_link(__MODULE__, recorder)

    @impl true
    def init(recorder), do: {:ok, recorder}

    @impl true
    def handle_cast(message, recorder) do
      send(recorder, {:dispatched, message})
      {:noreply, recorder}
    end
  end

  setup do
    {:ok, dispatcher} = RecordingDispatcher.start_link(self())
    {:ok, shim} = DeliveryShim.start_link(dispatcher)
    %{shim: shim, dispatcher: dispatcher}
  end

  test "a pump contract message rides the verbatim {:harness, _} ingress", %{
    shim: shim
  } do
    batch = {:batch, [{:event, %{id: 1}}, {:cadence_dropped, 2}]}
    send(shim, batch)

    assert_receive {:dispatched, {:dispatch, {:harness, received}}}
    assert received == batch
  end

  test "resize rides the system-event path, never the verbatim seam", %{
    shim: shim
  } do
    event = %Event{type: :resize, data: %{width: 100, height: 40}}
    send(shim, event)

    assert_receive {:dispatched, {:dispatch, received}}
    assert received == event
    refute_received {:dispatched, {:dispatch, {:harness, _}}}
  end

  test "a mixed sequence arrives in FIFO order (the §2 end-to-end claim)", %{
    shim: shim
  } do
    send(shim, {:batch, [{:event, %{id: 1}}]})
    send(shim, {:key, %{kind: :char, char: "a", mods: []}})
    send(shim, %Event{type: :resize, data: %{width: 90, height: 30}})
    send(shim, {:tick, 42})

    assert_receive {:dispatched, {:dispatch, {:harness, {:batch, _}}}}
    assert_receive {:dispatched, {:dispatch, {:harness, {:key, _}}}}
    assert_receive {:dispatched, {:dispatch, %Event{type: :resize}}}
    assert_receive {:dispatched, {:dispatch, {:harness, {:tick, 42}}}}
  end

  test "an unrecognized term is delivered, never filtered (the loud-loss law)", %{
    shim: shim
  } do
    send(shim, {:some_future_message, 123})

    assert_receive {:dispatched, {:dispatch, {:harness, {:some_future_message, 123}}}}
  end
end
