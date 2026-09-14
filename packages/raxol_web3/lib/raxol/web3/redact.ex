defmodule Raxol.Web3.Redact do
  @moduledoc """
  Collapse a transport failure to something that can safely be returned.

  ADR-0038 decision 6, modeled on `Raxol.Telegram.HTTP.redact_transport_reason/1`
  (`telegram/http.ex:136-142`), the one place in this repository that already
  does this correctly. That helper exists because Mint's
  `{:invalid_request_target, "/file/bot<token>/..."}` puts a bot token inside an
  error term, and the same shape reaches us: a transport reason is a tuple of
  whatever the layer below felt like including.

  So the collapse is deliberately lossy and the fallthrough is deliberately
  generic. A nested atom reason survives (`:econnrefused`, `:timeout`,
  `:closed`, `:nxdomain` are the ones that matter operationally and none of
  them carries text). A struct becomes its module. Anything else, including
  every tuple, becomes `:transport_error` rather than being inspected, because
  inspecting is how the token got out last time.

  `uri/1` is the other half: no URL carrying a query string may appear in a log
  line or an error term, because an API key travels as a query parameter on
  one of the upstreams this package targets and upstream error bodies echo the
  failing URL back. Stripping the whole query rather than named parameters is
  the safe direction: a parameter allowlist has to be kept in step with every
  endpoint, and the cost of being wrong is asymmetric.
  """

  @doc """
  A transport reason, reduced to an atom or a module.

  Mirrors the Telegram helper's clause order exactly, including the generic
  fallthrough, because that fallthrough is the part that holds.
  """
  @spec reason(term()) :: atom()
  def reason(%{reason: nested}) when is_atom(nested), do: nested
  def reason(%{__struct__: mod}), do: mod
  def reason(reason) when is_atom(reason), do: reason
  def reason(_reason), do: :transport_error

  @doc """
  A URI with its query removed, for a log line.

  The userinfo goes too: `https://key@host/` is a credential in a URL, and it
  is rendered by `URI.to_string/1` without comment.
  """
  @spec uri(URI.t()) :: String.t()
  def uri(%URI{} = uri) do
    URI.to_string(%{uri | query: nil, fragment: nil, userinfo: nil})
  end
end
