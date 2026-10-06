defmodule Raxol.Broker.Executor.PortMCPTest do
  @moduledoc """
  `Raxol.Broker.Executor.Port.MCP` and `Raxol.Broker.Executor.Port` against
  `Raxol.Broker.MCP.Fake`, a real in-process MCP server.
  """
  use ExUnit.Case, async: true

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.MCP.Fake

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

    test "a repeated url, sandbox or command is live, whichever value comes last" do
      fake = "https://orders.test/mcp"
      robinhood = "https://api.robinhood.com/mcp"

      for spec <- [
            [sandbox: true, url: fake, url: robinhood],
            [sandbox: true, url: robinhood, url: fake],
            [sandbox: true, url: fake, url: fake],
            [sandbox: true, sandbox: false, url: fake],
            [sandbox: false, sandbox: true, url: fake],
            [sandbox: true, url: fake, command: "a", command: "b"]
          ] do
        assert PortMCP.live_spec?(spec), inspect(spec)
      end
    end

    test "a command beside a sandbox url is live" do
      assert PortMCP.live_spec?(sandbox: true, url: "https://orders.test/mcp", command: "x")
    end

    test "a list that is not a keyword list is live" do
      assert PortMCP.live_spec?([{"url", "https://orders.test/mcp"}, {:sandbox, true}])
    end
  end

  describe "start/2" do
    test "dry run refuses a live spec before connecting" do
      server = Fake.start()
      spec = Keyword.delete(Fake.session(server), :sandbox)

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert Fake.exchanges(server) == 0
    end

    test "a live Robinhood url is refused in dry run even with sandbox" do
      server = Fake.start()
      spec = Keyword.put(Fake.session(server), :url, "https://Agent.Robinhood.com./mcp")

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert Fake.exchanges(server) == 0
    end

    test "armed is refused until arming exists" do
      server = Fake.start()
      assert PortMCP.start(Fake.session(server), mode: :armed) == {:error, :not_armed}
      assert Fake.exchanges(server) == 0
    end

    test "a missing or unknown mode is refused" do
      server = Fake.start()
      assert PortMCP.start(Fake.session(server), []) == {:error, {:invalid_mode, nil}}
      assert Fake.exchanges(server) == 0
    end

    test "a duplicate url is refused with Robinhood last, sending nothing" do
      server = Fake.start()

      spec =
        List.insert_at(Fake.session(server), -1, {:url, "https://api.robinhood.com/mcp"})

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert Fake.exchanges(server) == 0
    end

    test "a duplicate url is refused with Robinhood first, sending nothing" do
      server = Fake.start()
      spec = [url: "https://api.robinhood.com/mcp"] ++ Fake.session(server)

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert Fake.exchanges(server) == 0
    end

    test "a duplicate sandbox (true, then false) is refused, sending nothing" do
      server = Fake.start()
      spec = List.insert_at(Fake.session(server), -1, {:sandbox, false})

      assert PortMCP.start(spec, mode: :dry_run) == {:error, :live_port_in_dry_run}
      assert Fake.exchanges(server) == 0
    end

    test "the list that connects is the normalized list that was checked" do
      server = Fake.start()
      spec = Fake.session(server)

      assert {:ok, client_spec} = PortMCP.prepare(spec, mode: :dry_run, call_timeout: 7_000)
      keys = Keyword.keys(client_spec)
      assert keys == Enum.uniq(keys)
      refute Keyword.has_key?(client_spec, :sandbox)

      expected =
        spec
        |> Map.new()
        |> Map.delete(:sandbox)
        |> Map.put(:call_timeout, 7_000)

      assert Map.new(client_spec) == expected
      assert client_spec[:url] == spec[:url]
    end

    test "a repeated unchecked key connects with its last value, as the client reads it" do
      first = Fake.start()
      last = Fake.start()
      exchange = Fake.session(last)[:exchange]
      spec = List.insert_at(Fake.session(first), -1, {:exchange, exchange})

      assert {:ok, client_spec} = PortMCP.prepare(spec, mode: :dry_run)
      assert client_spec[:exchange] == exchange
      assert Keyword.get_values(client_spec, :exchange) == [exchange]

      assert {:ok, port} = PortMCP.start(spec, mode: :dry_run)
      assert Fake.exchanges(first) == 0
      assert Fake.exchanges(last) > 0
      assert Port.stop(port) == :ok
    end

    test "a sandbox spec connects in dry run" do
      server = Fake.start()
      assert {:ok, port} = PortMCP.start(Fake.session(server), mode: :dry_run)
      assert Fake.exchanges(server) > 0

      assert {:ok, %{is_error: false}} =
               Port.call(port, "review_equity_order", %{"symbol" => "AAPL"}, 5_000)

      assert Fake.calls(server, "review_") == ["review_equity_order"]
      assert Port.stop(port) == :ok
    end
  end

  describe "start_client/1 and await_ready/2" do
    test "start_client returns before connecting; await_ready waits for the session" do
      server = Fake.start()
      {:ok, dns} = Agent.start_link(fn -> {:error, :nxdomain} end)
      good = Fake.session(server)[:resolver]

      session =
        Keyword.put(Fake.session(server), :resolver, fn host, family ->
          if Agent.get(dns, & &1) == :ok, do: good.(host, family), else: {:error, :nxdomain}
        end)

      {:ok, spec} = PortMCP.prepare(session, mode: :dry_run, reconnect_ms: 10)
      assert spec[:reconnect_ms] == 10

      {:ok, port} = PortMCP.start_client(spec)
      assert {:error, {:not_ready, _}} = PortMCP.await_ready(port, 0)
      assert Fake.exchanges(server) == 0

      Agent.update(dns, fn _ -> :ok end)
      assert PortMCP.await_ready(port, 5_000) == :ok
      assert {:ok, %{is_error: false}} = Port.call(port, "review_equity_order", %{}, 5_000)
    end
  end

  describe "Port.call/4" do
    test "the caller timing out is {:error, :timeout}" do
      server = Fake.start()
      Fake.on_call(server, "review_equity_order", fn _args -> :hang end)

      {:ok, port} =
        PortMCP.start(Fake.session(server), mode: :dry_run, call_timeout: 60_000)

      assert Port.call(port, "review_equity_order", %{}, 1) == {:error, :timeout}
    end

    test "a stopped port is {:error, {:port_down, _}}" do
      server = Fake.start()
      {:ok, port} = PortMCP.start(Fake.session(server), mode: :dry_run)
      :ok = Port.stop(port)

      assert {:error, {:port_down, _reason}} = Port.call(port, "review_equity_order", %{}, 5_000)
    end
  end
end
