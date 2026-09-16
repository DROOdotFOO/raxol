defmodule Raxol.MCP.Client.EraTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Client.Era

  # ADR-0037 decision 2's demotion rule and cache, tested where they live. The
  # end-to-end half (the probe against two reference servers, the wedge, the
  # TTL) is in `Raxol.MCP.Client.Transport.HttpTest`.

  defp table, do: :ets.new(:eras, [:set, :public])

  describe "what counts as era evidence" do
    test "an absent probe method or endpoint demotes an origin" do
      for status <- [404, 405, 501] do
        assert Era.evidence({:status, status}) == :demote,
               "#{status} should be era evidence"
      end
    end

    test "a generic refusal or outage is health information, never a demotion" do
      # The wedge: treating a generic 400 or a 403 challenge as era evidence
      # would cache `legacy`, after which every call sends an `initialize` that
      # a modern server is specified not to answer.
      for status <- [400, 401, 403, 408, 429, 500, 502, 503] do
        assert Era.evidence({:status, status}) == :health,
               "#{status} must not decide an era"
      end
    end

    test "a success says nothing about the era on its own" do
      assert Era.evidence({:status, 200}) == :none
      assert Era.evidence({:status, 204}) == :none
    end

    test "only method-not-found demotes among JSON-RPC errors" do
      assert Era.evidence({:jsonrpc_error, -32_601}) == :demote
      assert Era.evidence({:jsonrpc_error, -32_602}) == :none
      assert Era.evidence({:jsonrpc_error, -32_603}) == :none
      assert Era.evidence(:none) == :none
    end

    test "the breaker's view agrees with the health verdict" do
      assert Era.unhealthy?(400)
      assert Era.unhealthy?(403)
      assert Era.unhealthy?(503)
      refute Era.unhealthy?(404)
      refute Era.unhealthy?(200)
    end
  end

  describe "the verdict cache" do
    test "a remembered verdict is read back" do
      table = table()
      key = {"https://example.test:443", "/mcp"}

      assert Era.verdict(table, key) == :miss
      assert Era.remember(table, key, :legacy) == :ok
      assert Era.verdict(table, key) == {:ok, :legacy}
    end

    test "two endpoints on one origin hold their own verdicts" do
      # A per-origin key would hand every endpoint on a gateway one era.
      table = table()
      Era.remember(table, {"https://gw.test:443", "/tron"}, :legacy)
      Era.remember(table, {"https://gw.test:443", "/canton"}, :modern)

      assert Era.verdict(table, {"https://gw.test:443", "/tron"}) == {:ok, :legacy}
      assert Era.verdict(table, {"https://gw.test:443", "/canton"}) == {:ok, :modern}
    end

    test "a verdict expires on its TTL and the row is reclaimed" do
      table = table()
      key = {"https://example.test:443", "/mcp"}
      Era.remember(table, key, :legacy)

      assert Era.verdict(table, key, ttl_ms: 0) == :miss
      assert :ets.lookup(table, key) == []
    end

    test "forgetting is what a session rejection does" do
      table = table()
      key = {"https://example.test:443", "/mcp"}
      Era.remember(table, key, :legacy)

      assert Era.forget(table, key) == :ok
      assert Era.verdict(table, key) == :miss
    end
  end

  describe "the key" do
    test "carries the path and the port, and drops the query and the userinfo" do
      # A per-account URL can carry a credential in the query or the userinfo,
      # and ADR-0033 section 7 names a cache key as one of the four places a
      # credential leaks.
      {:ok, uri} = URI.new("https://user:secret@example.test/mcp?token=sk-live")

      assert Era.key(uri) == {"https://example.test:443", "/mcp"}
      refute inspect(Era.key(uri)) =~ "sk-live"
      refute inspect(Era.key(uri)) =~ "secret"
    end

    test "a pathless URL keys on the root" do
      {:ok, uri} = URI.new("https://example.test")
      assert Era.key(uri) == {"https://example.test:443", "/"}
    end

    test "a non-default port is part of the origin" do
      {:ok, uri} = URI.new("https://example.test:8443/mcp")
      assert Era.origin(uri) == "https://example.test:8443"
    end
  end
end
