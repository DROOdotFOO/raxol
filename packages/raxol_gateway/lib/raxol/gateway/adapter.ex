defmodule Raxol.Gateway.Adapter do
  @moduledoc """
  The contract every platform implements to plug into the gateway.

  An adapter owns only platform I/O and translation. Routing, sessions, auth, and
  history live in the gateway, so adding a platform is implementing these five
  callbacks:

    * `connect/1` -- open the platform connection, returning an opaque handle.
    * `disconnect/1` -- close it.
    * `platform/0` -- the platform's atom id (`:telegram`, `:discord`, ...).
    * `normalize_event/1` -- map a raw inbound payload to `{:ok, route, event}`
      or `:ignore`. `event` is whatever a `Raxol.Gateway.Handler` expects.
    * `send_message/3` -- deliver a rendered outbound message to a route.

  `Raxol.Gateway.Adapter.InMemory` is a reference implementation.

  ## Stability

  Frozen: these five callbacks are the stable contract every platform
  adapter builds against, including adapters that live outside this repo.
  Additions must be optional callbacks; existing callbacks do not change
  shape.
  """

  alias Raxol.Gateway.Route

  @type conn :: term()
  @type config :: term()
  @type raw :: term()
  @type rendered :: term()
  @type event :: term()

  @callback connect(config()) :: {:ok, conn()} | {:error, term()}
  @callback disconnect(conn()) :: :ok
  @callback platform() :: atom()
  @callback normalize_event(raw()) :: {:ok, Route.t(), event()} | :ignore
  @callback send_message(conn(), Route.t(), rendered()) :: :ok | {:error, term()}
end
