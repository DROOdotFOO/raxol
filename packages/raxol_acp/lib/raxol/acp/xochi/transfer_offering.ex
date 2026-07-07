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
  def handle_request(req, _ctx) do
    case validate_requirement(req) do
      :ok -> {:accept, req}
      {:error, reason} -> {:reject, reason}
    end
  end

  @impl true
  def handle_deliver(req, _ctx) do
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

      true ->
        :ok
    end
  end

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
