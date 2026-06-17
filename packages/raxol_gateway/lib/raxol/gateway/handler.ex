defmodule Raxol.Gateway.Handler do
  @moduledoc """
  The per-chat logic a `Raxol.Gateway.Session` runs.

  A handler is initialized once per chat with its route, then handles each
  inbound event, optionally returning a rendered message to deliver back. A
  `Lifecycle`-backed handler (running a TEA app under `environment: :gateway`) is
  a future implementation; any module satisfying these two callbacks works.
  """

  alias Raxol.Gateway.Route

  @type state :: term()
  @type event :: term()
  @type rendered :: term()

  @callback init(Route.t(), keyword()) :: {:ok, state()} | {:error, term()}
  @callback handle_event(event(), state()) ::
              {:reply, rendered(), state()} | {:noreply, state()}
end
