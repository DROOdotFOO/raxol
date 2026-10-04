defmodule Raxol.Broker.Executor.PortMCPTest do
  @moduledoc """
  `Raxol.Broker.Executor.Port.MCP` and `Raxol.Broker.Executor.Port` against
  `Raxol.Broker.Test.OrderServer`, a real in-process MCP server.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.Test.OrderServer

  @moduletag :capture_log

  describe "live_spec?/1" do
    test "a sandbox spec on a non-Robinhood host is not live" do
      refute PortMCP.live_spec?(sandbox: true, url: "https://orders.test/mcp")
    end

    test "a spec without sandbox: true is live" do
      assert PortMCP.live_spec?(url: "https://orders.test/mcp")
      assert PortMCP.live_spec?(sandbox: false, url: "https://orders.test/mcp")
      assert PortMCP.live_spec?(sandbox: "true", url: "https://orders.test/mcp")
    end

    test "a stdio spec (no url) is live even when it says sandbox" do
      assert PortMCP.live_spec?(sandbox: true, command: "robinhood-mcp")
    end

    test "sandbox on a Robinhood host is live, whatever the case, dot or subdomain" do
      for url <- [
            "https://robinhood.com/mcp",
            "https://agent.robinhood.com/mcp",
            "https://AGENT.RobinHood.COM/mcp",
            "https://agent.robinhood.com./mcp",
            "https://ROBINHOOD.COM./mcp",
            "https://a.b.robinhood.com/mcp"
          ] do
        assert PortMCP.live_spec?(sandbox: true, url: url), url
      end
    end

    test "a host that only ends in the same letters is not Robinhood" do
      refute PortMCP.live_spec?(sandbox: true, url: "https://evilrobinhood.com/mcp")
    end

    test "a url with no host is live" do
      assert PortMCP.live_spec?(sandbox: true, url: "not a url")
    end
  end

  describe "start/2" do
    test "dry run refuses a live spec before connecting" do
      server = OrderServer.start()
      spec = Keyword.delete(OrderServer.session(server), :sandbox)

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert OrderServer.exchanges(server) == 0
    end

    test "a live Robinhood url is refused in dry run even with sandbox" do
      server = OrderServer.start()
      spec = Keyword.put(OrderServer.session(server), :url, "https://Agent.Robinhood.com./mcp")

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert OrderServer.exchanges(server) == 0
    end

    test "armed is refused until arming exists" do
      server = OrderServer.start()
      assert PortMCP.start(OrderServer.session(server), mode: :armed) == {:error, :not_armed}
      assert OrderServer.exchanges(server) == 0
    end

    test "a missing or unknown mode is refused" do
      server = OrderServer.start()
      assert PortMCP.start(OrderServer.session(server), []) == {:error, {:invalid_mode, nil}}
      assert OrderServer.exchanges(server) == 0
    end

    test "a sandbox spec connects in dry run" do
      server = OrderServer.start()
      assert {:ok, port} = PortMCP.start(OrderServer.session(server), mode: :dry_run)
      assert OrderServer.exchanges(server) > 0

      assert {:ok, %{is_error: false}} =
               Port.call(port, "review_equity_order", %{"symbol" => "AAPL"}, 5_000)

      assert OrderServer.calls(server, "review_") == ["review_equity_order"]
      assert Port.stop(port) == :ok
    end
  end

  describe "Port.call/4" do
    test "the caller timing out is {:error, :timeout}" do
      server = OrderServer.start()
      OrderServer.on_call(server, "review_equity_order", fn _args -> :hang end)

      {:ok, port} =
        PortMCP.start(OrderServer.session(server), mode: :dry_run, call_timeout: 60_000)

      assert Port.call(port, "review_equity_order", %{}, 1) == {:error, :timeout}
    end

    test "a stopped port is {:error, {:port_down, _}}" do
      server = OrderServer.start()
      {:ok, port} = PortMCP.start(OrderServer.session(server), mode: :dry_run)
      :ok = Port.stop(port)

      assert {:error, {:port_down, _reason}} = Port.call(port, "review_equity_order", %{}, 5_000)
    end
  end
end
