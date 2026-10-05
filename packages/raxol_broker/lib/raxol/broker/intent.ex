defmodule Raxol.Broker.Intent do
  @moduledoc """
  A request to trade, before any policy, review, or order.

  Every order, whoever proposes it, enters the broker as an intent. Build one
  with a constructor; each returns `{:ok, intent}` or `{:error, reason}` and
  never raises, because intents can come from model output.

  | Kind | Constructor | Order type | Notional |
  | --- | --- | --- | --- |
  | `:buy_usd` | `buy_usd/3` | `:market` | the dollar amount |
  | `:buy_shares` | `buy_shares/3` | `:market` | `qty` x quote |
  | `:sell` | `sell/3` | `:market` | `qty` x quote |
  | `:limit` | `limit/5` | `:limit` | `qty` x `limit` |
  | `:stop_limit` | `stop_limit/6` | `:stop_limit` | `qty` x `limit` |
  | `:stop_market` | `stop_market/5` | `:stop_market` | `qty` x `stop` |
  | `:option` | `option/4` | options | the stated maximum notional |
  | `:advanced` | `advanced/4` | advanced | the stated maximum notional |
  | `:cancel` | `cancel/2` | none | none |

  Options and advanced orders carry an explicit `notional` because their
  exposure is not derivable from a share price; adapter-specific arguments go
  in `params` and are never read by the policy.

  Options common to every constructor:

    * `:provenance` (required) -- `:strategy`, `:llm`, `:human`, or
      `{:untrusted, source}` with an atom or string source.
    * `:strategy` -- the proposing strategy's name, an atom or string.
    * `:id` -- a caller-chosen identifier (string); random when omitted.
  """

  alias Raxol.Broker.Plain

  @kinds [
    :buy_usd,
    :buy_shares,
    :sell,
    :limit,
    :stop_limit,
    :stop_market,
    :option,
    :advanced,
    :cancel
  ]
  @symbol ~r/\A[A-Z0-9][A-Z0-9.\-]{0,15}\z/
  @max_id_bytes 128

  @type kind ::
          :buy_usd
          | :buy_shares
          | :sell
          | :limit
          | :stop_limit
          | :stop_market
          | :option
          | :advanced
          | :cancel
  @type side :: :buy | :sell
  @type provenance :: :strategy | :llm | :human | {:untrusted, atom() | String.t()}
  @type reason ::
          {:missing_option, :provenance}
          | {:invalid, atom(), term()}

  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          side: side() | nil,
          symbol: String.t() | nil,
          qty: Decimal.t() | nil,
          notional: Decimal.t() | nil,
          limit: Decimal.t() | nil,
          stop: Decimal.t() | nil,
          order_id: String.t() | nil,
          params: map(),
          provenance: provenance(),
          strategy: atom() | String.t() | nil
        }

  @enforce_keys [:id, :kind, :provenance]
  defstruct [
    :id,
    :kind,
    :side,
    :symbol,
    :qty,
    :notional,
    :limit,
    :stop,
    :order_id,
    :provenance,
    :strategy,
    params: %{}
  ]

  @doc "Every intent kind."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  @doc "Is `value` an uppercase ticker or crypto pair, 1-16 characters?"
  @spec symbol?(term()) :: boolean()
  def symbol?(value), do: is_binary(value) and Regex.match?(@symbol, value)

  @doc "Market buy for a dollar amount."
  @spec buy_usd(String.t(), Decimal.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def buy_usd(symbol, notional, opts),
    do: build(:buy_usd, opts, side: :buy, symbol: symbol, notional: notional)

  @doc "Market buy for a share quantity."
  @spec buy_shares(String.t(), Decimal.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def buy_shares(symbol, qty, opts),
    do: build(:buy_shares, opts, side: :buy, symbol: symbol, qty: qty)

  @doc "Market sell for a share quantity."
  @spec sell(String.t(), Decimal.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def sell(symbol, qty, opts), do: build(:sell, opts, side: :sell, symbol: symbol, qty: qty)

  @doc "Limit order."
  @spec limit(side(), String.t(), Decimal.t(), Decimal.t(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def limit(side, symbol, qty, limit, opts),
    do: build(:limit, opts, side: side, symbol: symbol, qty: qty, limit: limit)

  @doc "Stop-limit order."
  @spec stop_limit(side(), String.t(), Decimal.t(), Decimal.t(), Decimal.t(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def stop_limit(side, symbol, qty, stop, limit, opts),
    do: build(:stop_limit, opts, side: side, symbol: symbol, qty: qty, stop: stop, limit: limit)

  @doc "Stop-market order."
  @spec stop_market(side(), String.t(), Decimal.t(), Decimal.t(), keyword()) ::
          {:ok, t()} | {:error, reason()}
  def stop_market(side, symbol, qty, stop, opts),
    do: build(:stop_market, opts, side: side, symbol: symbol, qty: qty, stop: stop)

  @doc "Options order with its maximum notional. `opts[:params]` goes to the adapter."
  @spec option(side(), String.t(), Decimal.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def option(side, symbol, notional, opts),
    do: build(:option, opts, side: side, symbol: symbol, notional: notional)

  @doc "Advanced order with its maximum notional. `opts[:params]` goes to the adapter."
  @spec advanced(side(), String.t(), Decimal.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def advanced(side, symbol, notional, opts),
    do: build(:advanced, opts, side: side, symbol: symbol, notional: notional)

  @doc "Cancel an open order by its broker order id."
  @spec cancel(String.t(), keyword()) :: {:ok, t()} | {:error, reason()}
  def cancel(order_id, opts), do: build(:cancel, opts, order_id: order_id)

  @doc """
  Rebuild `term` as an intent from validated plain fields.

  Accepts any term and never raises or dispatches a protocol on it, so it is
  safe on caller data in the process that will act on the result. Every field
  passes `Raxol.Broker.Plain` first, then the same checks the constructors
  apply. Errors never echo the offending value: `{:not_plain, path}` names
  where non-plain data sits, `{:invalid, field}` names a field of the wrong
  shape, `:not_an_intent` means `term` is not an `%Intent{}` at all.
  """
  @spec normalize(term()) ::
          {:ok, t()}
          | {:error, :not_an_intent | {:invalid, atom()} | {:not_plain, Plain.path()}}
  def normalize(%{__struct__: __MODULE__} = intent) do
    with {:ok, fields} <- plain_fields(intent),
         {:ok, intent} <- rebuild(fields) do
      {:ok, intent}
    else
      {:error, {:invalid, field, _value}} -> {:error, {:invalid, field}}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_term), do: {:error, :not_an_intent}

  defp rebuild(fields) do
    with {:ok, common} <- common_fields(fields),
         {:ok, order_fields} <- validate_fields(present_order_fields(fields)) do
      {:ok, struct!(__MODULE__, common ++ order_fields)}
    end
  end

  defp common_fields(%{kind: kind, provenance: provenance, strategy: strategy, id: id} = fields) do
    with :ok <- check_kind(kind),
         {:ok, provenance} <- provenance(provenance: provenance),
         {:ok, strategy} <- strategy(strategy),
         {:ok, id} <- normalize_id(id),
         {:ok, params} <- params(kind, :maps.get(:params, fields)) do
      {:ok, [kind: kind, id: id, provenance: provenance, strategy: strategy, params: params]}
    end
  end

  @fields [
    :id,
    :kind,
    :side,
    :symbol,
    :qty,
    :notional,
    :limit,
    :stop,
    :order_id,
    :provenance,
    :strategy,
    :params
  ]
  @order_fields [:side, :symbol, :qty, :notional, :limit, :stop, :order_id]

  defp plain_fields(intent), do: plain_fields(@fields, intent, %{})

  defp plain_fields([], _intent, acc), do: {:ok, acc}

  defp plain_fields([field | rest], intent, acc) do
    value = if is_map_key(intent, field), do: :maps.get(field, intent)

    case Plain.normalize(value) do
      {:ok, value} -> plain_fields(rest, intent, :maps.put(field, value, acc))
      {:error, {:not_plain, path}} -> {:error, {:not_plain, [field | path]}}
    end
  end

  defp check_kind(kind) when kind in @kinds, do: :ok
  defp check_kind(_kind), do: {:error, {:invalid, :kind}}

  defp normalize_id(value) when is_binary(value), do: id(value)
  defp normalize_id(_value), do: {:error, {:invalid, :id}}

  defp present_order_fields(fields) do
    for key <- @order_fields, :maps.get(key, fields) != nil, do: {key, :maps.get(key, fields)}
  end

  # -- Construction -----------------------------------------------------------

  defp build(kind, opts, fields) do
    with {:ok, provenance} <- provenance(opts),
         {:ok, strategy} <- strategy(Keyword.get(opts, :strategy)),
         {:ok, id} <- id(Keyword.get(opts, :id)),
         {:ok, params} <- params(kind, Keyword.get(opts, :params, %{})),
         {:ok, fields} <- validate_fields(fields) do
      {:ok,
       struct!(
         __MODULE__,
         [kind: kind, id: id, provenance: provenance, strategy: strategy, params: params] ++
           fields
       )}
    end
  end

  defp provenance(opts) do
    case Keyword.fetch(opts, :provenance) do
      {:ok, value} when value in [:strategy, :llm, :human] -> {:ok, value}
      {:ok, {:untrusted, source} = value} when is_atom(source) -> {:ok, value}
      {:ok, {:untrusted, source} = value} when is_binary(source) -> {:ok, value}
      {:ok, value} -> {:error, {:invalid, :provenance, value}}
      :error -> {:error, {:missing_option, :provenance}}
    end
  end

  defp strategy(value) when is_nil(value) or is_atom(value) or is_binary(value), do: {:ok, value}
  defp strategy(value), do: {:error, {:invalid, :strategy, value}}

  defp id(nil), do: {:ok, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}

  defp id(value) when is_binary(value) and value != "" and byte_size(value) <= @max_id_bytes,
    do: {:ok, value}

  defp id(value), do: {:error, {:invalid, :id, value}}

  defp params(kind, value) when kind in [:option, :advanced] and is_map(value), do: {:ok, value}
  defp params(_kind, value) when value == %{}, do: {:ok, %{}}
  defp params(_kind, value), do: {:error, {:invalid, :params, value}}

  defp validate_fields(fields) do
    Enum.reduce_while(fields, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case validate_field(key, value) do
        {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
        :error -> {:halt, {:error, {:invalid, key, value}}}
      end
    end)
  end

  defp validate_field(:side, side) when side in [:buy, :sell], do: {:ok, side}

  defp validate_field(:symbol, symbol) when is_binary(symbol) do
    normalized = symbol |> String.trim() |> String.upcase()
    if symbol?(normalized), do: {:ok, normalized}, else: :error
  end

  defp validate_field(:order_id, order_id)
       when is_binary(order_id) and order_id != "" and byte_size(order_id) <= @max_id_bytes,
       do: {:ok, order_id}

  defp validate_field(key, %Decimal{coef: coefficient} = value)
       when key in [:qty, :notional, :limit, :stop] and is_integer(coefficient) do
    if Decimal.gt?(value, 0), do: {:ok, value}, else: :error
  end

  defp validate_field(_key, _value), do: :error
end
