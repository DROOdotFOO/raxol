defmodule Raxol.Broker.MCP.FakeTest do
  @moduledoc """
  The Fake through a real `Raxol.Broker.Executor.Port.MCP` session: the HTTP
  transport, the legacy handshake and JSON-RPC all run for real.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
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
    assert Fake.exchanges(fake) == length(Fake.requests(fake))
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
  end
end
