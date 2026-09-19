defmodule Raxol.Web3.RPC do
  @moduledoc """
  A read-only JSON-RPC client, on the guarded outbound path.

  This is where the repository's two hand-rolled JSON-RPC clients converge, not
  a third one. `Raxol.Payments.ChainReader.JSONRPC` builds `[url:, headers:]`
  and passes **no timeout at all** (`jsonrpc.ex:99-112`), and puts the raw
  upstream body into an error term (`:119-120`); `Raxol.Earn.Onchain.RPC` sets a
  receive timeout and nothing else. Neither vets an address, neither refuses a
  redirect, neither bounds a response. ADR-0033 gap 3 is about exactly that
  pair, and ADR-0033 decision 2 moves the read layer down here so they can
  collapse into one. That migration carries deprecated shims across
  `raxol_payments` and is sequenced on its own; this module is the destination
  it collapses onto, which is why it is not called `JSONRPC2` or bolted to a
  backend.

  ## Read-only by construction

  `@read_methods` is a compile-time allowlist, and `call/4` refuses anything
  outside it before a request is built. ADR-0033 §4's claim that the served
  surface is read-only rests on this being structural: an unbounded passthrough
  to a JSON-RPC endpoint reaches `eth_sendRawTransaction`, and no amount of
  annotation on a tool definition prevents that.

  ## Errors carry no upstream text

  A JSON-RPC error object is mapped from its code onto the closed
  `{:upstream_refused, _}` set. The `message` field is upstream-authored text
  and does not travel: on an MCP surface it would land in model-visible output,
  and the survey records upstreams echoing the failing URL, query string
  included, inside exactly that field.
  """

  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP

  # Every method this package may speak. Additions are a deliberate act, and a
  # write method cannot be added by accident because none of them belongs to a
  # read contract.
  @read_methods ~w(
    eth_blockNumber
    eth_getBlockByNumber
    eth_getBlockByHash
    eth_getTransactionByHash
    eth_getTransactionReceipt
    eth_getBalance
    eth_getCode
    eth_getLogs
    eth_call
    eth_chainId
  )

  @json_headers [{"content-type", "application/json"}]

  @doc "The methods this client will speak, as a list."
  @spec read_methods() :: [String.t()]
  def read_methods, do: @read_methods

  @doc """
  One JSON-RPC call.

  Refuses a method outside the read allowlist, then goes out through
  `Raxol.Web3.HTTP`, so it inherits the vet, the origin's rate-limit budget,
  the circuit breaker, the pinned dial and every bound in the read loop.
  """
  @spec call(String.t(), String.t(), list(), keyword()) ::
          {:ok, term()} | {:error, Backend.error()}
  def call(url, method, params \\ [], opts \\ []) do
    if method in @read_methods do
      do_call(url, method, params, opts)
    else
      {:error, {:unsupported, :rpc_method}}
    end
  end

  @doc "The latest block number, as an integer."
  @spec block_number(String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Backend.error()}
  def block_number(url, opts \\ []) do
    with {:ok, hex} <- call(url, "eth_blockNumber", [], opts) do
      decode_quantity(hex)
    end
  end

  @doc """
  A block height by tag or number.

  `"finalized"` is the one that matters here: it is the only way to answer
  `finalized_height` on an EVM chain, since Blockscout's REST surface exposes no
  finality at all. A chain whose node does not know the tag answers `null`,
  which becomes `{:ok, nil}` rather than an error: no finality is a fact about
  the chain, not a failure of the call.
  """
  @spec block_height_by_tag(String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer() | nil} | {:error, Backend.error()}
  def block_height_by_tag(url, tag, opts \\ []) do
    case call(url, "eth_getBlockByNumber", [tag, false], opts) do
      {:ok, %{"number" => hex}} -> decode_quantity(hex)
      {:ok, nil} -> {:ok, nil}
      {:ok, _unexpected} -> {:error, {:decode_failed, :block}}
      {:error, _reason} = error -> error
    end
  end

  @doc "An `eth_call`, returning the raw hex result. The path any balance gate takes."
  @spec eth_call(String.t(), map(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Backend.error()}
  def eth_call(url, %{to: to, data: data}, tag \\ "latest", opts \\ []) do
    call(url, "eth_call", [%{"to" => to, "data" => data}, tag], opts)
  end

  @doc """
  A transaction by hash, as the node returns it, or `nil`.

  `nil` is the node's answer both for a hash it has never seen and for one it
  is holding in its pool but has not mined, so a caller that needs to tell
  those apart asks for the receipt as well.
  """
  @spec transaction(String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, Backend.error()}
  def transaction(url, hash, opts \\ []) when is_binary(hash) do
    object(call(url, "eth_getTransactionByHash", [hash], opts), :transaction)
  end

  @doc """
  A transaction receipt by hash, or `nil` when the transaction is not mined.

  The receipt is where a status and an effective gas price live; the
  transaction object carries neither.
  """
  @spec receipt(String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, Backend.error()}
  def receipt(url, hash, opts \\ []) when is_binary(hash) do
    object(call(url, "eth_getTransactionReceipt", [hash], opts), :receipt)
  end

  @doc "The native balance of an address at a tag, as an integer."
  @spec balance(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Backend.error()}
  def balance(url, address, tag \\ "latest", opts \\ []) when is_binary(address) do
    with {:ok, hex} <- call(url, "eth_getBalance", [address, tag], opts) do
      decode_quantity(hex)
    end
  end

  @doc """
  The code at an address at a tag, as the node's own hex string.

  `"0x"` is the answer for an address with no code, and it is returned as
  itself rather than as `nil`: whether that means "externally owned account"
  is a judgement for a caller, not an encoding decision here.
  """
  @spec code(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, Backend.error()}
  def code(url, address, tag \\ "latest", opts \\ []) when is_binary(address) do
    case call(url, "eth_getCode", [address, tag], opts) do
      {:ok, hex} when is_binary(hex) -> {:ok, hex}
      {:ok, _unexpected} -> {:error, {:decode_failed, :code}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  `eth_getLogs` for one filter object, as a list.

  The filter is built by the caller and passed through, because the bound that
  matters is the block range and only the caller knows what range it is walking.
  An unbounded range is how a public node refuses a query.
  """
  @spec logs(String.t(), map(), keyword()) :: {:ok, [map()]} | {:error, Backend.error()}
  def logs(url, filter, opts \\ []) when is_map(filter) do
    case call(url, "eth_getLogs", [filter], opts) do
      {:ok, logs} when is_list(logs) -> {:ok, logs}
      {:ok, _unexpected} -> {:error, {:decode_failed, :logs}}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  A block by number or tag, with transaction hashes rather than bodies.

  The full-body flag is `false` on purpose: a block's transaction bodies are an
  unbounded response whose size is set by whoever filled the block, and nothing
  in the read contract needs them. The hash list still carries the count.
  """
  @spec block_by_number(String.t(), non_neg_integer() | String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, Backend.error()}
  def block_by_number(url, number_or_tag, opts \\ [])

  def block_by_number(url, number, opts) when is_integer(number) do
    block_by_number(url, encode_quantity(number), opts)
  end

  def block_by_number(url, tag, opts) when is_binary(tag) do
    object(call(url, "eth_getBlockByNumber", [tag, false], opts), :block)
  end

  @doc "A block by hash, with transaction hashes rather than bodies."
  @spec block_by_hash(String.t(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, Backend.error()}
  def block_by_hash(url, hash, opts \\ []) when is_binary(hash) do
    object(call(url, "eth_getBlockByHash", [hash, false], opts), :block)
  end

  @doc """
  Decode a JSON-RPC quantity into an integer.

  Public because every caller of this module reads quantities out of the maps
  it returns, and a second hex parser in a backend is how one of them ends up
  accepting something this one refuses.
  """
  @spec decode_quantity(term()) :: {:ok, non_neg_integer()} | {:error, Backend.error()}
  def decode_quantity("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {number, ""} -> {:ok, number}
      _unparseable -> {:error, {:decode_failed, :quantity}}
    end
  end

  def decode_quantity(_other), do: {:error, {:decode_failed, :quantity}}

  @doc """
  Encode an integer as a JSON-RPC quantity, which is minimal hex.

  Lower case, because that is what every node in this package's tables emits
  and a value that round-trips through a log or a cache key should compare
  equal to the one it came from.
  """
  @spec encode_quantity(non_neg_integer()) :: String.t()
  def encode_quantity(number) when is_integer(number) and number >= 0 do
    "0x" <> String.downcase(Integer.to_string(number, 16))
  end

  defp do_call(url, method, params, opts) do
    body =
      Jason.encode!(%{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      })

    url
    |> HTTP.post(body, opts |> Keyword.put(:headers, @json_headers) |> classified())
    |> handle_response()
  end

  # A node announces every refusal it has inside a 200, so the cache stage
  # cannot tell a result from a refusal by status and has to be told. Without
  # this, `eth_getBlockByNumber` on a head block answers -32004 once and the
  # `:block` class serves that refusal for the next minute while the node is
  # already caught up, and a -32005 rate limit is served as a cached rate
  # limit after the budget has refilled.
  defp classified(opts) do
    case Keyword.get(opts, :cache) do
      nil -> opts
      spec -> Keyword.put(opts, :cache, Keyword.put_new(spec, :cacheable, &result?/1))
    end
  end

  # The same reading `handle_response/1` makes, and deliberately the same
  # function's worth of it: a body carries an answer when it carries a
  # `result`, and everything else is a refusal, a shape we did not expect, or
  # not JSON at all. None of the three is worth serving from a table later.
  defp result?(%{body: body}), do: match?({:ok, %{"result" => _value}}, Jason.decode(body))

  defp handle_response({:ok, %{status: status, body: body}}) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, {:upstream_refused, rpc_class(error)}}
      {:ok, _other} -> {:error, {:decode_failed, :jsonrpc}}
      {:error, _reason} -> {:error, {:decode_failed, :json}}
    end
  end

  defp handle_response({:ok, %{status: status}}), do: {:error, {:http, status}}
  defp handle_response({:error, _reason} = error), do: error

  # The code is a number we can reason about; the message is upstream prose and
  # stays where it is.
  defp rpc_class(%{"code" => -32_601}), do: :not_found
  defp rpc_class(%{"code" => -32_602}), do: :not_found
  defp rpc_class(%{"code" => code}) when code in [401, -32_001], do: :auth
  defp rpc_class(%{"code" => code}) when code in [429, -32_005], do: :rate_limit
  defp rpc_class(_error), do: :unknown

  # A node answers `null` for a transaction, receipt or block it does not have,
  # and `{:ok, nil}` is that answer rather than an error: a hash nobody has
  # seen is a fact, not a failure. Anything that is neither an object nor
  # `null` is a body that did not say what its shape claimed.
  defp object({:ok, result}, _tag) when is_map(result), do: {:ok, result}
  defp object({:ok, nil}, _tag), do: {:ok, nil}
  defp object({:ok, _unexpected}, tag), do: {:error, {:decode_failed, tag}}
  defp object({:error, _reason} = error, _tag), do: error
end
