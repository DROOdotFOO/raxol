defmodule Raxol.ACP.Xochi.SolverApplication do
  @moduledoc """
  Production runtime for the `xochi_cross_chain_transfer` storefront: authenticates
  against Virtuals, streams jobs, and settles each funded job by relaying the
  buyer's pre-signed Xochi intent.

  Supervises five children (`:rest_for_one`, so an `Auth`/`Agent` crash restarts
  everything downstream):

    1. `Raxol.ACP.Auth` -- EIP-712 auth against the Virtuals server.
    2. `Raxol.ACP.Agent` -- REST (`JobApi.HTTP`) + SSE (`Transport.SSE`) job
       orchestration, role `:provider`.
    3. `Raxol.ACP.Xochi.SolverAgent` -- per-job driver; on `job.funded` it runs the
       storefront relay `settle_fn` and submits the deliverable on-chain.
    4. an internal stream starter -- calls `Agent.start_stream/1` last, so the
       solver is subscribed before the first SSE event arrives.
    5. `Raxol.ACP.Xochi.Heartbeat` -- periodic liveness log + telemetry, last so its
       crash restarts nothing above it.

  The `settle_fn` is a pure relay (`Raxol.ACP.Xochi.Settler.build/1`, `:xochi_config`
  only): it never re-signs, so no signing wallet is wired here. raxol earns the
  storefront fee (`XOCHI_FEE_BPS`); the buyer's funds move solver-to-recipient via
  Xochi.

  ## Enabling

  Opt-in, mirroring `:seller_enabled`. Never starts under `MIX_ENV=test`.

      config :raxol_acp, xochi_solver_enabled: true

  `RaxolAcp.Application` starts it when the flag is set; an operator embedding raxol
  may instead add `Raxol.ACP.Xochi.SolverApplication` to their own supervision tree.

  ## Required environment

  | Var | Purpose |
  |---|---|
  | `RAXOL_ACP_AGENT_PRIVATE_KEY` | 32-byte hex, solver EOA. Signs auth + on-chain submit/complete. |
  | `RAXOL_ACP_EVALUATOR` | Address allowed to call `complete`/`reject`. |
  | `XOCHI_BASE_URL` | Xochi worker (`https://api.xochi.fi` prod, `https://api-stg.xochi.fi` staging). The worker calls Riddler internally; do not point at `riddler.axol.io/xochi/*`. |
  | `XOCHI_AUTH_TOKEN` | Xochi worker Member / agent-service token (`Authorization: Bearer`). Not a Riddler token. |

  Optional: `RAXOL_ACP_RPC_URL` (default `Chain.mainnet/0` rpc_url), `XOCHI_FEE_BPS`
  (default `50` -> 0.5%).
  """

  use Supervisor

  alias Raxol.ACP
  alias Raxol.ACP.Xochi.{Heartbeat, Settler, SolverAgent}

  # Base mainnet. The storefront authenticates and submits on Base; the transferred
  # funds move across chains inside the buyer's Xochi intent, off the ACP ledger.
  @chain_id 8453

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Whether the solver runtime should auto-start. Off by default; `RaxolAcp.Application`
  only runs outside `MIX_ENV=test` (the package sets `:mod` only for non-test), so
  this flag alone gates auto-start.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:raxol_acp, :xochi_solver_enabled, false)

  @impl true
  def init(_opts) do
    chain = ACP.Chain.mainnet()

    # Secret-handling invariant -- KEEP THIS if you reuse the solver pattern. The raw
    # key exists only as this transient local; `JSONRPC.new/1` immediately wraps it in a
    # `Raxol.ACP.Secret` before it enters the provider config. That wrapper redacts under
    # `Inspect`, so the key never renders into an OTP/SASL crash report even though the
    # provider is passed as a supervised child's start arg (a plain unwrapped key here
    # WOULD leak on any boot-time child crash -- see Secret's moduledoc). Do not log or
    # interpolate `private_key`; only `Secret.reveal/1` at a sign call site unwraps it.
    private_key = decode_pk!(System.fetch_env!("RAXOL_ACP_AGENT_PRIVATE_KEY"))
    rpc_url = System.get_env("RAXOL_ACP_RPC_URL", chain.rpc_url)
    server_url = chain.acp_server_url

    provider =
      ACP.ProviderAdapter.JSONRPC.new(chains: %{@chain_id => rpc_url}, private_key: private_key)

    wallet_address = ACP.ProviderAdapter.get_address(provider)

    api = ACP.JobApi.HTTP.new(auth: auth_name(), server_url: server_url, chain_ids: [@chain_id])
    transport = ACP.Transport.SSE.new(auth: auth_name(), server_url: server_url)

    # One Xochi client config, shared by the accept-time intent derivation (the
    # SolverAgent reads the authoritative amount by intent id) and the settle
    # relay. Without it on the agent, every job would fail closed at budget time.
    xochi_config = %{
      base_url: System.fetch_env!("XOCHI_BASE_URL"),
      auth_token: System.fetch_env!("XOCHI_AUTH_TOKEN")
    }

    settle_fn = Settler.build(xochi_config: xochi_config)

    children = [
      Supervisor.child_spec(
        {ACP.Auth,
         provider: provider, server_url: server_url, chain_id: @chain_id, name: auth_name()},
        id: :auth
      ),
      Supervisor.child_spec(
        {ACP.Agent,
         provider: provider,
         transport: transport,
         api: api,
         wallet_address: wallet_address,
         supported_chain_ids: [@chain_id],
         default_role: :provider,
         name: agent_name()},
        id: :agent
      ),
      Supervisor.child_spec(
        {SolverAgent,
         agent: agent_name(),
         provider: provider,
         wallet_address: wallet_address,
         evaluator_address: System.fetch_env!("RAXOL_ACP_EVALUATOR"),
         chain_id: @chain_id,
         acp_core_address: chain.acp_core_address,
         fee_bps: fee_bps(),
         settle_fn: settle_fn,
         xochi_config: xochi_config,
         name: solver_name()},
        id: :solver
      ),
      # Start the SSE stream last, after the solver has subscribed.
      %{
        id: :stream_starter,
        start: {Task, :start_link, [fn -> :ok = ACP.Agent.start_stream(agent_name()) end]},
        restart: :transient
      },
      # Liveness heartbeat -- last so a crash here restarts nothing above it under
      # :rest_for_one. Emits a periodic log + telemetry event so external monitoring can
      # tell a live-but-idle solver from a wedged one (no inbound port for a fly check).
      {Heartbeat, name: heartbeat_name()}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp fee_bps, do: String.to_integer(System.get_env("XOCHI_FEE_BPS", "50"))

  defp auth_name, do: Module.concat(__MODULE__, Auth)
  defp agent_name, do: Module.concat(__MODULE__, Agent)
  defp solver_name, do: Module.concat(__MODULE__, Solver)
  defp heartbeat_name, do: Module.concat(__MODULE__, Heartbeat)

  defp decode_pk!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_pk!(hex), do: Base.decode16!(hex, case: :mixed)
end
