defmodule Raxol.Web3.Backend.SQD do
  @moduledoc """
  How the SQD Portal announces a refusal, read once for both backends on it.

  `Raxol.Web3.Backend.Solana` and `Raxol.Web3.Backend.Tron` are two readers of
  one endpoint, `portal.sqd.dev/mcp`, and every time that reading was
  duplicated the two copies drifted apart into a live bug. One read
  `unknown_network` as a chain this source does not serve and failed over
  while the other read it as a not-found and stopped; then one classified
  `unauthorized` and `rate_limited` as facts about the source while the other
  collapsed both to an unclassifiable refusal, so a keyless read died on one
  chain with a healthy sibling behind it and failed over on the other. The
  reading lives here so there is one of it.

  ## A refusal has two places to live, so both are read

  A `tools/call` result can announce a refusal with `isError: true`, and it
  can announce one as a plain result whose payload IS the error object. Both
  refusals recorded from this endpoint on 2026-09-14 carried `isError: true`,
  so the second arm is a defence rather than a measurement, and it is worth
  one pattern match: a reader that checks one arm hands the other back as a
  successful body, and downstream that becomes a decode failure or an empty
  catalog. The read still fails, but it fails telling an operator that the
  archive returned garbage or does not carry this chain when the truth is
  that this deployment holds no credential, and that is the diagnosis they
  would act on.

  ## The code, never the prose

  The payload carries a `summary` and a `suggestions` list beside its `code`.
  Nothing here reads either: a refusal is classified by the machine-readable
  code alone, so no upstream text can reach an error term, which is ADR-0038
  decision 6's rule. `code/1` is what makes that structural rather than a
  matter of review.

  Only `unknown_network` needs anything from the caller, because naming the
  chain this source does not serve is the point of that variant; the caller
  passes the network name it asked about rather than this module reaching
  into a handle it does not own.
  """

  alias Raxol.Web3.Backend

  @doc """
  The refusal a payload announces, or `nil` when it announces none.

  `nil` is the answer for a successful body, so a caller on the plain arm of
  a tool result can tell the two apart without reading the body twice.
  """
  @spec refusal(term(), String.t() | nil) :: Backend.error() | nil
  def refusal(payload, network) do
    case code(payload) do
      nil -> nil
      code -> class(code, network)
    end
  end

  @doc """
  The refusal an `isError: true` result announces.

  Such a result is a refusal whatever its payload turns out to say, so one
  whose code cannot be read is still an error, and an unclassifiable one is
  final: it is our own request being wrong, and a sibling source would answer
  it the same way.
  """
  @spec announced(term(), String.t() | nil) :: Backend.error()
  def announced(payload, network) do
    refusal(payload, network) || {:upstream_refused, :unknown}
  end

  @doc "The machine-readable code a payload carries, or `nil`."
  @spec code(term()) :: String.t() | nil
  def code(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  def code(_other), do: nil

  # `unknown_network` says this source does not serve this chain, which a
  # sibling may; `:auth` and `:rate_limit` are a credential this deployment
  # does not hold and a budget this origin has spent. All three are facts
  # about the SOURCE, so `Raxol.Web3.Router.failover?/1` walks on. Anything
  # else is about the question and is final: `invalid_request`, the
  # windowless account query measured 2026-09-14, is the case that must be.
  defp class("unknown_network", network), do: {:unsupported_chain, network}
  defp class("unauthorized", _network), do: {:upstream_refused, :auth}
  defp class("rate_limited", _network), do: {:upstream_refused, :rate_limit}
  defp class(_ours, _network), do: {:upstream_refused, :unknown}
end
