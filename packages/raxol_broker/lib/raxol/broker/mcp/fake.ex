defmodule Raxol.Broker.MCP.Fake do
  @moduledoc """
  Robinhood's agent MCP server, in process and scripted: the backend for the
  broker's tests, dry runs and backtests, so nothing here needs a funded US
  account or the network.

  It is the legacy-era reference server (`Raxol.MCP.Client.ReferenceServer`:
  `initialize`, `Mcp-Session-Id`, real JSON-RPC) reached through the HTTP
  transport's `:exchange` seam, so the client's whole pre-socket pipeline runs
  for real. `session/1` is a `Raxol.Broker.Executor.Port.MCP` spec (marked
  sandbox); `mcp_opts/1` is the `:mcp` option for `Raxol.Broker.MCP.Client`.

  ## Tools

  The tool list Robinhood served on 2026-10-02 (`priv/robinhood/tools_list.json`,
  sanitized to five tools), plus three read-only tools the scenario answers
  that the sanitized capture omits: `get_equity_positions`,
  `get_equity_orders` and `get_alert_log`. Their schemas are not recorded
  (`{"type": "object"}`); their answers are this module's shapes, not
  Robinhood's.

  ## Scenario

  `scenario/1` (or `start/1` directly) takes:

    * `:account` - the one tradable account `get_accounts` lists
      (default `"FAKE-0001"`).
    * `:quotes` - `%{symbol => price}`; `get_equity_quotes` and every review
      quote it. A symbol not listed is omitted from the answer.
    * `:positions` - maps, answered by `get_equity_positions`.
    * `:alerts` - fired alerts, answered by `get_alert_log`.
    * `:warnings` - the `"alerts"` every `review_*` returns (default `[]`).
    * `:reject` - symbols whose `place_*` answers `isError: true`.
    * `:order_states` - the states a placed order moves through, one step per
      `get_equity_orders` call (default `["queued"]`). `cancel_*` moves an
      order to `"cancelled"`.
    * `:faults` - see below.

  `place_*` is idempotent on `ref_id`, as Robinhood documents it: the same
  `ref_id` answers the same order and creates no second one.

  ## Faults

  Each fault is `{match, fault}` or `{match, fault, times}` (default once).
  `match` is a tool name, a JSON-RPC method (`"initialize"`), or `:any`. The
  first entry matching a request is consumed; a faulted request never reaches
  the scenario, so it places nothing and is not in `calls/1`.

    * `{:http, status}` or `{:http, status, retry_after_seconds}` - an HTTP
      error (429, 5xx), with `Retry-After` when given.
    * `:malformed` - a 200 whose body is not JSON.
    * `{:slow, ms}` - answers normally after `ms`.
    * `:closed` - a transport failure: no response at all.

  Every exchange is in `requests/1` with its status; every `tools/call` that
  reached the scenario is in `calls/1` with its arguments.
  """

  alias Raxol.MCP.Client.ReferenceServer
  alias Raxol.MCP.Client.ReferenceServer.Legacy

  @tools_path Path.expand("../../../../priv/robinhood/tools_list.json", __DIR__)
  @external_resource @tools_path
  @recorded_tools @tools_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @scenario_tools for name <- ~w(get_equity_positions get_equity_orders get_alert_log),
                      do: %{
                        "name" => name,
                        "description" => "Fake: answered from the scenario.",
                        "inputSchema" => %{"type" => "object"},
                        "annotations" => %{"readOnlyHint" => true}
                      }

  @keys [:account, :quotes, :positions, :alerts, :warnings, :reject, :order_states, :faults]

  @type fault ::
          {:http, pos_integer()}
          | {:http, pos_integer(), non_neg_integer()}
          | :malformed
          | {:slow, non_neg_integer()}
          | :closed
  @type scenario :: %{atom() => term()}

  @doc "The tool list recorded from Robinhood on 2026-10-02 (sanitized)."
  @spec recorded_tools() :: [map()]
  def recorded_tools, do: @recorded_tools

  @doc "Every tool the Fake serves: the recorded list plus the scenario tools."
  @spec tools() :: [map()]
  def tools, do: @recorded_tools ++ @scenario_tools

  @doc "Validate a scenario. Raises `ArgumentError` on an unknown key or bad value."
  @spec scenario(keyword()) :: scenario()
  def scenario(opts) when is_list(opts) do
    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Fake scenario keys: #{inspect(unknown)}"
    end

    lists = Map.new([:positions, :alerts, :warnings, :reject, :faults], &{&1, list!(opts, &1)})

    %{
      account: string!(Keyword.get(opts, :account, "FAKE-0001"), :account),
      quotes: quotes!(Keyword.get(opts, :quotes, %{})),
      order_states: states!(Keyword.get(opts, :order_states, ["queued"]))
    }
    |> Map.merge(lists)
    |> Map.update!(:reject, &MapSet.new/1)
    |> Map.update!(:faults, &Enum.map(&1, fn fault -> fault!(fault) end))
  end

  @doc "Start a Fake linked to the caller, from a `scenario/1` or its options."
  @spec start(scenario() | keyword()) :: pid()
  def start(scenario \\ [])

  def start(opts) when is_list(opts), do: start(scenario(opts))

  def start(%{} = scenario) do
    {:ok, pid} =
      Agent.start_link(fn ->
        fake = self()

        state =
          ReferenceServer.state(:legacy,
            tools: tools(),
            observer: nil,
            result: &answer(fake, &1, &2)
          )

        Map.merge(scenario, %{
          seam: ReferenceServer.seam(Legacy, state),
          hooks: %{},
          orders: %{},
          calls: [],
          requests: []
        })
      end)

    pid
  end

  @doc "Replace the warnings every `review_*` returns."
  @spec warnings(pid(), [String.t()]) :: :ok
  def warnings(fake, list) when is_list(list), do: Agent.update(fake, &%{&1 | warnings: list})

  @doc "Append faults (same forms as the scenario's `:faults`)."
  @spec inject(pid(), [tuple()]) :: :ok
  def inject(fake, faults) when is_list(faults) do
    faults = Enum.map(faults, &fault!/1)
    Agent.update(fake, &%{&1 | faults: &1.faults ++ faults})
  end

  @doc """
  Run `fun.(arguments)` in the server before it answers `tool`. Returning
  `:hang` never answers, `{:rpc_error, code}` answers a JSON-RPC error,
  `{:result, map}` answers that raw `tools/call` result, and anything else
  answers from the scenario.
  """
  @spec on_call(pid(), String.t(), (map() -> term())) :: :ok
  def on_call(fake, tool, fun) when is_binary(tool) and is_function(fun, 1),
    do: Agent.update(fake, &%{&1 | hooks: Map.put(&1.hooks, tool, fun)})

  @doc "`{tool, arguments}` for each `tools/call` that reached the scenario, oldest first."
  @spec calls(pid()) :: [{String.t(), map()}]
  def calls(fake), do: fake |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "Names of those calls to tools starting with `prefix`."
  @spec calls(pid(), String.t()) :: [String.t()]
  def calls(fake, prefix),
    do: for({name, _args} <- calls(fake), String.starts_with?(name, prefix), do: name)

  @doc """
  Each exchange, oldest first: `{method, tool, status}`; `tool` is nil outside
  `tools/call` and `status` is nil for a `:closed` fault.
  """
  @spec requests(pid()) :: [{String.t() | nil, String.t() | nil, non_neg_integer() | nil}]
  def requests(fake), do: fake |> Agent.get(& &1.requests) |> Enum.reverse()

  @doc "How many HTTP exchanges reached the Fake, of any method."
  @spec exchanges(pid()) :: non_neg_integer()
  def exchanges(fake), do: Agent.get(fake, &length(&1.requests))

  @doc ~s(Orders placed, oldest first: `%{"order_id", "state", "args"}`.)
  @spec orders(pid()) :: [map()]
  def orders(fake) do
    fake
    |> Agent.get(& &1.orders)
    |> Map.values()
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(&order_view/1)
  end

  @doc "A sandbox `Raxol.Broker.Executor.Port.MCP.start/2` spec reaching this Fake."
  @spec session(pid()) :: keyword()
  def session(fake) do
    [name: :broker_fake, sandbox: true, url: "https://fake.broker.test/mcp", era: :legacy] ++
      mcp_opts(fake)
  end

  @doc "The `:mcp` option `Raxol.Broker.MCP.Client` needs to reach this Fake."
  @spec mcp_opts(pid()) :: keyword()
  def mcp_opts(fake) do
    [
      resolver: fn
        _host, :inet -> {:ok, [{93, 184, 216, 34}]}
        _host, :inet6 -> {:ok, []}
      end,
      exchange: fn vetted, request, opts -> exchange(fake, vetted, request, opts) end
    ]
  end

  # -- the wire ---------------------------------------------------------------

  defp exchange(fake, vetted, request, opts) do
    {method, tool} = describe(request)

    {fault, seam} =
      Agent.get_and_update(fake, fn state ->
        {fault, faults} = take_fault(state.faults, method, tool)
        {{fault, state.seam}, %{state | faults: faults}}
      end)

    response = respond_with(fault, fn -> seam.(vetted, request, opts) end)

    status =
      case response do
        {:ok, %{status: status}} -> status
        _no_response -> nil
      end

    Agent.update(fake, &%{&1 | requests: [{method, tool, status} | &1.requests]})
    response
  end

  defp describe(request) do
    case request |> Map.get(:body) |> Kernel.||("") |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, %{"method" => "tools/call" = method, "params" => %{"name" => tool}}} -> {method, tool}
      {:ok, %{"method" => method}} -> {method, nil}
      _other -> {nil, nil}
    end
  end

  # The first fault matching the request, with one use spent.
  defp take_fault([], _method, _tool), do: {nil, []}

  defp take_fault([{match, fault, times} = entry | rest], method, tool) do
    cond do
      not matches?(match, method, tool) ->
        {found, rest} = take_fault(rest, method, tool)
        {found, [entry | rest]}

      times == 1 ->
        {fault, rest}

      true ->
        {fault, [{match, fault, times - 1} | rest]}
    end
  end

  defp matches?(:any, _method, _tool), do: true
  defp matches?(match, method, tool), do: match == tool or match == method

  defp respond_with(nil, answer), do: answer.()
  defp respond_with({:http, status}, _answer), do: http_error(status, [])

  defp respond_with({:http, status, retry_after}, _answer),
    do: http_error(status, [{"retry-after", Integer.to_string(retry_after)}])

  defp respond_with(:malformed, _answer),
    do:
      {:ok,
       %{
         status: 200,
         headers: [{"content-type", "application/json"}],
         body: ~s({"jsonrpc": "2.0", )
       }}

  defp respond_with({:slow, ms}, answer) do
    Process.sleep(ms)
    answer.()
  end

  defp respond_with(:closed, _answer), do: {:error, :closed}

  defp http_error(status, headers),
    do:
      {:ok,
       %{status: status, headers: [{"content-type", "text/plain"} | headers], body: "fake fault"}}

  # -- tools/call -------------------------------------------------------------

  defp answer(fake, "tools/call", %{"name" => name} = params) do
    args = params["arguments"] || %{}
    Agent.update(fake, &%{&1 | calls: [{name, args} | &1.calls]})
    hook = Agent.get(fake, &Map.get(&1.hooks, name, fn _args -> :answer end))
    hooked(hook.(args), fake, name, args)
  end

  defp answer(_fake, _method, _params), do: :default

  defp hooked(:hang, _fake, _name, _args) do
    receive do
      :never_sent -> :default
    end
  end

  defp hooked({:rpc_error, code}, _fake, _name, _args), do: {:error, {code, "rejected"}}
  defp hooked({:result, result}, _fake, _name, _args), do: {:ok, result}

  defp hooked(_answer, fake, name, args) do
    if Enum.any?(tools(), &(&1["name"] == name)),
      do: Agent.get_and_update(fake, &tool(name, args, &1)),
      else: {:error, {-32_602, "Unknown tool: #{name}"}}
  end

  defp tool("get_accounts", _args, state),
    do:
      ok(
        %{"accounts" => [%{"account_number" => state.account, "agentic_allowed" => true}]},
        state
      )

  defp tool("get_equity_quotes", args, state) do
    symbols = List.wrap(args["symbols"])
    ok(%{"quotes" => for(s <- symbols, q = price_quote(state, s), do: q)}, state)
  end

  defp tool("get_equity_positions", _args, state),
    do: ok(%{"positions" => state.positions}, state)

  defp tool("get_alert_log", _args, state), do: ok(%{"alerts" => state.alerts}, state)

  defp tool("get_equity_orders", _args, state) do
    orders =
      Map.new(state.orders, fn {ref, order} -> {ref, advance(order, state.order_states)} end)

    state = %{state | orders: orders}

    ok(
      %{
        "orders" =>
          state
          |> Map.get(:orders)
          |> Map.values()
          |> Enum.sort_by(& &1.seq)
          |> Enum.map(&order_view/1)
      },
      state
    )
  end

  defp tool("review_" <> _, args, state),
    do: ok(%{"quote" => price_quote(state, args["symbol"]), "alerts" => state.warnings}, state)

  defp tool("place_" <> _, args, state) do
    ref = args["ref_id"] || "seq-#{map_size(state.orders) + 1}"

    cond do
      MapSet.member?(state.reject, args["symbol"]) ->
        error(%{"error" => "order rejected", "symbol" => args["symbol"]}, state)

      order = state.orders[ref] ->
        ok(order_view(order), state)

      true ->
        order = %{
          id: "ord-" <> ref,
          step: 0,
          state: hd(state.order_states),
          args: args,
          seq: map_size(state.orders)
        }

        ok(order_view(order), %{state | orders: Map.put(state.orders, ref, order)})
    end
  end

  defp tool("cancel_" <> _, args, state) do
    case Enum.find(state.orders, fn {_ref, order} -> order.id == args["order_id"] end) do
      {ref, order} ->
        order = %{order | state: "cancelled"}
        ok(order_view(order), %{state | orders: Map.put(state.orders, ref, order)})

      nil ->
        error(%{"error" => "order not found", "order_id" => args["order_id"]}, state)
    end
  end

  defp tool(_name, _args, state), do: ok(%{"ok" => true}, state)

  defp advance(%{state: "cancelled"} = order, _states), do: order

  defp advance(%{step: step} = order, states) do
    step = min(step + 1, length(states) - 1)
    %{order | step: step, state: Enum.at(states, step)}
  end

  defp order_view(order),
    do: %{"order_id" => order.id, "state" => order.state, "args" => order.args}

  defp price_quote(state, symbol) do
    case Map.fetch(state.quotes, symbol) do
      {:ok, price} ->
        %{
          "symbol" => symbol,
          "ask_price" => price,
          "bid_price" => price,
          "last_trade_price" => price
        }

      :error ->
        nil
    end
  end

  defp ok(body, state), do: {{:ok, result(body, false)}, state}
  defp error(body, state), do: {{:ok, result(body, true)}, state}

  defp result(body, is_error),
    do: %{
      "content" => [%{"type" => "text", "text" => Jason.encode!(body)}],
      "isError" => is_error
    }

  # -- scenario validation ----------------------------------------------------

  defp string!(value, _key) when is_binary(value) and value != "", do: value

  defp string!(value, key),
    do: raise(ArgumentError, "#{key} must be a string, got #{inspect(value)}")

  defp list!(opts, key) do
    case Keyword.get(opts, key, []) do
      value when is_list(value) -> value
      value -> raise ArgumentError, "#{key} must be a list, got #{inspect(value)}"
    end
  end

  defp quotes!(quotes) when is_map(quotes) or is_list(quotes),
    do: Map.new(quotes, fn {symbol, price} -> {string!(symbol, :quotes), price!(price)} end)

  defp quotes!(other), do: raise(ArgumentError, "quotes must be a map, got #{inspect(other)}")

  defp price!(%Decimal{} = price), do: Decimal.to_string(price, :normal)
  defp price!(price) when is_binary(price), do: price
  defp price!(price) when is_integer(price), do: Integer.to_string(price)

  defp price!(price),
    do:
      raise(
        ArgumentError,
        "a quote price must be a string, integer or Decimal, got #{inspect(price)}"
      )

  defp states!([_ | _] = states) do
    Enum.each(states, &string!(&1, :order_states))
    states
  end

  defp states!(other),
    do: raise(ArgumentError, "order_states must be a non-empty list, got #{inspect(other)}")

  defp fault!({match, fault}), do: fault!({match, fault, 1})

  defp fault!({match, fault, times} = entry)
       when (match == :any or is_binary(match)) and is_integer(times) and times > 0 do
    if valid_fault?(fault),
      do: entry,
      else: raise(ArgumentError, "unknown Fake fault: #{inspect(fault)}")
  end

  defp fault!(other),
    do:
      raise(
        ArgumentError,
        "a fault is {match, fault} or {match, fault, times}, got #{inspect(other)}"
      )

  defp valid_fault?({:http, status}) when status in 400..599, do: true

  defp valid_fault?({:http, status, after_s})
       when status in 400..599 and is_integer(after_s) and after_s >= 0, do: true

  defp valid_fault?({:slow, ms}) when is_integer(ms) and ms >= 0, do: true
  defp valid_fault?(fault), do: fault in [:malformed, :closed]
end
