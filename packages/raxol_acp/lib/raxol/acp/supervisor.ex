defmodule Raxol.ACP.Supervisor do
  @moduledoc """
  Top-level supervisor for the `raxol_acp` subsystem.

  ## Strategy

  `:rest_for_one` -- if a child earlier in the start order dies, all
  children after it are restarted too. This matters because:

  - The job registry must outlive any job server.
  - A persistent memo store crash means no job server can safely continue
    (memos would be lost on the next transition).
  - The seller WebSocket can crash and restart independently of jobs in
    flight.

  ## Children (v0.1)

  - `Raxol.ACP.Job.Registry` -- per-job process lookup
  - `Raxol.ACP.Wallet.NonceServer` -- serializes EVM nonce assignment for
    the umbrella seller wallet (default-named instance)
  - `Raxol.ACP.Offering.Registry` -- declared offerings (ETS-backed)
  - `Raxol.ACP.Job.Store` -- ETS-backed memo persistence (jobs hydrate
    from here on transient restart)
  - `Raxol.ACP.Job.Supervisor` -- DynamicSupervisor for per-job processes
  - `Raxol.ACP.Seller.Supervisor` -- only when
    `config :raxol_acp, seller_enabled: true`. Owns the Backend, the
    Queue, and the Runtime. Buyer-only deployments leave it off.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    initial_nonce = Application.get_env(:raxol_acp, :initial_nonce, 0)

    base = [
      Raxol.ACP.Job.Registry,
      {Raxol.ACP.Wallet.NonceServer, [initial_nonce: initial_nonce]},
      Raxol.ACP.Offering.Registry,
      Raxol.ACP.Job.Store,
      Raxol.ACP.Job.Supervisor
    ]

    children =
      if Application.get_env(:raxol_acp, :seller_enabled, false) do
        base ++ [Raxol.ACP.Seller.Supervisor]
      else
        base
      end

    Supervisor.init(children,
      strategy: :rest_for_one,
      # Defaults are 3 in 5s. Tests recycle Job.Store and Seller.*
      # for config rotation (DETS path swap, wallet swap, etc.); a
      # handful of recycles in setup blocks would otherwise blow
      # through the default budget and tear down the supervisor
      # tree mid-suite. Lift to a level that's still a hard fail in
      # production (100 restarts/5s implies a real bug) but absorbs
      # test churn.
      max_restarts: 100,
      max_seconds: 5
    )
  end
end
