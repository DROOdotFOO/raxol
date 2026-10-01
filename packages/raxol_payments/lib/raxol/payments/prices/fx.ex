defmodule Raxol.Payments.Prices.FX do
  @moduledoc """
  Prices euro and franc stablecoins for accounting, in front of another
  `price_fn` (ADR-0040 decision 6).

  Takes the `:fx` opts `Raxol.Payments.Accounting.env_config/0` produces when
  `RAXOL_FX_ENABLED=true` (`sleuth_api_key:` as a `Raxol.Payments.Secret`,
  `rpc_urls:` for chains 1 and 8453) and returns a `price_fn` that answers
  every symbol in `Raxol.Payments.Assets.fx_pegs/0` (EURC, EURe, ZCHF) at the
  Chainlink rate for its registered peg when Sleuth's market price is within
  100 bps of it, `nil` when it is not or the snapshot failed, and hands every
  other symbol to `fallback`. See `Raxol.Web3.FX.price_fn/3`.

  `raxol_web3` is an optional dependency. Without it, `price_fn(nil, fallback)`
  is still `fallback`, and any `:fx` opts raise: `Accounting` refuses
  `RAXOL_FX_ENABLED=true` in such a build before this is ever reached.

  Pricing only. Nothing here converts an amount a spend cap or a delivery
  floor reads; that is ADR-0040 decision 7, and it is not built.
  """

  alias Raxol.Payments.{Assets, Secret}

  @type price_fn :: (String.t() -> Decimal.t() | nil)

  @doc "`fallback` when `opts` is `nil`, else the FX `price_fn` in front of it."
  @spec price_fn(keyword() | nil, price_fn()) :: price_fn()
  def price_fn(nil, fallback) when is_function(fallback, 1), do: fallback

  def price_fn(opts, fallback) when is_list(opts) and is_function(fallback, 1),
    do: build(opts, fallback)

  @doc "Whether this build can price FX: `raxol_web3` is present."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(Raxol.Web3.FX)

  if Code.ensure_loaded?(Raxol.Web3.FX) do
    require Logger

    defp build(opts, fallback) do
      key = opts |> Keyword.fetch!(:sleuth_api_key) |> Secret.new() |> Secret.reveal()
      chainlink = Raxol.Web3.FX.Chainlink.new(rpc_urls: Keyword.get(opts, :rpc_urls, %{}))

      # `Sleuth.new/1` names the argument it refused and never the key.
      case Raxol.Web3.FX.Sleuth.new(api_key: key) do
        {:ok, sleuth} ->
          snapshot(Raxol.Web3.FX.new(sleuth, chainlink), fallback)

        {:error, reason} ->
          Logger.warning("FX Sleuth handle refused (#{inspect(reason)}); non-USD legs unpriced")
          unpriced(fallback)
      end
    end

    # The snapshot is upstream data, and the decoder is bounded against a
    # malformed one; this is the backstop if it still raises. Degrade the way a
    # failed snapshot already does -- the registered symbols unpriced, for the
    # ledger to count, and `fallback` for the rest -- rather than cost the
    # caller its whole sweep. Only the exception's module is logged; its
    # message can carry the upstream term.
    defp snapshot(fx, fallback) do
      Raxol.Web3.FX.price_fn(fx, Assets.fx_pegs(), fallback)
    rescue
      error ->
        Logger.warning(
          "FX price snapshot raised #{inspect(error.__struct__)}; non-USD legs unpriced"
        )

        unpriced(fallback)
    end

    # Never `fallback` for a registered symbol: it may price a euro at par.
    defp unpriced(fallback) do
      pegs = Assets.fx_pegs()
      fn symbol -> if Map.has_key?(pegs, symbol), do: nil, else: fallback.(symbol) end
    end
  else
    defp build(_opts, _fallback) do
      raise ArgumentError, "FX pricing needs raxol_web3, which is not in this build"
    end
  end
end
