defmodule Raxol.Broker.MCP.FakeTest do
  @moduledoc """
  The Fake through a real `Raxol.Broker.Executor.Port.MCP` session: the HTTP
  transport, the legacy handshake and JSON-RPC all run for real.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.MCP.Fake

  @moduletag :capture_log

  defp port!(fake, opts \\ []) do
    {:ok, port} = PortMCP.start(Fake.session(fake), [mode: :dry_run] ++ opts)
    on_exit(fn -> Port.stop(port) end)
    port
  end

  defp body!({:ok, %{content: [%{"type" => "text", "text" => text}]} = result}),
    do: {result.is_error, Jason.decode!(text)}

  defp place(port, symbol, ref_id) do
    Port.call(
      port,
      "place_equity_order",
      %{"account_number" => "FAKE-0001", "symbol" => symbol, "side" => "buy", "ref_id" => ref_id},
      5_000
    )
  end

  test "quotes, positions and alerts come from the scenario" do
    fake =
      Fake.start(
        quotes: %{"AAPL" => Decimal.new("125.50")},
        positions: [%{"symbol" => "AAPL", "quantity" => "3"}],
        alerts: [%{"symbol" => "AAPL", "fired_at" => "2026-10-02T14:30:00Z"}]
      )

    port = port!(fake)

    assert {false, %{"quotes" => [%{"symbol" => "AAPL", "ask_price" => "125.50"}]}} =
             body!(Port.call(port, "get_equity_quotes", %{"symbols" => ["AAPL", "MSFT"]}, 5_000))

    assert {false, %{"positions" => [%{"symbol" => "AAPL"}]}} =
             body!(Port.call(port, "get_equity_positions", %{}, 5_000))

    assert {false, %{"alerts" => [_]}} = body!(Port.call(port, "get_alert_log", %{}, 5_000))
  end

  test "a re-sent ref_id answers the same order and creates no second one" do
    fake = Fake.start()
    port = port!(fake)

    {false, first} = body!(place(port, "AAPL", "r-1"))
    {false, again} = body!(place(port, "AAPL", "r-1"))

    assert first["order_id"] == again["order_id"]
    assert [%{"order_id" => id}] = Fake.orders(fake)
    assert id == first["order_id"]
    assert Fake.calls(fake, "place_") == ["place_equity_order", "place_equity_order"]
  end

  test "a rejected symbol answers isError and records no order" do
    fake = Fake.start(reject: ["GME"])
    port = port!(fake)

    assert {true, %{"error" => "order rejected"}} = body!(place(port, "GME", "r-2"))
    assert Fake.orders(fake) == []
  end

  test "orders move one state per get_equity_orders, stop at the last, and cancel" do
    fake = Fake.start(order_states: ["queued", "confirmed", "filled"])
    port = port!(fake)
    {false, %{"order_id" => filled, "state" => "queued"}} = body!(place(port, "AAPL", "r-3"))
    {false, %{"order_id" => open}} = body!(place(port, "MSFT", "r-4"))

    {false, %{"order_id" => ^open, "state" => "cancelled"}} =
      body!(Port.call(port, "cancel_equity_order", %{"order_id" => open}, 5_000))

    states = fn ->
      {false, %{"orders" => orders}} = body!(Port.call(port, "get_equity_orders", %{}, 5_000))
      for order <- orders, do: {order["order_id"], order["state"]}
    end

    assert states.() == [{filled, "confirmed"}, {open, "cancelled"}]
    assert states.() == [{filled, "filled"}, {open, "cancelled"}]
    assert states.() == [{filled, "filled"}, {open, "cancelled"}]
  end

  test "an HTTP fault is consumed in order and never reaches the scenario" do
    fake = Fake.start(faults: [{"place_equity_order", {:http, 429}}])
    port = port!(fake)

    assert {:error, _reason} = place(port, "AAPL", "r-5")
    assert Fake.orders(fake) == []
    assert Fake.calls(fake) == []

    assert {false, %{"state" => "queued"}} = body!(place(port, "AAPL", "r-5"))

    assert [{"tools/call", "place_equity_order", 429}, {"tools/call", "place_equity_order", 200}] =
             for({"tools/call", _tool, _status} = request <- Fake.requests(fake), do: request)
  end

  test "a malformed body leaves the call unanswered until its timeout" do
    fake = Fake.start(faults: [{"get_accounts", :malformed}])
    port = port!(fake, call_timeout: 200)

    assert {:error, _reason} = Port.call(port, "get_accounts", %{}, 5_000)
    assert Fake.calls(fake) == []
    assert {false, %{"accounts" => [_]}} = body!(Port.call(port, "get_accounts", %{}, 5_000))
  end

  test "an exchange is recorded when it arrives, so one that never answers is seen" do
    fake = Fake.start()
    Fake.on_call(fake, "get_accounts", fn _args -> :hang end)
    port = port!(fake, call_timeout: 200)

    assert {:error, _reason} = Port.call(port, "get_accounts", %{}, 5_000)
    assert {"tools/call", "get_accounts", :pending} in Fake.requests(fake)
  end

  test "the client_opts store cannot hold a credential" do
    opts = Fake.client_opts(Fake.start())

    assert {:error, _reason} = Raxol.Broker.CredentialStore.put(opts[:credential], opts[:store])
    assert {:error, _reason} = Raxol.Broker.CredentialStore.fetch(opts[:store])
  end

  test "a closed connection reports the real transport's error shape" do
    fake = Fake.start(faults: [{"get_accounts", :closed}])
    port = port!(fake)

    assert Port.call(port, "get_accounts", %{}, 5_000) == {:error, {:transport, :closed}}
    assert {"tools/call", "get_accounts", nil} in Fake.requests(fake)
    assert Fake.calls(fake) == []
  end

  test "client_opts sessions never refresh: a 401 locks out" do
    fake = Fake.start(faults: [{"get_accounts", {:http, 401}}])
    client = start_supervised!({Raxol.Broker.MCP.Client, Fake.client_opts(fake)})

    assert Raxol.Broker.MCP.Client.call(client, "get_accounts", %{}) == {:error, :unauthorized}
    assert Raxol.Broker.MCP.Client.call(client, "get_accounts", %{}) == {:error, :unauthorized}

    assert [{"tools/call", "get_accounts", 401}] =
             for({"tools/call", _, _} = r <- Fake.requests(fake), do: r)
  end

  test "only an accepted bearer is answered; any other gets the recorded 401" do
    refused = Fake.start(accept: ["another-access-token"])
    client = start_supervised!({Client, Fake.client_opts(refused)}, id: :refused)

    assert Client.call(client, "get_accounts", %{}) == {:error, :unauthorized}
    assert Fake.requests(refused) == [{"initialize", nil, 401}]
    assert Fake.calls(refused) == []

    token = Fake.client_opts(refused)[:credential].access_token
    accepted = Fake.start(accept: [token])
    client = start_supervised!({Client, Fake.client_opts(accepted)}, id: :accepted)

    assert {:ok, %{is_error: false}} = Client.call(client, "get_accounts", %{})
    assert Fake.calls(accepted) == [{"get_accounts", %{}}]
  end

  test "accept/2 changes the accepted tokens mid-session" do
    fake = Fake.start()
    opts = Fake.client_opts(fake)
    client = start_supervised!({Client, opts}, id: :first)
    assert {:ok, %{is_error: false}} = Client.call(client, "get_accounts", %{})

    Fake.accept(fake, ["rotated-elsewhere"])
    assert Client.call(client, "get_accounts", %{}) == {:error, :unauthorized}

    Fake.accept(fake, [opts[:credential].access_token])
    again = start_supervised!({Client, opts}, id: :again)
    assert {:ok, %{is_error: false}} = Client.call(again, "get_accounts", %{})

    assert for({"tools/call", tool, status} <- Fake.requests(fake), do: {tool, status}) == [
             {"get_accounts", 200},
             {"get_accounts", 401},
             {"get_accounts", 200}
           ]

    assert Fake.calls(fake, "get_") == ["get_accounts", "get_accounts"]
  end

  test "forbid_calls answers every tools/call 403 and nothing reaches the scenario" do
    fake = Fake.start()
    Fake.forbid_calls(fake)
    client = start_supervised!({Client, Fake.client_opts(fake)})

    assert {:ok, [_ | _]} = Client.list_tools(client)
    assert Client.call(client, "get_accounts", %{}) == {:error, {:http, 403}}
    assert Fake.calls(fake) == []

    assert [{"tools/call", "get_accounts", 403}] =
             for({"tools/call", _, _} = r <- Fake.requests(fake), do: r)
  end

  test "server/discover gets Robinhood's plain-text 400, so an unpinned spec never handshakes" do
    fake = Fake.start()
    {:ok, spec} = PortMCP.prepare(Keyword.delete(Fake.session(fake), :era), mode: :dry_run)
    {:ok, port} = PortMCP.start_client(spec)
    on_exit(fn -> Port.stop(port) end)

    # The probe runs in the client's connect, before it takes any call.
    assert PortMCP.await_ready(port, 0) == {:error, {:not_ready, :closed}}
    assert [{"server/discover", nil, 400} | _] = Fake.requests(fake)
    refute Enum.any?(Fake.requests(fake), &match?({"initialize", _, _}, &1))
  end

  test "a scenario with an unknown key or a bad fault is refused" do
    assert_raise ArgumentError, ~r/unknown Fake scenario keys/, fn ->
      Fake.scenario(quote: %{})
    end

    assert_raise ArgumentError, ~r/unknown Fake fault/, fn ->
      Fake.scenario(faults: [{:any, {:http, 200}}])
    end

    # The count is the entry's third element, never the fault's.
    assert_raise ArgumentError, ~r/unknown Fake fault/, fn ->
      Fake.scenario(faults: [{"get_accounts", {:http, 429, 2}}])
    end

    assert_raise ArgumentError, ~r/accept must be/, fn -> Fake.scenario(accept: "token") end
    assert_raise ArgumentError, ~r/accept must be/, fn -> Fake.scenario(accept: [""]) end
  end
end
