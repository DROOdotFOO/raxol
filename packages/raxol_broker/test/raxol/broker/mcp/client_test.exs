defmodule Raxol.Broker.MCP.ClientTest do
  @moduledoc """
  The broker session end to end, against in-process stand-ins for both
  Robinhood servers: the authorization server replays the recorded auth
  exchange through the `:http_fn` seam, and the MCP server is the legacy-era
  reference server behind a bearer gate, driven through the transport's
  `:exchange` seam. The loopback callback socket, the encrypted store, the
  MCP transport and the refresh logic are all the real ones.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.CredentialStore
  alias Raxol.Broker.Login
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Test.AuthServer
  alias Raxol.Broker.Test.Browser
  alias Raxol.Broker.Test.Fixtures
  alias Raxol.Broker.Test.MCPServer
  alias Raxol.Broker.Test.MemoryKeys

  @moduletag :tmp_dir

  setup_all do
    unless Code.ensure_loaded?(Raxol.MCP.Client.ReferenceServer.Legacy) and
             Code.ensure_loaded?(Raxol.MCP.Client.Transport.Http) do
      raise "raxol_broker tests need raxol_mcp built with plug and mint"
    end

    :ok
  end

  setup %{tmp_dir: dir} do
    token = Fixtures.load("token_response")
    refreshed = Fixtures.load("refresh_response")

    {:ok,
     store: [
       path: Path.join([dir, "broker", "robinhood.credential"]),
       key_provider: {MemoryKeys, agent: MemoryKeys.start()}
     ],
     auth: AuthServer.start(),
     mcp: MCPServer.start(),
     token: token,
     refreshed: refreshed,
     secrets: [
       token["access_token"],
       token["refresh_token"],
       token["user_uuid"],
       refreshed["access_token"],
       refreshed["refresh_token"]
     ]}
  end

  # The credential the recorded sign-in produced, already stored.
  defp seed(ctx, expires_at \\ DateTime.add(DateTime.utc_now(), 810_101, :second)) do
    credential = %Credential{
      provider: :robinhood,
      issuer: "https://agent.robinhood.com/mcp/trading",
      client_id: Fixtures.load("registration_response")["client_id"],
      access_token: ctx.token["access_token"],
      refresh_token: ctx.token["refresh_token"],
      expires_at: expires_at,
      scope: "internal",
      user_uuid: ctx.token["user_uuid"]
    }

    :ok = CredentialStore.put(credential, ctx.store)
    AuthServer.issue_refresh(ctx.auth, ctx.token["refresh_token"])
    credential
  end

  defp start_broker(ctx) do
    opts = [
      store: ctx.store,
      auth: [http_fn: AuthServer.http_fn(ctx.auth)],
      mcp: MCPServer.mcp_opts(ctx.mcp),
      connect_timeout: 5_000
    ]

    start_supervised!({Client, opts})
  end

  defp tool_names(tools), do: Enum.map(tools, & &1.name)

  test "a recorded sign-in stores an encrypted credential the broker connects with", ctx do
    assert :ok =
             Login.run(
               auth: [
                 browser_fn: Browser.approve(ctx.auth),
                 http_fn: AuthServer.http_fn(ctx.auth),
                 timeout: 5_000
               ],
               store: ctx.store
             )

    raw = File.read!(ctx.store[:path])
    for secret <- ctx.secrets, do: refute(raw =~ secret)

    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)

    assert {:ok, tools} = Client.list_tools(broker)
    assert tools != []
    assert tool_names(tools) == ["get_accounts", "get_equity_quotes"]
  end

  test "a mid-session 401 refreshes once, persists the rotation, and retries", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    # The access token stops working server-side; only the rotated one will.
    MCPServer.accept(ctx.mcp, [ctx.refreshed["access_token"]])

    assert {:ok, %{content: [_ | _], is_error: false}} =
             Client.call(broker, "get_accounts", %{})

    assert AuthServer.refresh_count(ctx.auth) == 1

    calls = for {"tools/call", status} <- MCPServer.requests(ctx.mcp), do: status
    assert calls == [401, 200]

    assert {:ok, stored} = CredentialStore.fetch(ctx.store)
    assert stored.refresh_token == ctx.refreshed["refresh_token"]
    assert stored.access_token == ctx.refreshed["access_token"]
  end

  test "a 401 after the refresh is :unauthorized, stays up, and sends nothing more", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    MCPServer.accept(ctx.mcp, [])

    capture_log(fn ->
      assert {:error, :unauthorized} = Client.call(broker, "get_accounts", %{})
    end)

    assert AuthServer.refresh_count(ctx.auth) == 1
    assert Process.alive?(broker)

    seen = MCPServer.requests(ctx.mcp)

    assert {:error, :unauthorized} = Client.call(broker, "get_equity_quotes", %{})
    assert {:error, :unauthorized} = Client.list_tools(broker)

    # The status call is a round trip through the broker, so anything a
    # reconnect loop would have sent by now has been sent.
    _ = :sys.get_state(broker)
    assert MCPServer.requests(ctx.mcp) == seen
    assert AuthServer.refresh_count(ctx.auth) == 1
  end

  test "concurrent callers hitting a 401 share one refresh", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    MCPServer.accept(ctx.mcp, [ctx.refreshed["access_token"]])

    results =
      1..6
      |> Task.async_stream(fn i -> Client.call(broker, "get_equity_quotes", %{"i" => i}) end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, %{is_error: false}}, &1))
    assert AuthServer.refresh_count(ctx.auth) == 1
  end

  test "an expired credential is refreshed once before concurrent callers use it", ctx do
    seed(ctx, DateTime.add(DateTime.utc_now(), -60, :second))
    MCPServer.accept(ctx.mcp, [ctx.refreshed["access_token"]])
    broker = start_broker(ctx)

    results =
      1..6
      |> Task.async_stream(fn _ -> Client.call(broker, "get_accounts", %{}) end,
        max_concurrency: 6
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert AuthServer.refresh_count(ctx.auth) == 1

    # The expired token never went on the wire.
    assert Enum.all?(MCPServer.requests(ctx.mcp), fn {_method, status} -> status != 401 end)
  end

  test "a 403 is returned as is and never refreshes", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    MCPServer.forbid_calls(ctx.mcp)
    broker = start_broker(ctx)

    assert {:error, {:http, 403}} = Client.call(broker, "get_accounts", %{})
    assert AuthServer.refresh_count(ctx.auth) == 0
  end

  test "write-shaped and unknown tools are denied without a request", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)
    seen = MCPServer.requests(ctx.mcp)

    for name <-
          ~w(place_equity_order cancel_equity_order review_equity_order replace_equity_order
             preview_crypto_order exercise_option create_watchlist add_to_watchlist
             create_alert update_scan_config not_a_tool) do
      assert {:error, {:tool_denied, ^name}} = Client.call(broker, name, %{})
      assert {:error, {:tool_denied, ^name}} = Client.authorize_tool(name)
    end

    _ = :sys.get_state(broker)
    assert MCPServer.requests(ctx.mcp) == seen
  end

  test "neither logs nor process state carry a token or the account id", ctx do
    seed(ctx)
    MCPServer.accept(ctx.mcp, [ctx.token["access_token"]])

    log =
      capture_log(fn ->
        broker = start_broker(ctx)
        assert {:ok, _tools} = Client.list_tools(broker)
        MCPServer.accept(ctx.mcp, [ctx.refreshed["access_token"]])
        assert {:ok, _result} = Client.call(broker, "get_accounts", %{})

        status = inspect(:sys.get_status(broker), limit: :infinity, printable_limit: :infinity)
        state = inspect(:sys.get_state(broker), limit: :infinity, printable_limit: :infinity)

        for secret <- ctx.secrets do
          refute status =~ secret
          refute state =~ secret
        end

        refute status =~ "Bearer"
        refute state =~ "Bearer"
      end)

    for secret <- ctx.secrets, do: refute(log =~ secret)
    refute log =~ ~r/authorization/i
    refute log =~ "Bearer"
  end
end
