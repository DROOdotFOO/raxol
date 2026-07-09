defmodule Raxol.Terminal.DriverMock do
  @moduledoc """
  A simple mock implementation of the Terminal Driver for testing.

  This mock provides the minimal functionality needed for tests to run
  when not attached to a real TTY.
  """

  use GenServer
  # Removed undefined @behaviour Raxol.Terminal.Driver.Behaviour

  alias Raxol.Core.Events.Event

  defmodule State do
    @moduledoc false
    defstruct dispatcher_pid: nil
  end

  # --- Public API ---

  @doc """
  Starts the mock driver GenServer.
  """
  # Removed @impl for undefined behaviour
  def start_link(dispatcher_pid) do
    GenServer.start_link(__MODULE__, dispatcher_pid, name: __MODULE__)
  end

  # --- GenServer callbacks ---

  @impl GenServer
  def init(dispatcher_pid) do
    Raxol.Core.Runtime.Log.info("Starting DriverMock for tests")

    # Register with dispatcher if provided
    case dispatcher_pid do
      nil -> :ok
      pid -> send(pid, {:register_driver, self()})
    end

    {:ok, %State{dispatcher_pid: dispatcher_pid}}
  end

  @impl GenServer
  def handle_cast({:test_input, input_data}, state) do
    # Parse the test input and send to dispatcher
    event = parse_test_input(input_data)

    case state.dispatcher_pid do
      nil -> :ok
      pid -> GenServer.cast(pid, {:event, event})
    end

    {:noreply, state}
  end

  def handle_cast(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:register_dispatcher, pid}, state) when is_pid(pid) do
    Raxol.Core.Runtime.Log.info(
      "DriverMock: Registering dispatcher PID: #{inspect(pid)}"
    )

    {:noreply, %{state | dispatcher_pid: pid}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private functions ---

  defp parse_test_input(<<17>>) do
    # Ctrl+Q
    %Event{
      type: :key,
      data: %{
        key: :ctrl_q,
        char: nil,
        modifiers: [:ctrl]
      }
    }
  end

  defp parse_test_input(input_data) do
    Raxol.Core.Runtime.Log.warning(
      "DriverMock: Unknown test input: #{inspect(input_data)}"
    )

    %Event{
      type: :unknown_test_input,
      data: %{raw: input_data}
    }
  end
end
