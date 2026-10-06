defmodule Raxol.Broker.MCP.Fake do
  @moduledoc """
  Robinhood's agent MCP server, in process and scripted: the backend for the
  broker's tests, dry runs and backtests, so nothing here needs a funded US
  account or the network.

  It is the legacy-era reference server (`Raxol.MCP.Client.ReferenceServer`:
  `initialize`, `Mcp-Session-Id`, real JSON-RPC) reached through the HTTP
  transport's `:exchange` seam, so the client's whole pre-socket pipeline runs
  for real. `session/1` is a `Raxol.Broker.Executor.Port.MCP` spec (marked
  sandbox); `client_opts/2` is a complete, isolated option list for
  `Raxol.Broker.MCP.Client` (a synthetic credential that can never refresh,
  so the user's stored credential and Robinhood's token endpoint are never
  touched); `mcp_opts/1` is only its `:mcp` part.

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
    * `:accept` - the access tokens the Fake accepts (see Authorization and
      refusals; default unset: every token).
    * `:faults` - see below.

  `place_*` is idempotent on `ref_id`, as Robinhood documents it: the same
  `ref_id` answers the same order and creates no second one.

  ## Faults

  Each fault is `{match, fault}` or `{match, fault, times}` (default once).
  `match` is a tool name, a JSON-RPC method (`"initialize"`), or `:any`. The
  first entry matching a request is consumed; a faulted request never reaches
  the scenario, so it places nothing and is not in `calls/1`.

    * `{:http, status}` - an HTTP error (429, 5xx). The client sees only the
      status: the transport drops a non-2xx response's headers.
    * `:malformed` - a 200 whose body is not JSON. The client finds no reply
      in it, so the call gets no answer and ends at its call timeout.
    * `{:slow, ms}` - answers normally after `ms`.
    * `:closed` - a transport failure with no response,
      `{:error, {:transport, :closed}}` as the real exchange reports it.

  A fault pre-empts everything below: it is consumed before the request is
  authorized or routed.

  ## Authorization and refusals

  With `:accept` set (or after `accept/2`), a request whose
  `Authorization: Bearer` token is not one of those gets the 401 Robinhood
  answers an invalid token, `www-authenticate` and body as recorded with the
  auth exchange on 2026-10-02/03 (`priv/robinhood/invalid_token_401.json`).
  Unset, every token is accepted, which is what `client_opts/2` relies on.
  After `forbid_calls/1` every authorized `tools/call` answers 403.

  `server/discover` always gets the plain-text 400 Robinhood serves for it
  (observed 2026-10-03, `priv/robinhood/discover_400.json`), not a JSON-RPC
  method-not-found, so a spec that is not pinned to the legacy era fails
  against the Fake as it would against Robinhood. `session/1` and
  `client_opts/2` are pinned.

  Every exchange is in `requests/1` from the moment it arrives (status
  `:pending` until it answers); every `tools/call` that reached the scenario
  is in `calls/1` with its arguments. Neither records a header, so the bearer
  token is never kept.
  """

  alias Raxol.Agent.Auth.Credential
  alias Raxol.MCP.Client.ReferenceServer
  alias Raxol.MCP.Client.ReferenceServer.Legacy

  # A reserved `.test` host: nothing real answers it, so a spec that lost its
  # `:exchange` cannot reach a brokerage either.
  @url "https://fake.broker.test/mcp"

  @recordings Path.expand("../../../../priv/robinhood", __DIR__)

  @tools_path Path.join(@recordings, "tools_list.json")
  @external_resource @tools_path
  @recorded_tools @tools_path |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")

  @invalid_token_path Path.join(@recordings, "invalid_token_401.json")
  @external_resource @invalid_token_path
  @invalid_token @invalid_token_path |> File.read!() |> Jason.decode!()

  @discover_path Path.join(@recordings, "discover_400.json")
  @external_resource @discover_path
  @discover_refused @discover_path |> File.read!() |> Jason.decode!()

  @scenario_tools for name <- ~w(get_equity_positions get_equity_orders get_alert_log),
                      do: %{
                        "name" => name,
                        "description" => "Fake: answered from the scenario.",
                        "inputSchema" => %{"type" => "object"},
                        "annotations" => %{"readOnlyHint" => true}
                      }

  @keys [
    :account,
    :quotes,
    :positions,
    :alerts,
    :warnings,
    :reject,
    :order_states,
    :accept,
    :faults
  ]

  @type fault :: {:http, 400..599} | :malformed | {:slow, non_neg_integer()} | :closed
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
    known_keys!(opts)

    lists = Map.new([:positions, :alerts, :warnings, :reject, :faults], &{&1, list!(opts, &1)})

    %{
      account: string!(Keyword.get(opts, :account, "FAKE-0001"), :account),
      quotes: quotes!(Keyword.get(opts, :quotes, %{})),
      order_states: states!(Keyword.get(opts, :order_states, ["queued"])),
      accept: accept!(Keyword.get(opts, :accept))
    }
    |> Map.merge(lists)
    |> Map.update!(:reject, &MapSet.new/1)
    |> Map.update!(:faults, &faults!/1)
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
          requests: [],
          forbid_calls: false
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
  Accept exactly these access tokens from now on; any other bearer gets the
  recorded 401. `nil` accepts every token again.
  """
  @spec accept(pid(), [String.t()] | nil) :: :ok
  def accept(fake, tokens) do
    accepted = accept!(tokens)
    Agent.update(fake, &%{&1 | accept: accepted})
  end

  @doc "Answer every authorized `tools/call` 403 (authenticated but forbidden) from now on."
  @spec forbid_calls(pid()) :: :ok
  def forbid_calls(fake), do: Agent.update(fake, &%{&1 | forbid_calls: true})

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
  Each exchange, oldest first: `{method, tool, status}`. `tool` is nil outside
  `tools/call`; `status` is `:pending` while the exchange has not answered and
  nil for a `:closed` fault.
  """
  @spec requests(pid()) :: [
          {String.t() | nil, String.t() | nil, non_neg_integer() | :pending | nil}
        ]
  def requests(fake) do
    fake
    |> Agent.get(& &1.requests)
    |> Enum.reverse()
    |> Enum.map(fn {_ref, method, tool, status} -> {method, tool, status} end)
  end

  @doc "How many HTTP exchanges reached the Fake, of any method, answered or not."
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
    [name: :broker_fake, sandbox: true, url: @url, era: :legacy] ++ mcp_opts(fake)
  end

  @doc """
  The `:mcp` option `Raxol.Broker.MCP.Client` needs to reach this Fake. Not
  isolated on its own: a client given only this still reads the stored
  credential and refreshes against Robinhood. Use `client_opts/2`.
  """
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

  @doc """
  Complete `Raxol.Broker.MCP.Client.start_link/1` options for a session to
  this Fake that touches nothing real. The credential is synthetic, with no
  refresh token and no expiry: no refresh is ever scheduled, and a 401 locks
  the session out (`{:error, :unauthorized}`) instead of refreshing. The token
  endpoint refuses, and the stored credential is never read. `overrides` are
  merged last.
  """
  @spec client_opts(pid(), keyword()) :: keyword()
  def client_opts(fake, overrides \\ []) do
    Keyword.merge(
      [
        credential: %Credential{
          provider: :robinhood,
          issuer: @url,
          client_id: "fake-client",
          access_token: "fake-access-token",
          refresh_token: nil,
          expires_at: nil
        },
        auth: [http_fn: fn _url, _body, _opts -> {:error, :fake_has_no_token_endpoint} end],
        url: @url,
        mcp: mcp_opts(fake)
      ],
      overrides
    )
  end

  # -- the wire ---------------------------------------------------------------

  # Recorded on arrival, so an exchange that never answers (a `:hang` hook, a
  # `{:slow, ms}` fault, a task the transport killed) is still counted.
  defp exchange(fake, vetted, request, opts) do
    {method, tool} = describe(request)
    ref = make_ref()

    {fault, server} = arrive(fake, ref, method, tool)

    response = respond_with(fault, fn -> serve(server, method, vetted, request, opts) end)

    status =
      case response do
        {:ok, %{status: status}} -> status
        _no_response -> nil
      end

    Agent.update(fake, fn state ->
      requests =
        Enum.map(state.requests, fn
          {^ref, method, tool, :pending} -> {ref, method, tool, status}
          other -> other
        end)

      %{state | requests: requests}
    end)

    response
  end

  # Spends the fault the request matches, records it as `:pending`, and
  # snapshots what answers it.
  defp arrive(fake, ref, method, tool) do
    Agent.get_and_update(fake, fn state ->
      {fault, faults} = take_fault(state.faults, method, tool)
      arrived = [{ref, method, tool, :pending} | state.requests]
      server = Map.take(state, [:seam, :accept, :forbid_calls])
      {{fault, server}, %{state | faults: faults, requests: arrived}}
    end)
  end

  defp describe(request) do
    case request |> Map.get(:body) |> Kernel.||("") |> IO.iodata_to_binary() |> Jason.decode() do
      {:ok, %{"method" => "tools/call" = method, "params" => %{"name" => tool}}} -> {method, tool}
      {:ok, %{"method" => method}} -> {method, nil}
      _other -> {nil, nil}
    end
  end

  defp serve(server, method, vetted, request, opts) do
    with :ok <- authorize(server.accept, request),
         :ok <- route(method, server.forbid_calls) do
      server.seam.(vetted, request, opts)
    end
  end

  defp authorize(nil, _request), do: :ok

  defp authorize(accepted, request) do
    if MapSet.member?(accepted, bearer(request)), do: :ok, else: recorded(@invalid_token)
  end

  defp bearer(request) do
    Enum.find_value(Map.get(request, :headers, []), fn
      {name, "Bearer " <> token} -> if String.downcase(name) == "authorization", do: token
      _other -> nil
    end)
  end

  defp route("server/discover", _forbid_calls), do: recorded(@discover_refused)

  defp route("tools/call", true),
    do: {:ok, %{status: 403, headers: [{"content-type", "text/plain"}], body: "forbidden"}}

  defp route(_method, _forbid_calls), do: :ok

  defp recorded(%{"status" => status, "headers" => headers, "body" => body}),
    do: {:ok, %{status: status, headers: Map.to_list(headers), body: body}}

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

  defp respond_with({:http, status}, _answer),
    do: {:ok, %{status: status, headers: [{"content-type", "text/plain"}], body: "fake fault"}}

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

  defp respond_with(:closed, _answer), do: {:error, {:transport, :closed}}

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

  # Every served tool has a clause above. One added to the capture without an
  # answer here fails the call loudly rather than answering a made-up shape.
  defp tool(name, _args, state),
    do: {{:error, {-32_603, "the Fake has no answer for #{name}"}}, state}

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

  defp known_keys!(opts) do
    case Keyword.keys(opts) -- @keys do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown Fake scenario keys: #{inspect(unknown)}"
    end
  end

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

  defp accept!(nil), do: nil

  defp accept!(tokens) when is_list(tokens) do
    Enum.each(tokens, &string!(&1, :accept))
    MapSet.new(tokens)
  end

  defp accept!(other),
    do: raise(ArgumentError, "accept must be a list of tokens or nil, got #{inspect(other)}")

  defp faults!(faults), do: Enum.map(faults, &fault!/1)

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

  defp valid_fault?({:slow, ms}) when is_integer(ms) and ms >= 0, do: true
  defp valid_fault?(fault), do: fault in [:malformed, :closed]
end
