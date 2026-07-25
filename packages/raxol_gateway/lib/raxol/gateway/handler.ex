defmodule Raxol.Gateway.Handler do
  @moduledoc """
  The per-chat logic a `Raxol.Gateway.Session` runs.

  A handler is initialized once per chat with its route, then handles each
  inbound event, optionally returning a rendered message to deliver back.
  Any module satisfying `init/2` and `handle_event/2` works;
  `Raxol.Gateway.Handler.Agent` (agent conversations) and
  `Raxol.Gateway.Handler.Lifecycle` (a full TEA app under
  `environment: :gateway`) ship with the package.

  The optional `terminate/2` runs when the session stops cleanly (idle
  timeout, explicit stop) -- the hook for a handler that owns linked
  processes, since a session's `:normal` exit does not propagate over
  links. It is best-effort: a killed session never reaches it.
  """

  alias Raxol.Gateway.Route

  @type state :: term()
  @type event :: term()
  @type rendered :: term()

  @callback init(Route.t(), keyword()) :: {:ok, state()} | {:error, term()}
  @callback handle_event(event(), state()) ::
              {:reply, rendered(), state()} | {:noreply, state()}
  @callback terminate(reason :: term(), state()) :: term()

  @optional_callbacks terminate: 2
end
