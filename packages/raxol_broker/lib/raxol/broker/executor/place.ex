defmodule Raxol.Broker.Executor.Place do
  @moduledoc """
  The only module that names an order-writing tool (`place_equity_order`,
  `cancel_equity_order`) or sends one. A test greps the package for those
  names outside this file.

  `run/4` re-checks everything itself, whatever its caller checked:

    1. the `Raxol.Broker.Executor.ReviewReceipt` verifies under the
       executor's key for this intent id and group id, and its nonce is not
       in the spent set;
    2. the intent has an order tool (equity orders and cancels until #1174);
    3. `{:placing}` is journaled; any journal error means no call;
    4. the tool is called once, with `ref_id` (a UUID derived from the intent
       id) on a place, which Robinhood deduplicates on;
    5. the response is journaled as `{:order, status, response}`.

  Status is `:placed` for a result without `isError`, `:failed` for a result
  with `isError` or a JSON-RPC error the server answered, and `:unknown`
  for everything else (timeout, transport failure, port exit): the order may
  exist, and it keeps counting.
  """

  alias Raxol.Broker.Executor.{Port, Review, ReviewReceipt}
  alias Raxol.Broker.{Intent, Journal}

  @equity_kinds [:buy_usd, :buy_shares, :sell, :limit, :stop_limit, :stop_market]

  @type env :: %{
          key: binary(),
          spent: MapSet.t(binary()),
          port: Port.t(),
          journal: Journal.server(),
          account: String.t(),
          timeout: timeout()
        }
  @type status :: :placed | :failed | :unknown
  @type outcome :: {:ok, status(), map()} | {:error, term()}

  @doc """
  Place (or cancel) `intent` for journal group `group_id` with `receipt`.

  `{:error, :invalid_receipt | :receipt_spent}` when the receipt fails;
  nothing is journaled or sent. Otherwise `{:spent, nonce, outcome}`: the
  receipt is used up whatever happened next, and `outcome` is
  `{:ok, status, response}` or `{:error, reason}` (no call was made unless
  the reason is `{:order_unjournaled, status, _}`).
  """
  @spec run(ReviewReceipt.t(), Intent.t(), String.t(), env()) ::
          {:spent, binary(), outcome()} | {:error, :invalid_receipt | :receipt_spent}
  def run(receipt, %Intent{id: intent_id} = intent, group_id, env) do
    with {:ok, nonce} <- ReviewReceipt.verify(receipt, env.key, intent_id, group_id),
         :ok <- unspent(nonce, env.spent) do
      {:spent, nonce, place(intent, group_id, env)}
    end
  end

  defp unspent(nonce, spent),
    do: if(MapSet.member?(spent, nonce), do: {:error, :receipt_spent}, else: :ok)

  defp place(intent, group_id, env) do
    with {:ok, tool, args} <- call_for(intent, env.account),
         :ok <- journal(group_id, {:placing}, env.journal) do
      {status, response} = env.port |> Port.call(tool, args, env.timeout) |> classify(tool)

      case journal(group_id, {:order, status, response}, env.journal) do
        :ok -> {:ok, status, response}
        {:error, reason} -> {:error, {:order_unjournaled, status, reason}}
      end
    end
  end

  defp call_for(%Intent{kind: :cancel} = intent, account),
    do: {:ok, "cancel_equity_order", Review.order_args(intent, account)}

  defp call_for(%Intent{kind: kind} = intent, account) when kind in @equity_kinds do
    args = Map.put(Review.order_args(intent, account), "ref_id", ref_id(intent.id))
    {:ok, "place_equity_order", args}
  end

  defp call_for(%Intent{kind: kind}, _account), do: {:error, {:no_adapter, kind}}

  defp journal(group_id, entry, journal) do
    Journal.append_to_group(group_id, entry, journal)
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end

  defp classify({:ok, %{is_error: false, content: content}}, tool),
    do: {:placed, %{"tool" => tool, "is_error" => false, "content" => content}}

  defp classify({:ok, %{is_error: true, content: content}}, tool),
    do: {:failed, %{"tool" => tool, "is_error" => true, "content" => content}}

  defp classify({:error, %{"code" => code} = error}, tool) when is_integer(code),
    do: {:failed, %{"tool" => tool, "error" => error}}

  defp classify(other, tool), do: {:unknown, %{"tool" => tool, "error" => inspect(other)}}

  @doc """
  The `ref_id` sent with a place: a version-8 UUID from the SHA-256 of the
  intent id, so every attempt at one intent carries the same key.
  """
  @spec ref_id(String.t()) :: String.t()
  def ref_id(intent_id) when is_binary(intent_id) do
    <<a::48, _v::4, b::12, _r::2, c::62, _rest::binary>> =
      :crypto.hash(:sha256, "raxol.broker.ref_id:" <> intent_id)

    <<a::48, 8::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end
end
