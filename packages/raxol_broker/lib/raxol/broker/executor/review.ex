defmodule Raxol.Broker.Executor.Review do
  @moduledoc """
  The review stage: which `review_*` tool an intent goes through, the order
  arguments shared with `Raxol.Broker.Executor.Place`, and the warnings read
  from a review response.

  Only equity orders have a mapping (`review_equity_order`); options and
  advanced orders are refused with `{:error, {:no_adapter, kind}}` before
  anything is journaled. A cancel has no review tool upstream; its review
  record says so and carries no warnings. The review tool must be `:review`
  in the session's `Raxol.Broker.Tools.Catalog` classes, else the review is
  `{:error, {:tool_refused, tool, class}}` and nothing is sent.

  ## Warnings, fail closed

  A response with `isError` set fails the review (no order). Each text
  content block is decoded as JSON. A body is readable only through its
  `"alerts"` and `"warnings"` keys, and each of those that is present must
  hold a list; every entry of those lists is a warning. A `"quote"` alone
  says nothing about warnings. Every entry of an `"errors"` list is a
  warning too. Each of these counts as one warning,
  `"unreadable review response"`, so a response this stage cannot read asks
  a human instead of allowing:

    * empty content (this also covers a server that answers only in
      `structuredContent`, which the client does not expose);
    * a block that is not text or not a JSON object;
    * a JSON object with neither `"alerts"` nor `"warnings"` (including one
      with only a `"quote"`);
    * an `"alerts"`, `"warnings"` or `"errors"` key whose value is `null` or
      anything else that is not a list.

  ## Trade approvals

  Robinhood's `place_equity_order` text says that after a review with
  `customer_approval_required` true, the place call "does not place the
  order: it goes to the customer to approve or decline in the Robinhood app".
  The review record carries that flag as `"customer_approval_required"`: true
  only when a text block decodes to a JSON object holding
  `"customer_approval_required": true`, at its top level or under `"data"`.
  Robinhood answers `{"data": {...}, "guide": "..."}` with the flag in
  `data` (recorded in `test/fixtures/robinhood/review_equity_order.json`).
  Anything else, an absent key included, is false, and
  `Raxol.Broker.Executor.Place` then reads a successful place as an order.

  That recording also shows Robinhood's alerts are `data.order_checks`, an
  object that is `{}` when there are none. This module does not read that
  shape, so a real review is `"unreadable review response"` and asks.
  """

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Intent
  alias Raxol.Broker.Tools.Catalog

  @equity_kinds [:buy_usd, :buy_shares, :sell, :limit, :stop_limit, :stop_market]
  @unreadable "unreadable review response"
  @approval "customer_approval_required"

  @doc "The review tool for `intent`: a name, `:none` for a cancel, or `{:error, {:no_adapter, kind}}`."
  @spec tool(Intent.t()) :: {:ok, String.t() | :none} | {:error, {:no_adapter, atom()}}
  def tool(%Intent{kind: :cancel}), do: {:ok, :none}

  def tool(%Intent{kind: kind} = intent),
    do: if(equity?(intent), do: {:ok, "review_equity_order"}, else: {:error, {:no_adapter, kind}})

  @doc "Is `intent` an equity order (not a cancel)? The single list of equity kinds."
  @spec equity?(Intent.t()) :: boolean()
  def equity?(%Intent{kind: kind}), do: kind in @equity_kinds

  @doc """
  Did the review recorded as `response` say the order needs the owner's
  approval in the Robinhood app? See "Trade approvals" in the moduledoc.
  """
  @spec customer_approval_required?(map()) :: boolean()
  def customer_approval_required?(response) when is_map(response),
    do: Map.get(response, @approval) == true

  @doc """
  Run the review for `intent` on `port`, whose tool classes are `catalog`.
  Returns `{:ok, response, warnings}` where `response` is the string-keyed
  map journaled as the review record.
  """
  @spec run(Port.t(), Catalog.session(), Intent.t(), String.t(), timeout()) ::
          {:ok, map(), [String.t()]} | {:error, term()}
  def run(port, catalog, %Intent{} = intent, account, timeout) do
    case tool(intent) do
      {:ok, :none} ->
        {:ok, %{"tool" => nil, "note" => "cancel has no review tool"}, []}

      {:ok, tool} ->
        with :ok <- Catalog.permit(catalog, tool, :review) do
          port |> Port.call(tool, order_args(intent, account), timeout) |> read(tool)
        end

      {:error, _} = error ->
        error
    end
  end

  defp read({:ok, %{is_error: false, content: content}}, tool) when is_list(content) do
    bodies = Enum.map(content, &body/1)

    response = %{
      "tool" => tool,
      "is_error" => false,
      "content" => content,
      @approval => Enum.any?(bodies, &approval_required?/1)
    }

    {:ok, response, bodies_warnings(bodies)}
  end

  defp read({:ok, %{is_error: true}}, tool), do: {:error, {:review_failed, tool, :is_error}}
  defp read({:ok, _other}, tool), do: {:error, {:review_failed, tool, :invalid_response}}
  defp read({:error, reason}, tool), do: {:error, {:review_failed, tool, reason}}

  defp body(%{"type" => "text", "text" => text}) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = body} -> body
      _ -> :unreadable
    end
  end

  defp body(_block), do: :unreadable

  defp approval_required?(%{@approval => true}), do: true
  defp approval_required?(%{"data" => %{@approval => true}}), do: true
  defp approval_required?(_body), do: false

  defp bodies_warnings([]), do: [@unreadable]
  defp bodies_warnings(bodies), do: Enum.flat_map(bodies, &warnings/1)

  defp warnings(:unreadable), do: [@unreadable]
  defp warnings(body), do: body_warnings(body) ++ error_warnings(body)

  defp body_warnings(body) do
    case Enum.filter(["alerts", "warnings"], &is_map_key(body, &1)) do
      [] -> [@unreadable]
      keys -> Enum.flat_map(keys, &listed(Map.fetch!(body, &1)))
    end
  end

  defp error_warnings(%{"errors" => errors}), do: listed(errors)
  defp error_warnings(_body), do: []

  defp listed(list) when is_list(list), do: Enum.map(list, &describe/1)
  defp listed(_other), do: [@unreadable]

  defp describe(text) when is_binary(text), do: text
  defp describe(%{"message" => text}) when is_binary(text), do: text
  defp describe(other), do: Jason.encode!(other)

  @doc """
  The arguments of an equity order for `intent` against `account`, as the
  review and place tools take them (all values strings). Cancels take the
  broker order id.
  """
  @spec order_args(Intent.t(), String.t()) :: map()
  def order_args(%Intent{kind: :cancel, order_id: order_id}, account),
    do: %{"account_number" => account, "order_id" => order_id}

  def order_args(%Intent{} = intent, account) do
    %{
      "account_number" => account,
      "symbol" => intent.symbol,
      "side" => Atom.to_string(intent.side)
    }
    |> Map.merge(kind_args(intent))
  end

  defp kind_args(%Intent{kind: :buy_usd, notional: usd}),
    do: %{"type" => "market", "dollar_amount" => dec(usd)}

  defp kind_args(%Intent{kind: kind, qty: qty}) when kind in [:buy_shares, :sell],
    do: %{"type" => "market", "quantity" => dec(qty)}

  defp kind_args(%Intent{kind: :limit, qty: qty, limit: limit}),
    do: %{"type" => "limit", "quantity" => dec(qty), "limit_price" => dec(limit)}

  defp kind_args(%Intent{kind: :stop_limit} = intent) do
    %{
      "type" => "stop_limit",
      "quantity" => dec(intent.qty),
      "limit_price" => dec(intent.limit),
      "stop_price" => dec(intent.stop)
    }
  end

  defp kind_args(%Intent{kind: :stop_market, qty: qty, stop: stop}),
    do: %{"type" => "stop_market", "quantity" => dec(qty), "stop_price" => dec(stop)}

  defp dec(%Decimal{} = value), do: Decimal.to_string(value, :normal)
end
