defmodule Raxol.Gateway.Session do
  @moduledoc """
  One process per chat.

  A session is created by `Raxol.Gateway.SessionRouter` for a `Route` and runs a
  `Raxol.Gateway.Handler`. Each inbound event is dispatched to the handler; a
  `{:reply, rendered, state}` result is delivered back through the session's
  `:deliver` function (the router builds it from the adapter and connection). A
  session stops itself after `:idle_timeout` ms of inactivity.

  ## Options

    * `:route` (required) -- the `Raxol.Gateway.Route` this session serves
    * `:handler` (required) -- `{module, opts}` implementing `Gateway.Handler`
    * `:deliver` -- `(Route.t(), rendered -> any())`, default a no-op
    * `:idle_timeout` -- ms before the session stops (default 10 minutes)
  """

  use GenServer

  alias Raxol.Gateway.Route

  @default_idle_timeout 10 * 60 * 1000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Dispatch an inbound event to the session."
  @spec dispatch(GenServer.server(), term()) :: :ok
  def dispatch(server, event), do: GenServer.cast(server, {:event, event})

  @doc "The route this session serves."
  @spec route(GenServer.server()) :: Route.t()
  def route(server), do: GenServer.call(server, :route)

  @impl true
  def init(opts) do
    route = Keyword.fetch!(opts, :route)
    {handler_mod, handler_opts} = Keyword.fetch!(opts, :handler)

    case handler_mod.init(route, handler_opts) do
      {:ok, handler_state} ->
        state = %{
          route: route,
          handler_mod: handler_mod,
          handler_state: handler_state,
          deliver: Keyword.get(opts, :deliver, fn _route, _rendered -> :ok end),
          idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout),
          timer: nil
        }

        {:ok, arm_timer(state)}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:route, _from, state), do: {:reply, state.route, state}

  @impl true
  def handle_cast({:event, event}, state) do
    case state.handler_mod.handle_event(event, state.handler_state) do
      {:reply, rendered, handler_state} ->
        state.deliver.(state.route, rendered)
        {:noreply, arm_timer(%{state | handler_state: handler_state})}

      {:noreply, handler_state} ->
        {:noreply, arm_timer(%{state | handler_state: handler_state})}
    end
  end

  @impl true
  def handle_info(:idle_timeout, state), do: {:stop, :normal, state}
  def handle_info(_msg, state), do: {:noreply, state}

  defp arm_timer(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :idle_timeout, state.idle_timeout)}
  end
end
