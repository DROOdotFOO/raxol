defmodule Raxol.Web3.FX.Sleuth do
  @moduledoc """
  Sleuth's FX stablecoin surface, as market data (ADR-0040 decision 3).

  Three reads: `stables/2` (a page of assets), `stable/2` (one asset with its
  top pools) and `corridors/1` (totals per peg currency). All three go through
  `Raxol.Web3.HTTP`, the only way out of this package.

  ## What this module does not do

  It does not judge. Sleuth's `deviationBps`, `pegTargetUsd` and `fxRatesUsd`
  are carried through under `sleuth_` names as information, and nothing here
  computes from them: its FX rates were measured 13.9 hours old against its own
  four-hour budget, and its pool prices are rounded to two decimals.
  `Raxol.Web3.FX.Quality` gives the verdict, against `Raxol.Web3.FX.Chainlink`.

  ## Credentials

  The key travels in an `authorization: Bearer` header only. Sleuth also
  accepts `?api_key=`, which this module never builds, because a query string
  reaches access logs and error bodies. The struct does not render the key or
  `:http_opts` through `inspect/1`.

  ## Numbers

  Every figure is decoded with `floats: :decimals`, so an amount is a
  `Decimal` and never a float. `deviation_bps` and counts stay integers.

  A figure is `nil` unless it has at most 38 significant digits and an
  exponent within ±30, and that check reads only the decoded struct's
  fields. `1e1000000` is nine bytes of JSON, and the first arithmetic on it --
  rounding, a division by a rate, a `:normal` rendering -- expands the
  exponent into a million digits. The body bound caps a body's size, not what
  one number in it costs. A list entry that is not a JSON object is skipped.

  ## Symbols

  Canonicalized to the symbol `Raxol.Payments.Assets` uses, so a result can be
  echoed back as a lookup key: Sleuth's `EURE` and `MONERIUM` are `EURe`, and
  `FRANKENCOIN` is `ZCHF`.
  """

  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP

  @derive {Inspect, except: [:api_key, :http_opts]}
  @enforce_keys [:api_key]
  defstruct [
    :api_key,
    base_url: "https://www.sleuthintel.io/api/mcp",
    http_opts: [],
    cache?: true
  ]

  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          http_opts: keyword(),
          cache?: boolean()
        }

  @type asset :: %{
          symbol: String.t(),
          name: String.t() | nil,
          aliases: [String.t()],
          corridor: String.t() | nil,
          peg_currency: String.t() | nil,
          peg_mechanism: String.t() | nil,
          partner?: boolean(),
          yield_bearing?: boolean(),
          price_usd: Decimal.t() | nil,
          supply_usd: Decimal.t() | nil,
          volume_24h_usd: Decimal.t() | nil,
          partner_liquidity_usd: Decimal.t() | nil,
          sleuth_deviation_bps: integer() | nil,
          sleuth_peg_target_usd: Decimal.t() | nil
        }

  @type snapshot :: %{
          as_of: String.t() | nil,
          sleuth_fx_rates_usd: %{String.t() => Decimal.t()},
          sleuth_fx_rates_as_of: String.t() | nil,
          total: non_neg_integer() | nil,
          assets: [asset()]
        }

  # 15 a minute against a published `x-ratelimit-limit: 120`. The reset header
  # does not count down (985 then 1215 between samples), so it is never read.
  @rate_limit [capacity: 5, refill_per_second: 0.25]

  # Sleuth's own `refreshSec`. `cache-control: private, no-store` addresses
  # shared and browser caches; a 60 s in-process memo of data identical for
  # every caller is compatible with it (ADR-0040 decision 3).
  @ttl_ms 60_000

  # The largest measured body is 147.9 KB (`limit=300`).
  @max_bytes 262_144

  @sorts ~w(supplyUsd volume24hUsd deviationBps partnerLiquidityUsd marketCapUsd)

  @canonical %{"EURE" => "EURe", "MONERIUM" => "EURe", "FRANKENCOIN" => "ZCHF"}

  @doc """
  Build a handle.

  Options: `:api_key` (required), `:base_url` (https only, default Sleuth's),
  `:http_opts` (forwarded to `Raxol.Web3.HTTP`), `:cache` (default `true`).

  The key is trimmed, then refused as `{:invalid_argument, "api_key"}` unless
  every byte is visible ASCII: a CR, LF or space inside it cannot travel in a
  header, and the transport would otherwise refuse it later as an error that
  names nothing.
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Backend.error()}
  def new(opts) do
    base_url = Keyword.get(opts, :base_url, %__MODULE__{api_key: ""}.base_url)
    api_key = if is_binary(opts[:api_key]), do: String.trim(opts[:api_key]), else: ""

    cond do
      api_key == "" ->
        {:error, {:missing_argument, "api_key"}}

      not (api_key =~ ~r/\A[\x21-\x7E]+\z/) ->
        {:error, {:invalid_argument, "api_key"}}

      not String.starts_with?(base_url, "https://") ->
        {:error, {:invalid_argument, "base_url"}}

      true ->
        {:ok,
         %__MODULE__{
           api_key: api_key,
           base_url: String.trim_trailing(base_url, "/"),
           http_opts: Keyword.get(opts, :http_opts, []),
           cache?: Keyword.get(opts, :cache, true)
         }}
    end
  end

  @doc """
  A page of assets.

  Options: `:corridor` (`"EUR"`, `"REAL"`, `"VAR"`...), `:partner_only`,
  `:exclude_yield_bearing`, `:sort` (one of #{Enum.join(@sorts, ", ")}),
  `:limit` (1..300), `:offset` (>= 0). Validated before any request is built,
  so a bad argument costs no token from the bucket.
  """
  @spec stables(t(), keyword()) :: {:ok, snapshot()} | {:error, Backend.error()}
  def stables(%__MODULE__{} = sleuth, opts \\ []) do
    with {:ok, query} <- stables_query(opts),
         {:ok, body} <- get(sleuth, "/fx/stables", query) do
      decode_snapshot(body)
    end
  end

  @doc """
  One asset, with `top_pools`. `symbol` is looked up case-insensitively by
  Sleuth. It must start with a letter or digit, so it cannot be a `.` or `..`
  path segment that climbs out of `/fx/stables/` with the key attached.
  """
  @spec stable(t(), String.t()) ::
          {:ok, %{as_of: String.t() | nil, asset: map()}} | {:error, Backend.error()}
  def stable(%__MODULE__{} = sleuth, symbol) when is_binary(symbol) do
    if symbol =~ ~r/\A[A-Za-z0-9][A-Za-z0-9.\-]{0,23}\z/ do
      with {:ok, body} <- get(sleuth, "/fx/stables/" <> sleuth_symbol(symbol), []) do
        decode_detail(body)
      end
    else
      {:error, {:invalid_argument, "symbol"}}
    end
  end

  def stable(_sleuth, _symbol), do: {:error, {:invalid_argument, "symbol"}}

  @doc """
  Totals per peg currency. The per-corridor `assets` list is dropped unless
  `include_assets: true`, because it is most of a 70 KB body.
  """
  @spec corridors(t(), keyword()) :: {:ok, map()} | {:error, Backend.error()}
  def corridors(%__MODULE__{} = sleuth, opts \\ []) do
    with {:ok, body} <- get(sleuth, "/fx/corridors", []) do
      decode_corridors(body, Keyword.get(opts, :include_assets, false))
    end
  end

  @doc "The symbol `Raxol.Payments.Assets` uses for a Sleuth symbol."
  @spec canonical_symbol(String.t()) :: String.t()
  def canonical_symbol(symbol), do: Map.get(@canonical, String.upcase(symbol), symbol)

  # -- arguments -----------------------------------------------------------------

  defp stables_query(opts) do
    Enum.reduce_while(opts, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case param(key, value) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp param(:corridor, value) when is_binary(value) do
    if value =~ ~r/\A[A-Z]{3,4}\z/,
      do: {:ok, {"corridor", value}},
      else: {:error, {:invalid_argument, "corridor"}}
  end

  defp param(:partner_only, true), do: {:ok, {"partnerOnly", "1"}}
  defp param(:partner_only, false), do: {:ok, nil}
  defp param(:exclude_yield_bearing, true), do: {:ok, {"excludeYieldBearing", "1"}}
  defp param(:exclude_yield_bearing, false), do: {:ok, nil}
  defp param(:sort, value) when value in @sorts, do: {:ok, {"sort", value}}

  defp param(:limit, value) when is_integer(value) and value in 1..300,
    do: {:ok, {"limit", Integer.to_string(value)}}

  defp param(:offset, value) when is_integer(value) and value >= 0,
    do: {:ok, {"offset", Integer.to_string(value)}}

  defp param(key, _value), do: {:error, {:invalid_argument, Atom.to_string(key)}}

  # Sleuth looks up by its own names; `EURe` is `EURE` there.
  defp sleuth_symbol(symbol), do: String.upcase(symbol)

  # -- transport -----------------------------------------------------------------

  defp get(sleuth, path, query) do
    query = Enum.sort(query)
    url = sleuth.base_url <> path <> encode_query(query)

    opts =
      sleuth.http_opts
      |> Keyword.put_new(:rate_limit, @rate_limit)
      |> Keyword.put_new(:max_bytes, @max_bytes)
      |> Backend.put_header({"authorization", "Bearer " <> sleuth.api_key})
      |> Backend.put_header({"accept", "application/json"})
      |> put_cache(sleuth.cache?, {path, query})

    case HTTP.get(url, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, body}
      {:ok, %{status: status}} -> {:error, status_error(status)}
      {:error, _} = error -> error
    end
  end

  defp put_cache(opts, false, _fragment), do: opts

  defp put_cache(opts, true, fragment),
    do: Keyword.put(opts, :cache, key: {:sleuth, fragment}, ttl_ms: @ttl_ms)

  defp encode_query([]), do: ""
  defp encode_query(query), do: "?" <> URI.encode_query(query)

  # A 403 is `{:http, 403}`, as `Raxol.Web3.Backend` documents it: in front of
  # a CDN it is as likely a challenge page or an edge block as a refused key,
  # and reading it as `:auth` sends an operator to rotate a key that works.
  defp status_error(401), do: {:upstream_refused, :auth}
  defp status_error(404), do: {:upstream_refused, :not_found}
  defp status_error(429), do: {:upstream_refused, :rate_limit}
  defp status_error(400), do: {:invalid_argument, "query"}
  defp status_error(status), do: {:http, status}

  # -- decoding ------------------------------------------------------------------

  defp decode(body) do
    case Jason.decode(body, floats: :decimals) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:decode_failed, :sleuth}}
    end
  end

  defp decode_snapshot(body) do
    with {:ok, %{"assets" => assets} = map} when is_list(assets) <- decode(body) do
      {:ok,
       %{
         as_of: map["asOf"],
         sleuth_fx_rates_usd: decimals(map["fxRatesUsd"]),
         sleuth_fx_rates_as_of: map["fxRatesAsOf"],
         total: map["total"],
         assets: objects(assets, &asset/1)
       }}
    else
      {:ok, _other} -> {:error, {:decode_failed, :sleuth}}
      error -> error
    end
  end

  defp decode_detail(body) do
    with {:ok, %{"asset" => %{} = raw} = map} <- decode(body) do
      pools = objects(raw["topPools"], &pool/1)
      {:ok, %{as_of: map["asOf"], asset: Map.put(asset(raw), :top_pools, pools)}}
    else
      {:ok, _other} -> {:error, {:decode_failed, :sleuth}}
      error -> error
    end
  end

  defp decode_corridors(body, include_assets?) do
    with {:ok, %{"corridors" => corridors} = map} when is_list(corridors) <- decode(body) do
      {:ok, %{as_of: map["asOf"], corridors: objects(corridors, &corridor(&1, include_assets?))}}
    else
      {:ok, _other} -> {:error, {:decode_failed, :sleuth}}
      error -> error
    end
  end

  defp asset(raw) do
    %{
      symbol: symbol(raw["symbol"]),
      name: raw["name"],
      aliases: List.wrap(raw["aliases"]),
      corridor: raw["corridor"],
      peg_currency: raw["pegCurrency"],
      peg_mechanism: raw["pegMechanism"],
      partner?: raw["partner"] == true,
      yield_bearing?: raw["yieldBearing"] == true,
      price_usd: decimal(raw["priceUsd"]),
      supply_usd: decimal(raw["supplyUsd"]),
      volume_24h_usd: decimal(raw["volume24hUsd"]),
      partner_liquidity_usd: decimal(raw["partnerLiquidityUsd"]),
      sleuth_deviation_bps: integer(raw["deviationBps"]),
      sleuth_peg_target_usd: decimal(raw["pegTargetUsd"])
    }
  end

  # `price_usd` is Sleuth's two-decimal pool price: informational, never a
  # basis-point input (ADR-0040, "A pool-implied rate as the second source").
  defp pool(raw) do
    %{
      chain: raw["chain"],
      dex: raw["dex"],
      pair: raw["pair"],
      base: raw["base"],
      quote: raw["quote"],
      price_usd: decimal(raw["priceUsd"]),
      liquidity_usd: decimal(raw["liquidityUsd"]),
      volume_24h_usd: decimal(raw["volume24hUsd"])
    }
  end

  defp corridor(raw, include_assets?) do
    base = %{
      corridor: raw["corridor"],
      peg_currency: raw["pegCurrency"],
      asset_count: raw["assetCount"],
      total_supply_usd: decimal(raw["totalSupplyUsd"]),
      total_volume_24h_usd: decimal(raw["totalVolume24hUsd"]),
      total_partner_liquidity_usd: decimal(raw["totalPartnerLiquidityUsd"])
    }

    if include_assets?,
      do: Map.put(base, :assets, objects(raw["assets"], &corridor_asset/1)),
      else: base
  end

  defp corridor_asset(raw) do
    %{
      symbol: symbol(raw["symbol"]),
      supply_usd: decimal(raw["supplyUsd"]),
      volume_24h_usd: decimal(raw["volume24hUsd"]),
      sleuth_deviation_bps: integer(raw["deviationBps"])
    }
  end

  # Upstream data: an entry that is not an object has no fields to read.
  defp objects(list, fun), do: for(%{} = raw <- List.wrap(list), do: fun.(raw))

  defp symbol(symbol) when is_binary(symbol), do: canonical_symbol(symbol)
  defp symbol(_symbol), do: ""

  defp decimals(%{} = map),
    do: for({k, v} <- map, d = decimal(v), d != nil, into: %{}, do: {k, d})

  defp decimals(_), do: %{}

  # Checked on the struct's fields, before any `Decimal` function sees it.
  @max_exponent 30
  @max_coefficient Integer.pow(10, 38)

  defp decimal(%Decimal{coef: coef, exp: exp} = d)
       when is_integer(coef) and coef < @max_coefficient and exp in -@max_exponent..@max_exponent,
       do: d

  defp decimal(n) when is_integer(n) and abs(n) < @max_coefficient, do: Decimal.new(n)
  defp decimal(_), do: nil

  defp integer(n) when is_integer(n) and abs(n) < @max_coefficient, do: n

  defp integer(%Decimal{} = d) do
    case decimal(d) do
      nil -> nil
      bounded -> bounded |> Decimal.round(0) |> Decimal.to_integer()
    end
  end

  defp integer(_), do: nil
end
