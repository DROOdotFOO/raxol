defmodule Raxol.Gateway.Supervisor do
  @moduledoc """
  The gateway daemon: pairing, a session `DynamicSupervisor`, and the router.

  Strategy is `:rest_for_one`, so the router (which references the sessions
  supervisor) restarts if that supervisor dies.

  ## Options

    * `:handler` (required) -- `{module, opts}` the sessions run
    * `:adapter` / `:deliver` -- how outbound is delivered (see `SessionRouter`)
    * `:router_name` -- the router's registered name (default
      `Raxol.Gateway.SessionRouter`)
    * `:pairing_name` -- the pairing server's name (default
      `Raxol.Gateway.Pairing`)
    * `:sessions_sup` -- the session supervisor's name (default
      `Raxol.Gateway.SessionSup`)
    * `:authorize` -- `(Route.t() -> :allow | :deny)` the router consults before
      starting a session or delivering an event (see `SessionRouter`). Unset
      allows everything.
    * `:router` / `:pairing` -- extra opts merged into those children

  `:rest_for_one` also means a Pairing crash restarts the sessions and the
  router behind it. That is deliberate: sessions authorized under the pre-crash
  posture should not outlive it. (The router's `:authorize` closure captures a
  NAME, so it would survive on its own -- the restart is about the sessions.)
  Pass the posture as `:pairing` seed opts rather than calling the running
  server, so the restart rebuilds it -- see `Raxol.Gateway.Pairing`.

  The corollary is that Pairing sits on the hot path of every event with the
  blast radius of every session behind it, so it must not crash on wire input.
  `authorize/2` fails closed on a malformed route rather than raising.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    sessions_sup = Keyword.get(opts, :sessions_sup, Raxol.Gateway.SessionSup)

    router_opts =
      [
        name: Keyword.get(opts, :router_name, Raxol.Gateway.SessionRouter),
        handler: Keyword.fetch!(opts, :handler),
        sessions_sup: sessions_sup
      ]
      |> put_if(:adapter, Keyword.get(opts, :adapter))
      |> put_if(:deliver, Keyword.get(opts, :deliver))
      |> put_if(:authorize, Keyword.get(opts, :authorize))
      |> Keyword.merge(Keyword.get(opts, :router, []))

    pairing_opts =
      [name: Keyword.get(opts, :pairing_name, Raxol.Gateway.Pairing)]
      |> Keyword.merge(Keyword.get(opts, :pairing, []))

    children = [
      {Raxol.Gateway.Pairing, pairing_opts},
      {DynamicSupervisor, name: sessions_sup, strategy: :one_for_one},
      {Raxol.Gateway.SessionRouter, router_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)
end
