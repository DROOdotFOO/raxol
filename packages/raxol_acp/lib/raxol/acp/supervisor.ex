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

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
