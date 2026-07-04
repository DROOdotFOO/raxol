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

  USDC, USDT, or WETH on Ethereum, Optimism, Polygon, Base, or Arbitrum, checked
  against `Raxol.Payments.Assets`. Same-chain, malformed, non-positive-amount,
  and unknown-token requests are rejected before escrow.
  """

  use Raxol.ACP.Offering,
    name: "xochi_cross_chain_transfer",
    price_usdc: "0.25",
    sla_minutes: 10,
    cluster: "on_chain"

  alias Raxol.ACP.Xochi.Offering, as: Schema
  alias Raxol.ACP.Xochi.Settler
  alias Raxol.Payments.Assets

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
    cond do
      not Schema.valid_requirement?(req) ->
        {:error, :malformed_requirement}

      req["src_chain_id"] == req["dst_chain_id"] ->
        {:error, :not_cross_chain}

      not positive_amount?(req["amount_atomic"]) ->
        {:error, :non_positive_amount}

      not fillable?(req["src_chain_id"], req["src_token"]) ->
        {:error, {:unsupported_src_token, req["src_chain_id"], req["src_token"]}}

      not fillable?(req["dst_chain_id"], req["dst_token"]) ->
        {:error, {:unsupported_dst_token, req["dst_chain_id"], req["dst_token"]}}

      true ->
        :ok
    end
  end

  defp fillable?(chain, token), do: Assets.known?(chain, token)

  defp positive_amount?(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {n, ""} -> n > 0
      _ -> false
    end
  end

  defp positive_amount?(_), do: false

  # -- delivery --

  # Use a configured `:settle_fn` as-is; otherwise build a Settler from the
  # options. Missing options return an error instead of raising in Job.Server.
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
