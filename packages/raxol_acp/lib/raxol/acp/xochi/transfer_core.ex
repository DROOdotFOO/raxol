defmodule Raxol.ACP.Xochi.TransferCore do
  @moduledoc """
  Shared implementation for the Xochi ACP transfer offerings.

  Holds the request validation, corridor/liquidity gating, capacity accounting,
  and settler-relay delivery that all Xochi transfer offerings share. The public
  entry points take a `settlement_mode` so a thin offering module can layer a
  focused settlement gate on top of the common corridor rules:

    - `:any`     -- no settlement gate (the legacy `TransferOffering` shim).
    - `:public`  -- reject a requirement that declares a private/stealth tier.
    - `:stealth` -- require a stealth tier, an Ethereum-L1 destination (stealth
                    settles to a one-time ERC-5564 address on L1; cross-chain
                    stealth is not live), and the ERC-5564 meta-address keys.

  raxol never inspects or re-signs the buyer's opaque signed intent, so the gate
  works on the declared requirement fields only. It keeps a wrong request out of
  escrow with a machine-readable reason; Riddler remains the source of truth at
  fill.
  """

  alias Raxol.ACP.Xochi.CapacityLedger
  alias Raxol.ACP.Xochi.CorridorAllowlist
  alias Raxol.ACP.Xochi.Offering, as: Schema
  alias Raxol.ACP.Xochi.Settler
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Xochi.Capabilities

  @settler_required [:xochi_config]

  @type mode :: :any | :public | :stealth

  @doc "Validate + reserve capacity for a request under the given settlement mode."
  @spec handle_request(map(), map(), mode()) :: {:accept, map()} | {:reject, term()}
  def handle_request(req, ctx, mode) do
    with :ok <- validate_requirement(req, mode),
         :ok <- reserve_capacity(req, ctx) do
      {:accept, req}
    else
      {:error, reason} -> {:reject, reason}
    end
  end

  @doc "Relay the buyer's signed intent through the Settler and present the deliverable."
  @spec handle_deliver(map(), map()) :: {:deliver, map()} | {:error, term()}
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

  defp validate_requirement(req, mode) do
    caps = capabilities()

    cond do
      not Schema.valid_requirement?(req) ->
        {:error, :malformed_requirement}

      req["src_chain_id"] == req["dst_chain_id"] ->
        {:error, :not_cross_chain}

      not positive_amount?(req["amount_atomic"]) ->
        {:error, :non_positive_amount}

      # Settlement-mode gate (skipped for :any). Gates on the DECLARED
      # settlement_preference + dst_chain_id, not the opaque signature, so an
      # agent that picked the wrong offering (or an L2 destination for stealth)
      # gets a focused rejection before escrow instead of a fill-time failure.
      mode == :public and req["settlement_preference"] in ["stealth", "private"] ->
        {:error, {:wrong_offering, :expected_public, "xochi_stable_stealth"}}

      mode == :stealth and req["settlement_preference"] == "public" ->
        {:error, {:wrong_offering, :expected_stealth, "xochi_stable_public"}}

      # Stealth settles to a one-time ERC-5564 address on Ethereum L1. Cross-chain
      # stealth is not live, so the destination must be chain 1 (mirrors the Xochi
      # frontend gate). This offering is therefore X->L1: a non-Ethereum origin
      # bridging to an Ethereum-L1 stealth settlement.
      mode == :stealth and req["dst_chain_id"] != 1 ->
        {:error, {:stealth_requires_l1_destination, req["dst_chain_id"]}}

      mode == :stealth and not valid_stealth_meta?(req["stealth_meta_address"]) ->
        {:error, :stealth_meta_address_required}

      # Per-VM address format is only enforced against a live matrix, which knows
      # each chain's VM family. Under the EVM-only static fallback a non-EVM chain
      # would misclassify as :evm, so we defer to corridor gating (preserving
      # pre-capabilities behavior: a Tron leg rejects as an unsupported token).
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

      not allowed_corridor?(req) ->
        {:error, {:unsupported_corridor, req["src_chain_id"], req["dst_chain_id"]}}

      origin_closed?(req["src_chain_id"]) ->
        {:error, {:origin_closed, req["src_chain_id"]}}

      not within_capacity?(req["dst_chain_id"], req["dst_token"], req["amount_atomic"]) ->
        {:error, {:over_capacity, req["dst_chain_id"], req["dst_token"]}}

      true ->
        :ok
    end
  end

  # ERC-5564 meta-address: both spending and viewing public keys, 0x-hex.
  defp valid_stealth_meta?(%{"spending_pub_key" => s, "viewing_pub_key" => v})
       when is_binary(s) and is_binary(v),
       do: hex_key?(s) and hex_key?(v)

  defp valid_stealth_meta?(_), do: false

  defp hex_key?(k), do: String.match?(k, ~r/^0x[0-9a-fA-F]+$/)

  # -- corridor + liquidity gating (config-driven; default inert) --

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

  # -- rolling aggregate capacity (inert unless the ledger is running) --

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

  defp to_atomic(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> n
      _ -> 0
    end
  end

  defp to_atomic(_), do: 0

  # Corridor gate: the live capability matrix decides fillability, direction
  # aware; the static Assets set survives as the fallback and backstops a live
  # matrix that omits addresses for a leg the static table knows.
  defp fillable?(caps, chain, token, role) do
    Capabilities.fillable?(caps, chain, token, role) or
      (caps.source == :fallback and fallback_chain?(caps, chain) and
         Assets.known?(chain, token))
  end

  defp fallback_chain?(caps, chain), do: Enum.any?(caps.chains, &(&1.chain_id == chain))

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

  defp present(deliverable) do
    deliverable
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
  end
end
