defmodule Raxol.Console.Inbound do
  @moduledoc """
  The authorized entry point for inbound chat events.

  A Console has no feed loop of its own. Adapters translate (`normalize_event/1`)
  and `Raxol.Gateway.SessionRouter` routes, but something has to pump one into
  the other, and that something belongs to the deployment: which transport it
  polls, how it handles backpressure, and where it logs are all its business.

  What is NOT its business is deciding who may open a session. `route/3` is that
  decision plus the routing, in one call, so a deployment's feed cannot wire up
  the second half and forget the first:

      Raxol.Telegram.UpdatePoller.start_link(
        conn: conn,
        on_update: fn raw ->
          with {:ok, route, event} <- Raxol.Telegram.GatewayAdapter.normalize_event(raw) do
            Raxol.Console.Inbound.route(MyConsole, route, event)
          end
        end
      )

  `MyConsole` is the same `:name` the runtime booted under, which is what the
  Pairing server and the router are named after.

  ## Why this exists

  `Raxol.Gateway.Pairing.authorize/2` was documented across five adapters as
  something the feed loop calls before routing. It was never enforced anywhere,
  and Console -- having no feed loop -- never got the call site. The server ran,
  denied nothing, and every inbound event got a session. See GitHub #884.

  ## This is not the only enforcement point

  A gate that only works when you remember to call it is the bug above with a
  new name, so `Raxol.Console.Boot` also hands the router an `:authorize`
  function over the same Pairing server. A deployment that calls
  `Raxol.Gateway.SessionRouter.route/3` directly gets the same decision.

  What this adds is the answer without a round trip: a denial here never touches
  the router, and it carries the console's own telemetry and log line. Skipping
  it costs an extra `GenServer.call` per denied event and loses that signal --
  it does not cost the check.

  ## Authorization posture

  `route/3` always consults `Pairing`. An open Console is open because its
  Pairing server was seeded to allow the connected platforms, not because
  anything skipped a check -- so there is one code path in both postures, and
  `:sys.get_state` on the Pairing server shows the truth. The seeds are start
  options, so the posture survives a Pairing restart; runtime DM pairings do
  not. See `Raxol.Console.RuntimeConfig.build/2` for configuring it.

  ## Telemetry

    * `[:raxol_console, :inbound, :denied]` -- metadata `%{console, key, platform,
      user_id}`. The only signal that someone was turned away; a denial is
      otherwise invisible, since `route/3` returns to a feed loop that is free to
      discard it.
  """

  require Logger

  alias Raxol.Gateway.{Pairing, Route, SessionRouter}

  @doc """
  Authorize `route` and, if allowed, deliver `event` to its session.

  Returns `SessionRouter.route/3`'s own result when allowed -- `:ok`, or
  `{:error, :max_sessions | :rate_limited}` -- and `{:error, :unauthorized}` when
  not. Note that `:ok` carries `route/3`'s meaning: the event was accepted for
  delivery, not that it was served.
  """
  @spec route(atom(), Route.t(), term()) :: :ok | {:error, term()}
  def route(base \\ Raxol.Console, %Route{} = route, event) do
    case Pairing.authorize(pairing_name(base), route) do
      :allow ->
        SessionRouter.route(router_name(base), route, event)

      :deny ->
        deny(base, route)
        {:error, :unauthorized}
    end
  end

  @doc """
  Whether `route` would be authorized, without routing anything.

  For a feed that wants to answer an unpaired sender (with a pairing code, say)
  rather than drop them silently.
  """
  @spec authorized?(atom(), Route.t()) :: boolean()
  def authorized?(base \\ Raxol.Console, %Route{} = route),
    do: Pairing.authorize(pairing_name(base), route) == :allow

  @doc "The Pairing server name for a Console booted under `base`."
  @spec pairing_name(atom()) :: atom()
  def pairing_name(base \\ Raxol.Console), do: :"#{base}.pairing"

  @doc "The `SessionRouter` name for a Console booted under `base`."
  @spec router_name(atom()) :: atom()
  def router_name(base \\ Raxol.Console), do: :"#{base}.router"

  defp deny(base, route) do
    :telemetry.execute(
      [:raxol_console, :inbound, :denied],
      %{system_time: System.system_time()},
      %{
        console: base,
        key: Route.key(route),
        platform: route.platform,
        user_id: route.user_id
      }
    )

    Logger.info("#{base}: denied unauthorized #{route.platform} chat #{Route.key(route)}")
  end
end
