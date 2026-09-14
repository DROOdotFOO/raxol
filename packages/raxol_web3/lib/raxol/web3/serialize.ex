defmodule Raxol.Web3.Serialize do
  @moduledoc """
  Renders normalized reads as JSON-safe data, and parses what a caller sends.

  ADR-0033 decision 4 rejects `Raxol.MCP.AgentBridge` for three reasons, and
  the third is this one: it "formats results with `inspect/2` rather than JSON".
  A model reading `%{from: {:evm, "0x.."}, timestamp: ~U[...]}` is reading Elixir
  term syntax, which it will sometimes parse and sometimes hallucinate around,
  and a client decoding it gets a string where it asked for an object.

  So the backend contract's shapes are Elixir-shaped (tagged tuples, `DateTime`
  structs, atoms) because that is right for Elixir callers, and this module is
  the one place they become JSON. Two conversions do the work:

    * A tagged account reference becomes `"tag:value"`, so `{:evm, "0xabc"}` is
      `"evm:0xabc"`. The tag survives rather than being flattened to a bare
      address, because it is the thing that distinguishes a Tron account from
      an EVM one and a Canton party from either, and a surface that drops it
      has to guess on the way back in.
    * A `DateTime` becomes ISO 8601.

  Everything else is already encodable: `Jason` renders an atom value as a
  string, so `:success` needs no help.

  ## Errors

  `error/1` renders the closed taxonomy as `%{code:, detail:}`. The code is the
  variant name and the detail is the variant's own datum: a retry-after in
  milliseconds, a byte limit, a status, an origin id. There is no message
  field, because there is no text to put in one, which is the property ADR-0038
  decision 6 spends its rules on.
  """

  # The families the tagged reference can name. Only `:evm` has a backend, and
  # the list is here rather than inline so that adding Tron is a one-line
  # change in one place instead of a grep.
  #
  # A compile-time map, not `String.to_existing_atom/1`. That function is the
  # usual guard against atom exhaustion from caller input, and it is the wrong
  # one here: it depends on the atom having been interned by something else
  # already, so `"party"` raised until an unrelated module happened to mention
  # `:party`. A fixed map cannot create an atom and cannot fail to find one.
  @tags %{
    "evm" => :evm,
    "tron" => :tron,
    "solana" => :solana,
    "party" => :party,
    "aztec" => :aztec
  }

  @doc """
  A read result, as JSON-safe data.

  Walks maps and lists, so one function covers a page of transfers and a single
  block without either knowing about it.
  """
  @spec result(term()) :: term()
  def result(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  def result(%_struct{} = struct), do: inspect(struct)

  def result(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, result(inner)} end)
  end

  def result(value) when is_list(value), do: Enum.map(value, &result/1)

  def result({tag, value}) when is_atom(tag) and is_binary(value) do
    "#{tag}:#{value}"
  end

  def result(value), do: value

  @doc """
  An error from the closed taxonomy, as JSON-safe data.

  A variant this does not know becomes `%{code: "error"}` rather than being
  inspected. That fallthrough is the same bet `Raxol.Web3.Redact` makes: a term
  nobody enumerated is a term nobody has checked for text.
  """
  @spec error(term()) :: %{code: String.t(), detail: term()}
  def error({code, detail}) when is_atom(code) and (is_integer(detail) or is_atom(detail)) do
    %{code: Atom.to_string(code), detail: detail}
  end

  def error({code, detail}) when is_atom(code) and is_binary(detail) do
    %{code: Atom.to_string(code), detail: detail}
  end

  def error(code) when is_atom(code), do: %{code: Atom.to_string(code), detail: nil}

  def error(_unknown), do: %{code: "error", detail: nil}

  @doc """
  Parse an account reference a caller sent.

  `"evm:0xabc"` is explicit. A bare `"0xabc"` is `{:evm, "0xabc"}`, which is
  the right default while EVM is the only family with a backend, and which is
  the thing to revisit when a second family lands rather than a thing to guess
  at then.
  """
  @spec account_ref(String.t()) :: {atom(), String.t()}
  def account_ref(value) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [tag, rest] when rest != "" ->
        case Map.fetch(@tags, tag) do
          {:ok, family} -> {family, rest}
          :error -> {:evm, value}
        end

      _bare ->
        {:evm, value}
    end
  end

  @doc "The account-reference tags this surface understands."
  @spec tags() :: [String.t()]
  def tags, do: Map.keys(@tags)
end
