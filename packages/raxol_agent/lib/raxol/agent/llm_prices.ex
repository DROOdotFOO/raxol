defmodule Raxol.Agent.LlmPrices do
  @moduledoc """
  A small static price table: USD per million tokens, by provider model
  family. Used when the `RAXOL_COST_PER_MTOK_IN/OUT` env rates are not
  set, so `/usage` and the spending ledger can estimate cost out of the
  box for well-known hosted models.

  Prices drift; these are approximate list prices, matched by model-name
  prefix (longest prefix wins). The env rates always take precedence,
  and an unknown model estimates nothing rather than guessing. Local
  backends (ollama, lm_studio) are free and deliberately absent.

  A second, backend-scoped table prices providers whose rate depends on the
  response rather than only on the request -- a cache tier and a UTC peak
  clock (ADR-0035). `turn_cost_usd/4` consults it before the flat table, and
  its rows are scoped to one backend because the same model name served by a
  reseller or by a free host must keep failing closed rather than borrow the
  direct vendor's rate.
  """

  # {prefix, usd_per_mtok_in, usd_per_mtok_out} — longest prefix wins.
  # Family rows sit under their exceptions: Opus dropped to 5/25 with
  # 4.5, and the gpt-5 variants price very differently from the base —
  # a family-only match would over- or under-bill a real spending budget
  # by an order of magnitude.
  @prices [
    {"claude-opus-4-5", 5.0, 25.0},
    {"claude-opus-4-6", 5.0, 25.0},
    {"claude-opus-4-7", 5.0, 25.0},
    {"claude-opus-4-8", 5.0, 25.0},
    {"claude-opus", 15.0, 75.0},
    {"claude-sonnet", 3.0, 15.0},
    {"claude-haiku", 1.0, 5.0},
    {"gpt-5-mini", 0.25, 2.0},
    {"gpt-5-nano", 0.05, 0.4},
    {"gpt-5-pro", 15.0, 120.0},
    {"gpt-5", 1.25, 10.0},
    {"gpt-4o-mini", 0.15, 0.6},
    {"gpt-4o", 2.5, 10.0}
  ]

  # Backend-scoped rows, consulted before @prices and matched longest-prefix
  # wins within one backend. A row declares the backend it applies to because
  # a model name is no longer sufficient: OpenRouter serves
  # "deepseek/deepseek-v4-pro" at its own markup and LLM7 serves
  # "deepseek-v4-flash" for free. Both return :unknown today and so fail
  # closed; a name-scoped row would silently convert them to fail-open at the
  # wrong vendor's rate (ADR-0035).
  #
  # Each rate is {off_peak, peak} USD per million tokens. DeepSeek's were
  # verified 2026-09-04. They move: the 2026-08-16 change took
  # deepseek-v4-pro output from a flat 0.87 to 3.96 at peak, a 355% increase
  # three weeks before this row was written, and nothing here makes a stale
  # row fail loudly. That is why a provider-reported cost outranks this table.
  #
  # deepseek-chat and deepseek-reasoner are deliberately absent: both were
  # announced retired and were observed still routing days later, which makes
  # them aliases whose target is not stable. Unpriced means fail-closed, which
  # is the correct treatment for a name that may reroute.
  #
  # {backend, prefix, cache-hit input, cache-miss input, output}
  @scoped_prices [
    {:deepseek, "deepseek-v4-pro", {0.022, 0.044}, {0.66, 1.32}, {1.98, 3.96}},
    {:deepseek, "deepseek-v4-flash", {0.007, 0.014}, {0.22, 0.44}, {0.66, 1.32}},
    {:deepseek, "deepseek-v4-flash-vision-exp", {0.007, 0.014}, {0.22, 0.44}, {0.66, 1.32}}
  ]

  @doc """
  The USD-per-Mtok rate pair for a model, `{:ok, {in_rate, out_rate}}`
  or `:unknown`. The backend is accepted for future disambiguation but
  matching is by model-name prefix.
  """
  @spec rates(atom() | nil, String.t() | nil) ::
          {:ok, {float(), float()}} | :unknown
  def rates(_backend, model) when is_binary(model) do
    case match_prefix(model) do
      :unknown -> match_prefix(strip_vendor(model))
      rates -> rates
    end
  end

  def rates(_backend, _model), do: :unknown

  @doc """
  The USD cost of one turn, `{:ok, cost}` or `:unknown`.

  Takes the provider-raw usage map, before `BenchmarkProfile.add_usage/2`
  collapses it to two fields, and an injectable clock so the module stays
  pure. Resolution order, highest first: a cost the provider reported in USD,
  the backend-scoped table, then `rates/2` with the cache-hit rate equal to
  the cache-miss rate. `RAXOL_COST_PER_MTOK_IN/OUT` outrank all three and are
  applied by the caller, which is the only party that reads the environment.

  A usage map carrying a cache split is priced exactly: hit tokens at the hit
  rate, miss tokens at the miss rate, never a blend. One without a split is
  priced at the conservative worst case -- peak rates, every input token a
  cache miss -- because a spend gate that guesses must only ever err upward.
  """
  @spec turn_cost_usd(atom() | nil, String.t() | nil, map(), DateTime.t()) ::
          {:ok, float()} | :unknown
  def turn_cost_usd(backend, model, usage, now \\ DateTime.utc_now())

  def turn_cost_usd(backend, model, usage, now) when is_map(usage) do
    case reported_cost_usd(usage) do
      {:ok, cost} -> {:ok, cost}
      :unknown -> table_cost_usd(backend, model, usage, now)
    end
  end

  def turn_cost_usd(_backend, _model, _usage, _now), do: :unknown

  defp match_prefix(nil), do: :unknown

  defp match_prefix(model) do
    @prices
    |> Enum.filter(fn {prefix, _in_rate, _out_rate} ->
      String.starts_with?(model, prefix)
    end)
    |> Enum.max_by(
      fn {prefix, _in_rate, _out_rate} -> byte_size(prefix) end,
      fn ->
        nil
      end
    )
    |> case do
      nil -> :unknown
      {_prefix, in_rate, out_rate} -> {:ok, {in_rate, out_rate}}
    end
  end

  # OpenRouter names the same hosted model "anthropic/claude-sonnet-4-5", which
  # matches no family prefix and therefore priced at nothing -- silently
  # inerting any budget on that whole backend. Retry on the segment after a
  # single "/", which is the vendor-prefix form; a local id with more than one
  # slash is left alone. Safe against the table as written because no row is
  # shorter than "gpt-4o", so a stripped local id cannot collide with a family.
  # Adding a short row ("gpt", "claude") would change that.
  defp strip_vendor(model) do
    case String.split(model, "/") do
      [_vendor, name] -> name
      _ -> nil
    end
  end

  # A cost the counterparty reported for THIS turn: `Harness.GrokBuild` stamps
  # it from `total_cost_usd` (grok_build.ex:98-107) and an ACP peer sends it
  # as %{amount, currency}. Preferred over any table because whoever billed
  # the turn knows its price -- but it is a claim, not an invoice, so currency
  # is never coerced: anything other than USD falls through to the table
  # instead of being converted, since a silently-converted figure in a spend
  # gate is the failure this whole path exists to prevent (ADR-0035).
  #
  # A non-positive amount is indistinguishable from no claim and treated as
  # one. `:session_cost`, the cumulative figure an ACP peer reports alongside
  # the per-turn delta, is display-only and deliberately never read here:
  # summing it with :cost would double-count the whole session every turn.
  defp reported_cost_usd(usage) do
    case Map.get(usage, :cost) || Map.get(usage, "cost") do
      amount when is_number(amount) and amount > 0 -> {:ok, amount / 1}
      %{} = cost -> usd_amount(cost)
      _ -> :unknown
    end
  end

  defp usd_amount(cost) do
    amount = Map.get(cost, :amount) || Map.get(cost, "amount")
    currency = Map.get(cost, :currency) || Map.get(cost, "currency")

    if currency == "USD" and is_number(amount) and amount > 0 do
      {:ok, amount / 1}
    else
      :unknown
    end
  end

  defp table_cost_usd(backend, model, usage, now) do
    case scoped_row(backend, model) do
      {_backend, _prefix, hit, miss, out} ->
        tokens = split_tokens(usage)
        tier = tier(tokens, now)

        {:ok, price(tokens, {at(hit, tier), at(miss, tier), at(out, tier)})}

      nil ->
        flat_cost_usd(backend, model, usage)
    end
  end

  # The flat table carries neither dimension, so a hit costs what a miss
  # costs and the clock is irrelevant. Every existing caller keeps its number.
  defp flat_cost_usd(backend, model, usage) do
    case rates(backend, model) do
      {:ok, {rin, rout}} -> {:ok, price(split_tokens(usage), {rin, rin, rout})}
      :unknown -> :unknown
    end
  end

  defp scoped_row(backend, model) when is_binary(model) do
    @scoped_prices
    |> Enum.filter(fn {row_backend, prefix, _hit, _miss, _out} ->
      row_backend == backend and String.starts_with?(model, prefix)
    end)
    |> Enum.max_by(
      fn {_backend, prefix, _hit, _miss, _out} -> byte_size(prefix) end,
      fn -> nil end
    )
  end

  defp scoped_row(_backend, _model), do: nil

  defp price(%{hit: hit, miss: miss, output: output}, {hit_rate, miss_rate, out_rate}) do
    hit / 1_000_000 * hit_rate + miss / 1_000_000 * miss_rate +
      output / 1_000_000 * out_rate
  end

  defp at({off_peak, _peak}, :off_peak), do: off_peak
  defp at({_off_peak, peak}, :peak), do: peak

  # Without a split there is nothing to price exactly, so price the worst case
  # the row can produce: peak rates on all-miss input. Three real paths land
  # here -- a streaming turn whose trailing usage frame is empty, a resumed
  # session's string-keyed journal payload, and an Anthropic-compatible
  # surface, which emits no cache fields at all -- so this branch carries
  # weight rather than guarding a theoretical case.
  defp tier(%{split?: false}, _now), do: :peak
  defp tier(%{split?: true}, now), do: peak_tier(now)

  # Peak is 01:00-04:00 and 06:00-10:00 UTC (Beijing business hours) and
  # off-peak is half, so the window is expressed as UTC hours with no timezone
  # database and no DST. Half-open at the top: 04:00 and 10:00 are the first
  # off-peak hours, not the last peak ones.
  @peak_hours [1, 2, 3, 6, 7, 8, 9]

  # DeepSeek documents peak hours as Monday-Friday but does not say whether a
  # weekend hour inside a peak window is peak or off-peak, so every weekend
  # hour counts as peak. That over-bills a weekend turn by 2x on purpose: an
  # unresolved ambiguity in a spend gate points upward (ADR-0035).
  defp peak_tier(%DateTime{} = now) do
    # Normalized through unix seconds so a caller's non-UTC clock still lands
    # on the UTC window without needing a timezone database.
    utc = DateTime.from_unix!(DateTime.to_unix(now))

    cond do
      Date.day_of_week(DateTime.to_date(utc)) >= 6 -> :peak
      utc.hour in @peak_hours -> :peak
      true -> :off_peak
    end
  end

  defp peak_tier(_now), do: :peak

  # Provider-raw cache keys, normalized here because turn_cost_usd/4 takes the
  # map before anything collapses it: DeepSeek's hit/miss pair, Anthropic's
  # read/creation pair, the camel-cased ACP wire field, and the atom form the
  # ACP adapter emits.
  @hit_keys [
    :prompt_cache_hit_tokens,
    :cache_read_input_tokens,
    "cachedReadTokens",
    :cached_read_tokens
  ]
  @miss_keys [:prompt_cache_miss_tokens]
  @input_keys [:input_tokens, :prompt_tokens]
  @output_keys [:output_tokens, :completion_tokens]
  # An Anthropic cache WRITE is not a read: it bills above the miss rate, so
  # counting it as a miss is the closest classification that still errs up.
  @creation_keys [:cache_creation_input_tokens]

  # DeepSeek reports hit + miss = prompt_tokens, so an explicit miss count
  # replaces the input count. Anthropic and ACP report cached reads BESIDE an
  # input count that already excludes them, so there the input count IS the
  # miss count. Either way no token is billed twice.
  defp split_tokens(usage) do
    hit = read(usage, @hit_keys)
    miss = read(usage, @miss_keys)
    input = read(usage, @input_keys) || 0

    %{
      hit: hit || 0,
      miss: (miss || input) + (read(usage, @creation_keys) || 0),
      output: read(usage, @output_keys) || 0,
      split?: hit != nil or miss != nil
    }
  end

  # Atom and string keys both, as `add_usage/2` already accepts: a live frame
  # is keyed either way depending on the provider, and a resumed session's
  # journal payload is always string-keyed. A reported zero is a fact, not an
  # absence, so it stops the search and still counts as a split.
  defp read(usage, keys), do: Enum.find_value(keys, &token_count(usage, &1))

  defp token_count(usage, key) do
    case Map.get(usage, key) || Map.get(usage, alt_key(key)) do
      n when is_integer(n) and n >= 0 -> n
      _ -> nil
    end
  end

  defp alt_key(key) when is_atom(key), do: Atom.to_string(key)
  defp alt_key(key), do: key
end
