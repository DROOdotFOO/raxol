defmodule Raxol.ACP.Xochi.TransferOffering do
  @moduledoc """
  ACP offering that sells Xochi cross-chain stablecoin transfers.

  A buyer's job requirement names a source chain, destination chain, token,
  amount, and its pre-signed Xochi intent bundle. `handle_request/2` accepts the
  job only when the corridor is settleable (a solver-fillable token on a
  supported chain); `handle_deliver/2` relays the buyer's signed intent through
  `Raxol.ACP.Xochi.Settler`
  (`Raxol.Payments.Protocols.Xochi.execute_signed/2`, then poll) -- raxol never
  signs the transfer -- and returns the intent id and settlement tx hashes for
  on-chain verification.

  The offering name is `"xochi_cross_chain_transfer"`, matching the marketplace
  metadata from `mix acp.register_offering`. When `:seller_enabled` is set,
  `Raxol.ACP.Seller.Supervisor` registers it on startup; otherwise call
  `register/0`.

  ## Settler configuration

  `handle_deliver/2` builds a `Raxol.ACP.Xochi.Settler` from:

      config :raxol_acp, :xochi_transfer_settler,
        xochi_config: %{base_url: "https://api.xochi.fi", auth_token: "..."},
        poll_timeout_ms: 120_000

  A `:settle_fn` (a one-arg function returning `{:ok, deliverable} | {:error,
  reason}`) may be given in place of the build options. With neither, delivery
  returns `{:error, {:settler_not_configured, missing}}` and the job expires.

  ## Supported corridors

  Corridors are gated by the live solver capability matrix
  (`Raxol.Payments.Xochi.Capabilities`, direction-aware), so new solver chains
  and tokens light up without a raxol redeploy. When the capabilities endpoint
  is unconfigured or unreachable the gate degrades to the static
  `Raxol.Payments.Assets` set (USDC/USDT/WETH on the six EVM chains) -- exactly
  the pre-capabilities behavior. Same-chain, malformed, non-positive-amount,
  per-chain-invalid-address, and unknown-token requests are rejected before
  escrow with machine-readable reasons.
  """

  use Raxol.ACP.Offering,
    name: "xochi_cross_chain_transfer",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.ACP.Xochi.CapacityLedger
  alias Raxol.ACP.Xochi.CorridorAllowlist
  alias Raxol.ACP.Xochi.Offering, as: Schema
  alias Raxol.ACP.Xochi.Settler
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Xochi.Capabilities

  @settler_required [:xochi_config]

  @impl true
  def requirements_schema, do: Schema.requirement_schema()

  @impl true
  def deliverables_schema, do: Schema.deliverable_schema()

  @impl true
  def handle_request(req, ctx) do
    with :ok <- validate_requirement(req),
         :ok <- reserve_capacity(req, ctx) do
      {:accept, req}
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  @impl true
  def handle_deliver(req, ctx) do
    case do_deliver(req) do
      {:deliver, _presented} = result ->
        confirm_capacity(ctx)
        result

      other ->
        release_capacity(ctx)
        other
    end
  end

  defp do_deliver(req) do
    with {:ok, settle} <- resolve_settler(),
         {:ok, deliverable} <- settle.(%{requirement: req}) do
      {:deliver, present(deliverable)}
    end
  end

  # -- request validation --

  defp validate_requirement(req) do
    caps = capabilities()

    cond do
      not Schema.valid_requirement?(req) ->
        {:error, :malformed_requirement}

      req["src_chain_id"] == req["dst_chain_id"] ->
        {:error, :not_cross_chain}

      not positive_amount?(req["amount_atomic"]) ->
        {:error, :non_positive_amount}

      # Per-VM address format is only enforced against a live matrix, which
      # knows each chain's VM family. Under the EVM-only static fallback a
      # non-EVM chain would misclassify as :evm, so we defer to corridor gating
      # (preserving pre-capabilities behavior: a Tron leg rejects as an
      # unsupported token, not an invalid address).
      caps.source == :live and
          not Capabilities.valid_address?(caps, req["src_chain_id"], req["src_token"]) ->
        {:error, {:invalid_address, :src_token, req["src_chain_id"], req["src_token"]}}

      caps.source == :live and
          not Capabilities.valid_address?(caps, req["dst_chain_id"], req["dst_token"]) ->
        {:error, {:invalid_address, :dst_token, req["dst_chain_id"], req["dst_token"]}}

      not fillable?(caps, req["src_chain_id"], req["src_token"], :origin) ->
        {:error, {:unsupported_src_token, req["src_chain_id"], req["src_token"]}}

      not fillable?(caps, req["dst_chain_id"], req["dst_token"], :destination) ->
        {:error, {:unsupported_dst_token, req["dst_chain_id"], req["dst_token"]}}

      # Stablecoin corridor scope: both legs pass the token-fillable checks above,
      # but that is direction-blind -- it accepts pairs the solver cannot route
      # (e.g. USDT Arbitrum -> Base). The allowlist declines any route outside the
      # launch stablecoin set (USDC mesh, the USDT relay corridors, USDG drain).
      # Fails closed in production; inert in dev/test unless configured on.
      not allowed_corridor?(req) ->
        {:error, {:unsupported_corridor, req["src_chain_id"], req["dst_chain_id"]}}

      # Liquidity guardrails: reject a corridor we cannot settle right now before
      # escrow, so a customer gets a clean rejection instead of an accept that
      # fails at settlement. A closed origin (e.g. Robinhood while the USDG exit
      # is down, axol-io/Riddler#419) and an amount above the destination's fill
      # inventory are both hard stops. Config-driven; inert until set.
      origin_closed?(req["src_chain_id"]) ->
        {:error, {:origin_closed, req["src_chain_id"]}}

      not within_capacity?(req["dst_chain_id"], req["dst_token"], req["amount_atomic"]) ->
        {:error, {:over_capacity, req["dst_chain_id"], req["dst_token"]}}

      true ->
        :ok
    end
  end

  # -- Liquidity guardrails (config-driven; both default to inert) --
  #
  #     config :raxol_acp, :closed_origins, [4663]
  #     config :raxol_acp, :destination_caps, %{
  #       # {dst_chain_id, dst_token_address (lowercase)} => max atomic units/order
  #       {8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"} => 10_000_000_000,
  #       {10, "0x0b2c639c533813f4aa9d7837caf62653d097ff85"} => 0  # 0 => closed
  #     }
  #
  # A destination absent from the map is unconstrained; a src chain absent from
  # `:closed_origins` is open. Both unset reproduces today's behavior. Caps are
  # DESTINATION-side (the fill inventory), so they gate the token that actually
  # settles -- including a cross-asset Robinhood leg (dst = USDG on 4663).

  # Corridor scope gate: resolve each leg's token symbol from its {chain, address}
  # and consult the stablecoin allowlist. Inert (always true) unless the allowlist
  # is enabled -- see `CorridorAllowlist.enabled?/0`. An unknown token resolves to
  # `nil`, which the allowlist never allows (fail closed).
  defp allowed_corridor?(req) do
    if CorridorAllowlist.enabled?() do
      src_symbol = Assets.symbol_for(req["src_chain_id"], req["src_token"])
      dst_symbol = Assets.symbol_for(req["dst_chain_id"], req["dst_token"])

      CorridorAllowlist.allowed?(
        src_symbol,
        dst_symbol,
        req["src_chain_id"],
        req["dst_chain_id"]
      )
    else
      true
    end
  end

  defp origin_closed?(chain),
    do: chain in Application.get_env(:raxol_acp, :closed_origins, [])

  defp within_capacity?(chain, token, amount_atomic) when is_binary(token) do
    caps = Application.get_env(:raxol_acp, :destination_caps, %{})

    case Map.get(caps, {chain, String.downcase(token)}) do
      nil -> true
      cap when is_integer(cap) -> to_atomic(amount_atomic) <= cap
    end
  end

  defp within_capacity?(_chain, _token, _amount), do: true

  # Rolling aggregate capacity (bounds the running total per destination, not just
  # a single order). Reserved at accept, confirmed at settle, released on failure,
  # TTL-swept if the job never settles. Inert unless `CapacityLedger` is running;
  # a destination with no configured capacity is unbounded. See its module docs.

  defp reserve_capacity(req, ctx) do
    if capacity_ledger_running?() do
      dest = {req["dst_chain_id"], req["dst_token"]}
      amount = to_atomic(req["amount_atomic"])

      case CapacityLedger.reserve(ctx.job_id, dest, amount, reservation_ttl_ms()) do
        :ok ->
          :ok

        {:error, :over_capacity} ->
          {:error, {:over_capacity, req["dst_chain_id"], req["dst_token"]}}
      end
    else
      :ok
    end
  end

  defp confirm_capacity(ctx) do
    if capacity_ledger_running?(), do: CapacityLedger.confirm(ctx.job_id), else: :ok
  end

  defp release_capacity(ctx) do
    if capacity_ledger_running?(), do: CapacityLedger.release(ctx.job_id), else: :ok
  end

  defp capacity_ledger_running?, do: is_pid(Process.whereis(CapacityLedger))

  defp reservation_ttl_ms,
    do: Application.get_env(:raxol_acp, :capacity_reservation_ttl_ms, 900_000)

  # `positive_amount?/1` has already validated the string in this pipeline; a
  # non-integer falls back to 0, which fails every cap (rejected, fail-closed).
  defp to_atomic(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_atomic(_), do: 0

  # Corridor gate: the live capability matrix decides fillability, direction
  # aware (src must be an :origin token, dst a :destination token). The static
  # `Assets.known?/2` gate survives two ways: `Capabilities.fallback/0` is
  # derived from it (solver unreachable => today's behavior), and it backstops
  # a live matrix that omits addresses for a leg the static table knows.
  #
  # The backstop is scoped to chains the fallback matrix advertises: `Assets`
  # also carries non-EVM (Tron relay) addresses that the EVM-only fallback
  # corridor set does not cover, so a non-EVM leg stays unavailable until a live
  # matrix confirms it (fail closed).
  defp fillable?(caps, chain, token, role) do
    Capabilities.fillable?(caps, chain, token, role) or
      (caps.source == :fallback and fallback_chain?(caps, chain) and
         Assets.known?(chain, token))
  end

  defp fallback_chain?(caps, chain) do
    Enum.any?(caps.chains, &(&1.chain_id == chain))
  end

  # Cached capability matrix. The Xochi worker base_url comes from the same
  # `:xochi_transfer_settler` config the delivery path already requires; with
  # no config the gate degrades to the static fallback (never the network).
  defp capabilities do
    :raxol_acp
    |> Application.get_env(:xochi_transfer_settler, [])
    |> Keyword.get(:xochi_config)
    |> case do
      %{base_url: _} = config -> Capabilities.get(config)
      _ -> Capabilities.fallback()
    end
  end

  defp positive_amount?(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> n > 0
      _ -> false
    end
  end

  defp positive_amount?(_), do: false

  # -- delivery --

  # Use a configured `:settle_fn` as-is; otherwise build a Settler from the
  # options. Missing options return an error instead of raising during delivery.
  defp resolve_settler do
    opts = Application.get_env(:raxol_acp, :xochi_transfer_settler, [])

    case Keyword.get(opts, :settle_fn) do
      fun when is_function(fun, 1) -> {:ok, fun}
      _ -> build_settler(opts)
    end
  end

  defp build_settler(opts) do
    case Enum.reject(@settler_required, &Keyword.has_key?(opts, &1)) do
      [] -> {:ok, Settler.build(opts)}
      missing -> {:error, {:settler_not_configured, missing}}
    end
  end

  # Stringify keys and drop nil fields so the deliverable matches
  # `deliverable_schema/0` (string keys, no nulls).
  defp present(deliverable) do
    deliverable
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end
end
