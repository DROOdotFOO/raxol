defmodule Raxol.Core.Runtime.Events.DispatcherHarnessIngressTest do
  @moduledoc """
  Unit U6-a of the harness TEA migration: the `{:dispatch, {:harness, msg}}`
  cast is the SessionPump's verbatim ingress -- msg reaches update/2
  unwrapped (Raxol.Harness.PumpContract §3), ahead of the generic
  `{:dispatch, event}` clause that would otherwise walk it through the
  event pipeline. These tests pin the two properties the frozen contract
  needs from this seam: verbatim delivery of a NON-Event term, and the
  model fold + render notification that every other raw-dispatch
  predecessor (agent_message, layout_recommendation) also produces.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Events.Dispatcher
  alias Raxol.Core.Runtime.Events.Dispatcher.State

  defmodule RecordingApp do
    @moduledoc false

    def subscribe(_model), do: []

    def update(message, model) do
      send(model.recorder, {:update_received, message})
      {%{model | folded: [message | model.folded]}, []}
    end
  end

  defp base_state do
    %State{
      runtime_pid: self(),
      app_module: RecordingApp,
      model: %{recorder: self(), folded: []},
      width: 80,
      height: 24,
      rendering_engine: self()
    }
  end

  test "a pump message reaches update/2 verbatim, envelope stripped" do
    # The shape is deliberately NOT an %Event{} and not a Bubbler-known
    # term: only the raw-dispatch path can deliver it intact.
    batch =
      {:batch,
       [
         {:event, %{id: 1, type: :turn_started, payload: %{}}},
         {:cadence_dropped, 2},
         {:malformed_event}
       ]}

    assert {:noreply, new_state} =
             Dispatcher.handle_manager_cast(
               {:dispatch, {:harness, batch}},
               base_state()
             )

    assert_received {:update_received, received}
    assert received == batch
    assert new_state.model.folded == [batch]
  end

  test "a folded pump message triggers the render notification" do
    # process_successful_update/2's :render_needed is what eventually casts
    # :render_frame at the Engine; the harness ingress must not bypass it.
    assert {:noreply, _new_state} =
             Dispatcher.handle_manager_cast(
               {:dispatch, {:harness, {:tick, 42}}},
               base_state()
             )

    assert_received :render_needed
  end

  test "keystroke-class messages fold in arrival order (FIFO preserved)" do
    # PumpContract §2's end-to-end claim, restated at this seam: two casts
    # arriving in order fold in order. The pump's own input-first receive
    # establishes the order; this GenServer's mailbox preserves it.
    state = base_state()

    {:noreply, state} =
      Dispatcher.handle_manager_cast(
        {:dispatch, {:harness, {:key, %{kind: :char, char: "a", mods: []}}}},
        state
      )

    {:noreply, state} =
      Dispatcher.handle_manager_cast(
        {:dispatch, {:harness, {:batch, [{:event, %{id: 2}}]}}},
        state
      )

    # RecordingApp prepends on fold, so [batch, key] here means the
    # keystroke folded FIRST -- arrival order preserved end-to-end.
    assert [{:batch, _}, {:key, %{kind: :char}}] = state.model.folded

    assert_received {:update_received, {:key, _}}
    assert_received {:update_received, {:batch, _}}
  end
end
