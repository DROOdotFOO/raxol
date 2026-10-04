defmodule Raxol.Broker.Test.OrderServer do
  @moduledoc """
  An in-process MCP server that answers Robinhood's order tools, for the
  executor tests: the legacy-era reference server (`initialize`,
  `Mcp-Session-Id`, real JSON-RPC over the HTTP transport's `:exchange`
  seam) serving the recorded `tools_list.json`, with `tools/call` answered
  from a script.

    * `review_*` answers `{"quote": ..., "alerts": warnings}`; set the
      warnings with `warnings/2`.
    * Any other tool answers `{"order_id": ..., "state": "queued"}`.
    * `on_call/3` runs a function in the server before it answers a tool;
      returning `:hang` never answers (a timed-out call), `{:rpc_error, code}`
      answers a JSON-RPC error, `{:result, map}` answers that raw `tools/call`
      result (for example `%{"content" => [], "isError" => false}`), anything
      else answers normally.

  Every `tools/call` is logged with its arguments for assertions, and every
  HTTP exchange (including `initialize`) is counted by `exchanges/1`.
  """

  alias Raxol.Broker.Test.Fixtures
  alias Raxol.MCP.Client.ReferenceServer
  alias Raxol.MCP.Client.ReferenceServer.Legacy

  @spec start() :: pid()
  def start do
    {:ok, pid} = Agent.start_link(fn -> %{warnings: [], hooks: %{}, calls: [], exchanges: 0} end)
    pid
  end

  @spec warnings(pid(), [String.t()]) :: :ok
  def warnings(server, list), do: Agent.update(server, &%{&1 | warnings: list})

  @spec on_call(pid(), String.t(), (map() -> term())) :: :ok
  def on_call(server, tool, fun),
    do: Agent.update(server, &%{&1 | hooks: Map.put(&1.hooks, tool, fun)})

  @doc "`{tool, arguments}` for each `tools/call`, oldest first."
  @spec calls(pid()) :: [{String.t(), map()}]
  def calls(server), do: server |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "Names of the calls to tools starting with `prefix`."
  @spec calls(pid(), String.t()) :: [String.t()]
  def calls(server, prefix),
    do: for({name, _args} <- calls(server), String.starts_with?(name, prefix), do: name)

  @doc "How many HTTP exchanges reached the server, of any method."
  @spec exchanges(pid()) :: non_neg_integer()
  def exchanges(server), do: Agent.get(server, & &1.exchanges)

  @doc "A `Raxol.Broker.Executor.Port.MCP.start/2` spec reaching this server (a sandbox)."
  @spec session(pid()) :: keyword()
  def session(server) do
    tools = Fixtures.load("tools_list")["tools"]

    state =
      ReferenceServer.state(:legacy, tools: tools, observer: nil, result: &answer(server, &1, &2))

    seam = ReferenceServer.seam(Legacy, state)

    [
      name: :broker_executor_test,
      sandbox: true,
      url: "https://orders.test/mcp",
      era: :legacy,
      resolver: fn
        _host, :inet -> {:ok, [{93, 184, 216, 34}]}
        _host, :inet6 -> {:ok, []}
      end,
      exchange: fn vetted, request, opts ->
        Agent.update(server, &%{&1 | exchanges: &1.exchanges + 1})
        seam.(vetted, request, opts)
      end
    ]
  end

  defp answer(server, "tools/call", %{"name" => name} = params) do
    args = params["arguments"] || %{}
    Agent.update(server, &%{&1 | calls: [{name, args} | &1.calls]})
    %{hooks: hooks, warnings: warnings} = Agent.get(server, & &1)
    respond(Map.get(hooks, name, fn _args -> :answer end).(args), name, args, warnings)
  end

  defp answer(_server, _method, _params), do: :default

  defp respond(:hang, _name, _args, _warnings) do
    receive do
      :never_sent -> :default
    end
  end

  defp respond({:rpc_error, code}, _name, _args, _warnings), do: {:error, {code, "rejected"}}

  defp respond({:result, result}, _name, _args, _warnings), do: {:ok, result}

  defp respond(_answer, name, args, warnings),
    do: {:ok, %{"content" => [text(body(name, args, warnings))], "isError" => false}}

  defp body("review_" <> _, args, warnings),
    do: %{"quote" => %{"symbol" => args["symbol"], "ask" => "125.00"}, "alerts" => warnings}

  defp body(_tool, args, _warnings),
    do: %{
      "order_id" => "ord-" <> (args["ref_id"] || args["order_id"] || "x"),
      "state" => "queued"
    }

  defp text(body), do: %{"type" => "text", "text" => Jason.encode!(body)}
end
