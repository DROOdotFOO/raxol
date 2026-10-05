defmodule Raxol.Broker.Journal.Codec do
  @moduledoc """
  JSON forms of what `Raxol.Broker.Journal` records.

  Decimals are written as strings with their exact digits and exponent
  (`Decimal.to_string/1`), so they read back equal. The journal is hash-chained
  and refuses JSON floats, so nothing here produces one: floats inside opaque
  terms (order and review responses, params) are written as strings
  (`term/1`).

    * `%Raxol.Broker.Intent{}` and `%Raxol.Broker.Policy.Context{}` round-trip:
      `decode_intent(encode_intent(i)) == {:ok, i}`, and the same for a context
      whose fields have the types the policy accepts. Atoms are decoded only
      from fixed lists or with `String.to_existing_atom/1`, never minted.
      Option and advanced `params`, and the context's `review_warnings`, are
      kept as the JSON they encode to.
    * Policy results (`Raxol.Broker.Policy.evaluate/2`) are one-way: atoms and
      tuples in a DENY detail become strings and arrays. Two results are the
      same decision when their encodings are equal.
  """

  alias Raxol.Broker.Intent
  alias Raxol.Broker.Policy.Context

  @sides [:buy, :sell]
  @provenances [:strategy, :llm, :human]
  @sessions [:regular, :extended, :closed]
  @intent_decimals [:qty, :notional, :limit, :stop]
  @context_decimals [:portfolio_value, :start_of_day_value, :day_pnl, :today_notional]

  # -- Intent -----------------------------------------------------------------

  @doc "Encode an intent as a JSON-ready map."
  @spec encode_intent(Intent.t()) :: map()
  def encode_intent(%Intent{} = intent) do
    decimals = Map.new(@intent_decimals, &{Atom.to_string(&1), decimal(Map.fetch!(intent, &1))})

    Map.merge(decimals, %{
      "id" => intent.id,
      "kind" => Atom.to_string(intent.kind),
      "side" => atom_or_nil(intent.side),
      "symbol" => intent.symbol,
      "order_id" => intent.order_id,
      "params" => term(intent.params),
      "provenance" => provenance(intent.provenance),
      "strategy" => named(intent.strategy)
    })
  end

  @doc "Decode a map written by `encode_intent/1`."
  @spec decode_intent(term()) :: {:ok, Intent.t()} | {:error, {:bad_intent, atom()}}
  def decode_intent(%{} = map) do
    decoders = intent_decoders() ++ decimal_decoders(@intent_decimals, :bad_intent)
    with {:ok, fields} <- decode_fields(map, decoders), do: {:ok, struct!(Intent, fields)}
  end

  def decode_intent(_other), do: {:error, {:bad_intent, :not_a_map}}

  defp intent_decoders do
    [
      kind: &one_of(&1, Intent.kinds(), :kind),
      side: &optional_one_of(&1, @sides, :side),
      provenance: &decode_provenance/1,
      strategy: &decode_named(&1, :strategy),
      id: &string(&1, false, {:bad_intent, :id}),
      symbol: &string(&1, true, {:bad_intent, :symbol}),
      order_id: &string(&1, true, {:bad_intent, :order_id}),
      params: &json_map(&1, {:bad_intent, :params})
    ]
  end

  defp provenance(value) when value in @provenances, do: Atom.to_string(value)
  defp provenance({:untrusted, source}), do: %{"untrusted" => named(source)}

  defp decode_provenance(%{"untrusted" => source}) do
    case decode_named(source, :provenance) do
      {:ok, nil} -> {:error, {:bad_intent, :provenance}}
      {:ok, source} -> {:ok, {:untrusted, source}}
      error -> error
    end
  end

  defp decode_provenance(value), do: one_of(value, @provenances, :provenance)

  # An atom-or-string field (strategy, untrusted source): strings stay
  # strings, atoms are tagged so they come back as atoms.
  defp named(nil), do: nil
  defp named(value) when is_atom(value), do: %{"atom" => Atom.to_string(value)}
  defp named(value) when is_binary(value), do: value

  defp decode_named(nil, _field), do: {:ok, nil}
  defp decode_named(value, _field) when is_binary(value), do: {:ok, value}

  defp decode_named(%{"atom" => name}, field) when is_binary(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, {:bad_intent, field}}
  end

  defp decode_named(_value, field), do: {:error, {:bad_intent, field}}

  defp string(nil, true = _optional?, _error), do: {:ok, nil}
  defp string(value, _optional?, _error) when is_binary(value), do: {:ok, value}
  defp string(_value, _optional?, error), do: {:error, error}

  defp json_map(value, _error) when is_map(value), do: {:ok, value}
  defp json_map(_value, error), do: {:error, error}

  # -- Context ----------------------------------------------------------------

  @doc "Encode a policy context (policy, prices, counters) as a JSON-ready map."
  @spec encode_context(Context.t()) :: map()
  def encode_context(%Context{} = context) do
    decimals = Map.new(@context_decimals, &{Atom.to_string(&1), decimal(Map.fetch!(context, &1))})

    Map.merge(decimals, %{
      "policy" => encode_policy(context.policy),
      "positions" => price_map(context.positions),
      "quotes" => price_map(context.quotes),
      "orders_last_minute" => term(context.orders_last_minute),
      "market_session" => atom_or_nil(context.market_session),
      "review_warnings" => term(context.review_warnings)
    })
  end

  @doc "Decode a map written by `encode_context/1`."
  @spec decode_context(term()) :: {:ok, Context.t()} | {:error, {:bad_context, atom()}}
  def decode_context(%{} = map) do
    decoders = context_decoders() ++ decimal_decoders(@context_decimals, :bad_context)
    with {:ok, fields} <- decode_fields(map, decoders), do: {:ok, struct!(Context, fields)}
  end

  def decode_context(_other), do: {:error, {:bad_context, :not_a_map}}

  defp context_decoders do
    [
      policy: &decode_policy/1,
      positions: &decode_price_map(&1, :positions),
      quotes: &decode_price_map(&1, :quotes),
      market_session: &session/1,
      orders_last_minute: &decode_count/1,
      review_warnings: &json_list/1
    ]
  end

  defp price_map(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {term_key(k), decimal(v)} end)

  defp price_map(other), do: term(other)

  defp decode_price_map(map, field) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {symbol, value}, {:ok, acc} ->
      case parse_decimal(value) do
        {:ok, decimal} -> {:cont, {:ok, Map.put(acc, symbol, decimal)}}
        :error -> {:halt, {:error, {:bad_context, field}}}
      end
    end)
  end

  defp decode_price_map(_value, field), do: {:error, {:bad_context, field}}

  defp decode_count(nil), do: {:ok, nil}
  defp decode_count(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp decode_count(_value), do: {:error, {:bad_context, :orders_last_minute}}

  defp session(value) do
    case optional_one_of(value, @sessions, :market_session) do
      {:ok, session} -> {:ok, session}
      {:error, _} -> {:error, {:bad_context, :market_session}}
    end
  end

  defp json_list(value) when is_list(value), do: {:ok, value}
  defp json_list(_value), do: {:error, {:bad_context, :review_warnings}}

  # The policy keyword list keeps its order as [key, value] pairs. Values are
  # tagged where JSON alone is ambiguous: Decimals and atoms (`:unset`, order
  # types). Keys and atoms decode through existing atoms only.
  defp encode_policy(nil), do: nil

  defp encode_policy(policy) when is_list(policy) do
    Enum.map(policy, fn
      {key, value} when is_atom(key) -> [Atom.to_string(key), policy_value(value)]
      other -> term(other)
    end)
  end

  defp encode_policy(other), do: term(other)

  defp policy_value(%Decimal{} = d), do: %{"decimal" => Decimal.to_string(d)}
  defp policy_value(value) when is_boolean(value) or is_nil(value), do: value
  defp policy_value(value) when is_atom(value), do: %{"atom" => Atom.to_string(value)}
  defp policy_value(list) when is_list(list), do: Enum.map(list, &policy_value/1)
  defp policy_value(value), do: term(value)

  defp decode_policy(nil), do: {:ok, nil}

  defp decode_policy(pairs) when is_list(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn
      [key, value], {:ok, acc} when is_binary(key) ->
        with {:ok, key} <- existing_atom(key),
             {:ok, value} <- decode_policy_value(value) do
          {:cont, {:ok, [{key, value} | acc]}}
        else
          :error -> {:halt, {:error, {:bad_context, :policy}}}
        end

      _pair, _acc ->
        {:halt, {:error, {:bad_context, :policy}}}
    end)
    |> case do
      {:ok, policy} -> {:ok, Enum.reverse(policy)}
      error -> error
    end
  end

  defp decode_policy(_value), do: {:error, {:bad_context, :policy}}

  defp decode_policy_value(%{"decimal" => d}) do
    case parse_decimal(d) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> :error
    end
  end

  defp decode_policy_value(%{"atom" => name}) when is_binary(name), do: existing_atom(name)

  defp decode_policy_value(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
      case decode_policy_value(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      :error -> :error
    end
  end

  defp decode_policy_value(value)
       when is_boolean(value) or is_nil(value) or is_integer(value) or is_binary(value),
       do: {:ok, value}

  defp decode_policy_value(_value), do: :error

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # -- Policy results -----------------------------------------------------------

  @doc """
  Encode a `Raxol.Broker.Policy.evaluate/2` result. `{:error, {:invalid_result,
  value}}` for anything else, so a malformed verdict is never journaled as one.
  """
  @spec encode_result(term()) :: {:ok, map()} | {:error, {:invalid_result, term()}}
  def encode_result({:allow, %Intent{}}), do: {:ok, %{"action" => "allow"}}

  def encode_result({:ask, [_ | _] = asks} = result) do
    if Enum.all?(asks, &match?({rule, prompt} when is_atom(rule) and is_binary(prompt), &1)) do
      {:ok,
       %{
         "action" => "ask",
         "asks" =>
           Enum.map(asks, fn {rule, prompt} ->
             %{"rule" => Atom.to_string(rule), "prompt" => prompt}
           end)
       }}
    else
      {:error, {:invalid_result, result}}
    end
  end

  def encode_result({:deny, {rule, detail}}) when is_atom(rule),
    do: {:ok, %{"action" => "deny", "rule" => Atom.to_string(rule), "detail" => term(detail)}}

  def encode_result(other), do: {:error, {:invalid_result, other}}

  # -- Shared -----------------------------------------------------------------

  @doc """
  One-way JSON form of an arbitrary term: Decimals and DateTimes as strings,
  atoms as strings (`true`, `false` and `nil` stay JSON literals), tuples as
  arrays, structs as their fields, map keys as strings, anything else that has
  no JSON form (pids, functions, non-UTF-8 binaries) as `inspect/1` text.

  Floats become strings of their shortest round-tripping digits
  (`:erlang.float_to_binary(f, [:short])`, so `125.01` is `"125.01"`): the
  chained journal refuses JSON floats, whose text form is not canonical, and
  an order or review response must always be recordable. Integers stay
  numbers.
  """
  @spec term(term()) :: term()
  def term(%Decimal{} = d), do: Decimal.to_string(d)
  def term(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  def term(%_{} = struct), do: struct |> Map.from_struct() |> term()
  def term(map) when is_map(map), do: Map.new(map, fn {k, v} -> {term_key(k), term(v)} end)
  def term(list) when is_list(list), do: Enum.map(list, &term/1)
  def term(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> term()
  def term(value) when is_boolean(value) or is_nil(value), do: value
  def term(atom) when is_atom(atom), do: Atom.to_string(atom)
  def term(float) when is_float(float), do: :erlang.float_to_binary(float, [:short])
  def term(integer) when is_integer(integer), do: integer

  def term(binary) when is_binary(binary),
    do: if(String.valid?(binary), do: binary, else: inspect(binary))

  def term(other), do: inspect(other, structs: false)

  defp term_key(key) when is_binary(key), do: key
  defp term_key(key) when is_atom(key), do: Atom.to_string(key)
  defp term_key(key), do: inspect(key)

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal(other), do: term(other)

  # Decode each `{field, decoder}` from the map's string key of the same name,
  # in order, into a keyword list; the first decoder error stops the walk.
  defp decode_fields(map, decoders) do
    Enum.reduce_while(decoders, {:ok, []}, fn {field, decode}, {:ok, acc} ->
      case decode.(map[Atom.to_string(field)]) do
        {:ok, value} -> {:cont, {:ok, [{field, value} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp decimal_decoders(fields, tag),
    do: Enum.map(fields, fn field -> {field, &optional_decimal(&1, {tag, field})} end)

  defp optional_decimal(nil, _error), do: {:ok, nil}

  defp optional_decimal(value, error) do
    case parse_decimal(value) do
      {:ok, decimal} -> {:ok, decimal}
      :error -> {:error, error}
    end
  end

  defp parse_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp parse_decimal(_value), do: :error

  defp atom_or_nil(nil), do: nil
  defp atom_or_nil(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp atom_or_nil(other), do: term(other)

  defp one_of(value, allowed, field) when is_binary(value) do
    case Enum.find(allowed, &(Atom.to_string(&1) == value)) do
      nil -> {:error, {:bad_intent, field}}
      atom -> {:ok, atom}
    end
  end

  defp one_of(_value, _allowed, field), do: {:error, {:bad_intent, field}}

  defp optional_one_of(nil, _allowed, _field), do: {:ok, nil}
  defp optional_one_of(value, allowed, field), do: one_of(value, allowed, field)
end
