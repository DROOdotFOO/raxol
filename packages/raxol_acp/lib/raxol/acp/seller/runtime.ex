defmodule Raxol.ACP.Seller.Runtime do
  @moduledoc """
  Subscribes to the configured `Raxol.ACP.Seller.Backend` and forwards
  every `{:acp_event, event}` message to `Raxol.ACP.Seller.Queue`.

  Thin by design: the Runtime is just the bridge between an asynchronous
  message source (the Backend) and the dispatch layer (the Queue). It
  does not interpret events. If the Backend dies, `Seller.Supervisor`'s
  `:rest_for_one` strategy restarts the Runtime too, which re-subscribes
  on its next `init/1`.

  ## Configuration

  The Backend module is selected by:

      config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.InMemory

  ## Telemetry

  - `[:raxol, :acp, :seller, :runtime, :event_received]` -- every event
    delivered to the Runtime, before being forwarded to the Queue.
    Metadata: `%{type, job_id}` (job_id may be `nil` for events that
    don't carry one).
  """

  use GenServer

  alias Raxol.ACP.Seller.{Backend, Queue}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Return the backend module the Runtime subscribed to."
  @spec backend() :: module()
  def backend, do: GenServer.call(__MODULE__, :backend)

  @impl true
  def init(opts) do
    backend =
      Keyword.get(opts, :backend) ||
        Application.get_env(:raxol_acp, :seller_backend) ||
        raise """
        raxol_acp: no seller backend configured. Set one of:

          config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.InMemory
          config :raxol_acp, seller_backend: Raxol.ACP.Seller.Backend.WebSocket
        """

    :ok = Backend.subscribe(backend, self())

    {:ok, %{backend: backend}}
  end

  @impl true
  def handle_call(:backend, _from, state), do: {:reply, state.backend, state}

  @impl true
  def handle_info({:acp_event, event}, state) do
    :telemetry.execute(
      [:raxol, :acp, :seller, :runtime, :event_received],
      %{},
      %{type: Map.get(event, :type), job_id: Map.get(event, :job_id)}
    )

    Queue.dispatch(event)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
