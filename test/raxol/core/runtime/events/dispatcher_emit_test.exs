defmodule Raxol.Core.Runtime.Events.DispatcherEmitTest do
  @moduledoc """
  Keystone-emit tests: proves the Dispatcher publishes a neutral event to
  `Raxol.Core.Runtime.EmitBus` at BOTH model-fold sites. The async
  command-result path used to update the model silently (the emits-nothing
  bug); it now emits.
  """
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.EmitBus
  alias Raxol.Core.Runtime.Events.Dispatcher

  @session_id "sess-emit-test"

  defmodule EmitMockApp do
    @behaviour Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{count: 0}

    @impl true
    def update(_msg, model), do: {%{model | count: model.count + 1}, []}

    @impl true
    def view(_model), do: []

    @impl true
    def handle_event(_), do: :ok
    @impl true
    def handle_message(_, _), do: :ok
    @impl true
    def handle_tick(_), do: :ok
    @impl true
    def subscriptions(_), do: []
    @impl true
    def terminate(_, _), do: :ok
  end

  setup do
    case Raxol.Core.UserPreferences.start_link(
           name: Raxol.Core.UserPreferences,
           test_mode?: true
         ) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    ensure_registry(:raxol_event_subscriptions, :duplicate)
    ensure_registry(EmitBus.registry_name(), :duplicate)

    table = :"cmd_reg_#{System.unique_integer([:positive])}"
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])

    initial_state = %{
      app_module: EmitMockApp,
      model: %{count: 0},
      runtime_pid: self(),
      width: 80,
      height: 24,
      focused: true,
      debug_mode: false,
      plugin_manager: nil,
      command_registry_table: table,
      session_id: @session_id
    }

    {:ok, dispatcher} = Dispatcher.start_link(self(), initial_state, name: nil)

    on_exit(fn ->
      if Process.alive?(dispatcher), do: GenServer.stop(dispatcher)
    end)

    EmitBus.subscribe(@session_id)

    %{dispatcher: dispatcher}
  end

  test "process_command_result publishes an ephemeral :command_result event",
       %{dispatcher: dispatcher} do
    # Drive the previously-blind async fold site.
    send(dispatcher, {:command_result, {:llm_chunk, "hello"}})

    assert_receive {:emit_bus, @session_id, event}, 1_000
    assert event.family == :loop
    assert event.type == :command_result
    assert event.tier == :ephemeral
    assert is_integer(event.ts)
    assert event.payload.message == {:command_result, {:llm_chunk, "hello"}}
  end

  test "an agent-message turn brackets a durable :app_update with turn_started/turn_completed",
       %{dispatcher: dispatcher} do
    # agent_message casts are one turn: turn_started -> app_update -> turn_completed,
    # all durable and sharing one minted turn_id.
    GenServer.cast(dispatcher, {:dispatch, {:agent_message, :peer, :ping}})

    assert_receive {:emit_bus, @session_id, %{type: :turn_started} = started},
                   1_000

    assert_receive {:emit_bus, @session_id, %{type: :app_update} = updated},
                   1_000

    assert_receive {:emit_bus, @session_id,
                    %{type: :turn_completed} = completed},
                   1_000

    assert Enum.all?([started, updated, completed], &(&1.family == :loop))
    assert Enum.all?([started, updated, completed], &(&1.tier == :durable))

    assert is_binary(started.turn_id)
    assert started.turn_id == updated.turn_id
    assert started.turn_id == completed.turn_id
  end

  test "a tagged async command_result carries its ORIGINATING turn's id, not emit-time state",
       %{dispatcher: dispatcher} do
    # Cross-turn contamination regression: an async command dispatched in turn
    # N snapshots N's turn_id into its context; its late result echoes it back
    # as {:command_result, msg, %{turn_id: ...}}. Run a LATER full turn first,
    # then deliver turn N's leftover delta — it must be stamped with N's id,
    # not the later turn's and not nil.
    GenServer.cast(dispatcher, {:dispatch, {:agent_message, :peer, :ping}})

    assert_receive {:emit_bus, @session_id, %{type: :turn_completed} = later},
                   1_000

    send(
      dispatcher,
      {:command_result, {:llm_chunk, "late"}, %{turn_id: "turn-N"}}
    )

    assert_receive {:emit_bus, @session_id, %{type: :command_result} = delta},
                   1_000

    assert delta.tier == :ephemeral
    assert delta.turn_id == "turn-N"
    refute delta.turn_id == later.turn_id
  end

  test "an UNtagged command_result between turns is attributed to no turn (nil), never a stale one",
       %{dispatcher: dispatcher} do
    GenServer.cast(dispatcher, {:dispatch, {:agent_message, :peer, :ping}})
    assert_receive {:emit_bus, @session_id, %{type: :turn_completed}}, 1_000

    send(dispatcher, {:command_result, {:llm_chunk, "untagged"}})

    assert_receive {:emit_bus, @session_id, %{type: :command_result} = delta},
                   1_000

    assert is_nil(delta.turn_id)
  end

  test "no session_id means no emit (terminal apps stay silent)" do
    ensure_registry(:raxol_event_subscriptions, :duplicate)
    ensure_registry(EmitBus.registry_name(), :duplicate)

    table = :"cmd_reg_#{System.unique_integer([:positive])}"
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        self(),
        %{
          app_module: EmitMockApp,
          model: %{count: 0},
          runtime_pid: self(),
          width: 80,
          height: 24,
          focused: true,
          debug_mode: false,
          plugin_manager: nil,
          command_registry_table: table
          # no session_id
        },
        name: nil
      )

    on_exit(fn ->
      if Process.alive?(dispatcher), do: GenServer.stop(dispatcher)
    end)

    # Subscribe to a wildcard is impossible; subscribe to the id the app would
    # have used and confirm nothing arrives.
    EmitBus.subscribe(@session_id)
    send(dispatcher, {:command_result, {:llm_chunk, "silent"}})

    refute_receive {:emit_bus, _, _}, 300
  end

  defp ensure_registry(name, keys) do
    case Registry.start_link(keys: keys, name: name) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end
  end
end
