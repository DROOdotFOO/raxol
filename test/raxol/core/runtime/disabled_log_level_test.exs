defmodule Raxol.Core.Runtime.DisabledLogLevelTest do
  # Every event the Dispatcher takes and every frame the Engine draws must
  # not pay for log messages nobody will see. `Raxol.Core.Runtime.Log`'s level
  # functions evaluate their argument before the level check, so a dump of
  # the model, the view or the event in one of them runs at every level; over
  # SSH that is once per input event. The model, the event, the view and the
  # command below each carry an `InspectProbe`, which reports each time it is
  # inspected, and the Logger is at :emergency.
  #
  # async: false because the Logger level is node-wide.
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.Event
  alias Raxol.Core.Runtime.Events.Dispatcher
  alias Raxol.Core.Runtime.Rendering.Engine

  defmodule InspectProbe do
    @moduledoc false
    defstruct [:owner, :tag]

    def new(tag), do: %__MODULE__{owner: self(), tag: tag}

    defimpl Inspect do
      def inspect(%{owner: owner, tag: tag}, _opts) do
        send(owner, {:inspected, tag})
        "#InspectProbe<" <> Kernel.inspect(tag) <> ">"
      end
    end

    # Lets `update/2` return a probe as a command, which the Dispatcher runs.
    defimpl Raxol.Core.Runtime.Directive.Executor do
      def execute(_probe, _context), do: :ok
    end
  end

  defmodule ProbeApp do
    @moduledoc false
    @behaviour Raxol.Core.Runtime.Application

    @impl true
    def init(_context), do: %{}

    @impl true
    def update(%Event{data: %{probe: probe}}, model),
      do: {Map.put(model, :keys, Map.get(model, :keys, 0) + 1), [probe]}

    def update({:agent_message, _from, _payload}, model),
      do:
        {Map.put(
           model,
           :agent_messages,
           Map.get(model, :agent_messages, 0) + 1
         ), []}

    def update(_msg, model), do: {model, []}

    @impl true
    def view(model) do
      # The probe rides in the style, which layout carries into every
      # positioned element.
      Raxol.View.Components.text(
        content: "keys: #{Map.get(model, :keys, 0)}",
        style: %{probe: model.probe}
      )
    end

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

    for name <- [
          :raxol_event_subscriptions,
          Raxol.Core.Runtime.EmitBus.registry_name()
        ] do
      case Registry.start_link(keys: :duplicate, name: name) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
      end
    end

    table = :"cmd_reg_#{System.unique_integer([:positive])}"
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])

    # Supervised, not linked: ExUnit sends :test_finished before the test
    # process exits and starts on_exit right away, so a linked server can
    # die between an on_exit's `Process.alive?` and its `GenServer.stop`.
    # ExUnit stops supervised children before any on_exit runs.
    dispatcher =
      start_supervised!(%{
        id: Dispatcher,
        start:
          {Dispatcher, :start_link,
           [
             self(),
             %{
               app_module: ProbeApp,
               model: %{probe: InspectProbe.new(:model)},
               runtime_pid: self(),
               width: 40,
               height: 10,
               focused: true,
               # The app's debug mode logs every event it dispatches.
               debug_mode: true,
               plugin_manager: nil,
               command_registry_table: table
             },
             [name: nil]
           ]}
      })

    level = Logger.level()
    Logger.configure(level: :emergency)

    on_exit(fn -> Logger.configure(level: level) end)

    %{dispatcher: dispatcher}
  end

  test "dispatching an event dumps nothing while logging is disabled",
       %{dispatcher: dispatcher} do
    event =
      Event.new(:key, %{key: :char, char: "a", probe: InspectProbe.new(:event)})

    assert :ok = GenServer.call(dispatcher, {:dispatch, event})
    assert {:ok, %{keys: 1}} = GenServer.call(dispatcher, :get_model)
    refute_received {:inspected, _}
  end

  test "an agent message dumps nothing while logging is disabled",
       %{dispatcher: dispatcher} do
    message = {:agent_message, :peer, InspectProbe.new(:agent_message)}

    assert :ok = GenServer.call(dispatcher, {:dispatch, message})
    assert {:ok, %{agent_messages: 1}} = GenServer.call(dispatcher, :get_model)
    refute_received {:inspected, _}
  end

  test "rendering a frame dumps nothing while logging is disabled",
       %{dispatcher: dispatcher} do
    engine =
      start_supervised!(
        {Engine,
         name: :"disabled_log_engine_#{System.unique_integer([:positive])}",
         app_module: ProbeApp,
         dispatcher_pid: dispatcher,
         width: 40,
         height: 10,
         environment: :agent}
      )

    # The frame the runtime draws after every update, then the one
    # `Raxol.Headless` draws for a screenshot. The engine takes the cast
    # before the call, and each process's probe reports reach this one ahead
    # of that process's own reply, so the two calls are the fence.
    GenServer.cast(engine, :render_frame)
    assert {:ok, frame} = GenServer.call(engine, :render_frame_sync_buffer)
    assert {:ok, _model} = GenServer.call(dispatcher, :get_model)

    assert Raxol.Headless.TextCapture.capture(frame) =~ "keys: 0"
    refute_received {:inspected, _}
  end
end
