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
  """

  # {prefix, usd_per_mtok_in, usd_per_mtok_out} — longest prefix wins.
  @prices [
    {"claude-opus", 15.0, 75.0},
    {"claude-sonnet", 3.0, 15.0},
    {"claude-haiku", 1.0, 5.0},
    {"gpt-5", 1.25, 10.0},
    {"gpt-4o-mini", 0.15, 0.6},
    {"gpt-4o", 2.5, 10.0}
  ]

  @doc """
  The USD-per-Mtok rate pair for a model, `{:ok, {in_rate, out_rate}}`
  or `:unknown`. The backend is accepted for future disambiguation but
  matching is by model-name prefix.
  """
  @spec rates(atom() | nil, String.t() | nil) ::
          {:ok, {float(), float()}} | :unknown
  def rates(_backend, model) when is_binary(model) do
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

  def rates(_backend, _model), do: :unknown
end
