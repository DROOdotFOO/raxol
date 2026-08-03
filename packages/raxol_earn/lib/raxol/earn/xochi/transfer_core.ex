defmodule Raxol.Earn.Xochi.TransferCore do
  @moduledoc """
  Shared implementation for the Xochi ACP transfer offerings.

  Holds the request validation, corridor/liquidity gating, capacity accounting,
  and settler-relay delivery that all Xochi transfer offerings share. The public
  entry points take a `settlement_mode` so a thin offering module can layer a
  focused settlement gate on top of the common corridor rules:

    - `:any`: no settlement gate (the legacy `TransferOffering` shim).
    - `:public`: reject a requirement that declares a private or stealth tier.
    - `:stealth`: require a stealth tier, an Ethereum-L1 destination (stealth
      settles to a one-time ERC-5564 address on L1; cross-chain stealth is not
      live), and the ERC-5564 meta-address keys.

  raxol never inspects or re-signs the buyer's opaque signed intent, so the gate
  works on the declared requirement fields only. It keeps a wrong request out of
  escrow with a machine-readable reason; Riddler remains the source of truth at
  fill. `describe_rejection/1` turns each of those reasons into a sentence a buyer
  agent can act on.
  """

  alias Raxol.Earn.Xochi.CapacityLedger
  alias Raxol.Earn.Xochi.CorridorAllowlist
  alias Raxol.Earn.Xochi.Offering, as: Schema
  alias Raxol.Earn.Xochi.Settler
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

  @doc """
  Human-readable explanation for a `{:reject, reason}` from `handle_request/3`.

  Buyer agents get a machine-readable reason tuple back; this maps each one to a
  sentence they can log or show, so a rejected job says what to fix (wrong
  offering, closed corridor, over capacity) instead of an opaque atom.

      iex> Raxol.Earn.Xochi.TransferCore.describe_rejection(:not_cross_chain)
      "Source and destination chains are the same; this offering only settles cross-chain."
  """
  @spec describe_rejection(term()) :: String.t()
  def describe_rejection(:malformed_requirement),
    do:
      "The requirement is missing corridor fields or a signed_intent bundle " <>
        "(needs intent_id, quote_id, signature, nonce)."

  def describe_rejection(:not_cross_chain),
    do: "Source and destination chains are the same; this offering only settles cross-chain."

  def describe_rejection(:non_positive_amount),
    do: "amount_atomic must be a positive integer in token base units."

  def describe_rejection({:wrong_offering, :expected_public, alt}),
    do:
      "This is the public offering, but the requirement asks for a stealth tier. Use \"#{alt}\"."

  def describe_rejection({:wrong_offering, :expected_stealth, alt}),
    do:
      "This is the stealth offering, but the requirement asks for public settlement. Use \"#{alt}\"."

  def describe_rejection({:wrong_offering, :expected_usdc}),
    do:
      "This offering settles USDC only; a leg is not USDC. Other stablecoins are not settle-ready yet."

  def describe_rejection({:order_below_min, min}),
    do: "Order amount is below the minimum of #{min} base units."

  def describe_rejection({:order_above_max, max}),
    do: "Order amount exceeds the maximum of #{max} base units; use a smaller amount."

  def describe_rejection({:stealth_requires_l1_destination, dst}),
    do:
      "Stealth settles on Ethereum L1, so dst_chain_id must be 1 (got #{dst}); " <>
        "cross-chain stealth is not live."

  def describe_rejection(:stealth_meta_address_required),
    do: "Stealth needs a stealth_meta_address with 0x-hex spending_pub_key and viewing_pub_key."

  def describe_rejection({:invalid_address, leg, chain, token}),
    do: "The #{leg} address #{token} is not a valid address for chain #{chain}."

  def describe_rejection({:unsupported_src_token, chain, token}),
    do: "The solver cannot pull #{token_label(chain, token)} on chain #{chain}."

  def describe_rejection({:unsupported_dst_token, chain, token}),
    do: "The solver cannot deliver #{token_label(chain, token)} on chain #{chain}."

  def describe_rejection({:unsupported_corridor, src, dst}),
    do: "The #{src} -> #{dst} corridor is not on the allowlist."

  def describe_rejection({:origin_closed, chain}),
    do: "Chain #{chain} is closed for origin pulls right now."

  def describe_rejection({:over_capacity, chain, token}),
    do:
      "The destination #{token_label(chain, token)} on chain #{chain} is at capacity; " <>
        "try a smaller amount or another corridor."

  def describe_rejection({:settler_not_configured, missing}),
    do: "The settler is not configured (missing #{inspect(missing)})."

  def describe_rejection(reason), do: "Request rejected: #{inspect(reason)}."

  defp token_label(chain, token) do
    case Assets.symbol_for(chain, token) do
      symbol when is_binary(symbol) -> symbol
      _ -> token
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
    do: chain in Application.get_env(:raxol_earn, :closed_origins, [])

  defp within_capacity?(chain, token, amount_atomic) when is_binary(token) do
    caps = Application.get_env(:raxol_earn, :destination_caps, %{})

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
    do: Application.get_env(:raxol_earn, :capacity_reservation_ttl_ms, 900_000)

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
    :raxol_earn
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
    opts = Application.get_env(:raxol_earn, :xochi_transfer_settler, [])

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
