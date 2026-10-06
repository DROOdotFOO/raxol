defmodule Raxol.Broker.MCP.ClientTest do
  @moduledoc """
  The broker session end to end, against in-process stand-ins for both
  Robinhood servers: the authorization server replays the recorded auth
  exchange through the `:http_fn` seam, and the MCP server is
  `Raxol.Broker.MCP.Fake` (the legacy-era reference server) behind its bearer
  gate, driven through the transport's `:exchange` seam. The loopback
  callback socket, the encrypted store, the MCP transport and the refresh
  logic are all the real ones.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.CredentialStore
  alias Raxol.Broker.Login
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.AuthServer
  alias Raxol.Broker.Test.Browser
  alias Raxol.Broker.Test.Fixtures
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
     mcp: Fake.start(accept: []),
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
      mcp: Fake.mcp_opts(ctx.mcp),
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

    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)

    assert {:ok, tools} = Client.list_tools(broker)
    assert tools != []
    # The Fake serves the recorded five plus its three scenario tools; the
    # broker keeps only the read-only ones, never place/cancel/review.
    assert tool_names(tools) ==
             ~w(get_accounts get_equity_quotes get_equity_positions get_equity_orders get_alert_log)
  end

  test "a mid-session 401 refreshes once, persists the rotation, and retries", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    # The access token stops working server-side; only the rotated one will.
    Fake.accept(ctx.mcp, [ctx.refreshed["access_token"]])

    assert {:ok, %{content: [_ | _], is_error: false}} =
             Client.call(broker, "get_accounts", %{})

    assert AuthServer.refresh_count(ctx.auth) == 1

    calls = for {"tools/call", _tool, status} <- Fake.requests(ctx.mcp), do: status
    assert calls == [401, 200]

    assert {:ok, stored} = CredentialStore.fetch(ctx.store)
    assert stored.refresh_token == ctx.refreshed["refresh_token"]
    assert stored.access_token == ctx.refreshed["access_token"]
  end

  test "a token rejected at the handshake refreshes after exactly one initialize", ctx do
    # Live, 2026-10-03: the inner client kept re-sending `initialize` with the
    # dead token once a second until the shared breaker opened, so the broker
    # saw `:breaker_open` instead of the 401 and never refreshed.
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.refreshed["access_token"]])
    broker = start_broker(ctx)

    assert {:ok, [_ | _]} = Client.list_tools(broker)
    assert AuthServer.refresh_count(ctx.auth) == 1

    handshakes = for {"initialize", _tool, status} <- Fake.requests(ctx.mcp), do: status
    assert handshakes == [401, 200]
  end

  test "a 401 after the refresh is :unauthorized, stays up, and sends nothing more", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    Fake.accept(ctx.mcp, [])

    capture_log(fn ->
      assert {:error, :unauthorized} = Client.call(broker, "get_accounts", %{})
    end)

    assert AuthServer.refresh_count(ctx.auth) == 1
    assert Process.alive?(broker)

    seen = Fake.requests(ctx.mcp)

    assert {:error, :unauthorized} = Client.call(broker, "get_equity_quotes", %{})
    assert {:error, :unauthorized} = Client.list_tools(broker)

    # The status call is a round trip through the broker, so anything a
    # reconnect loop would have sent by now has been sent.
    _ = :sys.get_state(broker)
    assert Fake.requests(ctx.mcp) == seen
    assert AuthServer.refresh_count(ctx.auth) == 1
  end

  test "concurrent callers hitting a 401 share one refresh", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)

    Fake.accept(ctx.mcp, [ctx.refreshed["access_token"]])

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
    Fake.accept(ctx.mcp, [ctx.refreshed["access_token"]])
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
    assert Enum.all?(Fake.requests(ctx.mcp), fn {_method, _tool, status} -> status != 401 end)
  end

  test "a 403 is returned as is and never refreshes", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    Fake.forbid_calls(ctx.mcp)
    broker = start_broker(ctx)

    assert {:error, {:http, 403}} = Client.call(broker, "get_accounts", %{})
    assert AuthServer.refresh_count(ctx.auth) == 0
  end

  test "write-shaped and unknown tools are denied without a request", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])
    broker = start_broker(ctx)
    assert {:ok, _tools} = Client.list_tools(broker)
    seen = Fake.requests(ctx.mcp)

    for name <-
          ~w(place_equity_order cancel_equity_order review_equity_order replace_equity_order
             preview_crypto_order exercise_option create_watchlist add_to_watchlist
             create_alert update_scan_config not_a_tool) do
      assert {:error, {:tool_denied, ^name}} = Client.call(broker, name, %{})
      assert {:error, {:tool_denied, ^name}} = Client.authorize_tool(name)
    end

    _ = :sys.get_state(broker)
    assert Fake.requests(ctx.mcp) == seen
  end

  test "neither logs nor process state carry a token or the account id", ctx do
    seed(ctx)
    Fake.accept(ctx.mcp, [ctx.token["access_token"]])

    log =
      capture_log(fn ->
        broker = start_broker(ctx)
        assert {:ok, _tools} = Client.list_tools(broker)
        Fake.accept(ctx.mcp, [ctx.refreshed["access_token"]])
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

  describe "throttling" do
    defp start_against_fake(fake, backoff),
      do: start_supervised!({Client, Fake.client_opts(fake, backoff: backoff)})

    defp statuses(fake, tool),
      do: for({"tools/call", ^tool, status} <- Fake.requests(fake), do: status)

    defp answers(fake, method),
      do: for({^method, nil, status} <- Fake.requests(fake), do: status)

    test "a 429 is retried with backoff until it answers" do
      fake =
        Fake.start(
          quotes: %{"AAPL" => "125"},
          faults: [{"get_equity_quotes", {:http, 429}, 2}]
        )

      broker = start_against_fake(fake, base_ms: 1)

      assert {:ok, %{is_error: false}} =
               Client.call(broker, "get_equity_quotes", %{"symbols" => ["AAPL"]})

      assert statuses(fake, "get_equity_quotes") == [429, 429, 200]
    end

    test "after :retries the throttle status is returned" do
      fake = Fake.start(faults: [{"get_accounts", {:http, 503}, 10}])
      broker = start_against_fake(fake, base_ms: 1, retries: 2)

      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 503}}
      assert statuses(fake, "get_accounts") == [503, 503, 503]
    end

    test "a status that is not throttling is not retried" do
      fake = Fake.start(faults: [{"get_accounts", {:http, 500}}])
      broker = start_against_fake(fake, base_ms: 1)

      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 500}}
      assert statuses(fake, "get_accounts") == [500]
    end

    test "a retry that would pass the caller's timeout is not sent" do
      fake = Fake.start(faults: [{"get_accounts", {:http, 429}, 5}])
      broker = start_against_fake(fake, base_ms: 60_000, max_ms: 60_000)

      assert Client.call(broker, "get_accounts", %{}, 5_000) == {:error, {:http, 429}}
      assert statuses(fake, "get_accounts") == [429]
    end

    test "retries never open the breaker; a throttled call answers its status" do
      fake = Fake.start(faults: [{"get_accounts", {:http, 429}, 8}])
      broker = start_against_fake(fake, base_ms: 1, retries: 10)

      # Four failures leave one before the threshold of five: no fifth retry.
      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 429}}
      assert statuses(fake, "get_accounts") == [429, 429, 429, 429]

      # The next call's own failure opens it; the call still answers its status.
      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 429}}
      assert Client.call(broker, "get_accounts", %{}) == {:error, :breaker_open}
      assert statuses(fake, "get_accounts") == [429, 429, 429, 429, 429]
    end

    # A slow `initialize` holds the connect open, so the calls queue behind it.
    test "a 429 on the connect's tool list is retried before the queued call" do
      fake = Fake.start(faults: [{"initialize", {:slow, 100}}, {"tools/list", {:http, 429}}])
      broker = start_against_fake(fake, base_ms: 1)

      assert {:ok, %{is_error: false}} = Client.call(broker, "get_accounts", %{})
      assert answers(fake, "tools/list") == [429, 200]
      assert answers(fake, "initialize") == [200, 200]
      assert statuses(fake, "get_accounts") == [200]
    end

    test "a connect throttled past :retries answers queued callers and stays up" do
      fake =
        Fake.start(faults: [{"initialize", {:slow, 100}}, {"tools/list", {:http, 429}, 3}])

      broker = start_against_fake(fake, base_ms: 1, retries: 2)

      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 429}}
      assert answers(fake, "tools/list") == [429, 429, 429]
      assert statuses(fake, "get_accounts") == []

      assert {:ok, %{is_error: false}} = Client.call(broker, "get_accounts", %{})
      assert statuses(fake, "get_accounts") == [200]
    end

    test "a queued caller the connect's next delay would outlast gets the status" do
      fake = Fake.start(faults: [{"initialize", {:slow, 100}}, {"tools/list", {:http, 429}}])
      broker = start_against_fake(fake, base_ms: 2_000, max_ms: 2_000)

      # Its deadline is the longest first delay away, so any delay passes it.
      short = Task.async(fn -> Client.call(broker, "get_accounts", %{}, 2_000) end)
      long = Task.async(fn -> Client.call(broker, "get_accounts", %{}) end)

      assert Task.await(short) == {:error, {:http, 429}}
      assert {:ok, %{is_error: false}} = Task.await(long, 10_000)
      assert statuses(fake, "get_accounts") == [200]
    end

    test "a throttled handshake is retried and answers the bare status" do
      fake = Fake.start(faults: [{"initialize", {:http, 503}, 2}])

      # The inner client's own reconnect is pushed past the connect budget, so
      # every `initialize` after the first is a broker retry.
      opts =
        Fake.client_opts(fake,
          backoff: [base_ms: 1, retries: 1],
          connect_timeout: 200,
          mcp: Fake.mcp_opts(fake) ++ [reconnect_ms: 60_000]
        )

      broker = start_supervised!({Client, opts})

      assert Client.call(broker, "get_accounts", %{}) == {:error, {:http, 503}}
      assert answers(fake, "initialize") == [503, 503]
    end

    test "a throttle on the post-refresh retry still locks out on the next 401", ctx do
      seed(ctx)
      r1 = ctx.refreshed
      r2 = %{r1 | "refresh_token" => "fake-refresh-token-rt-2", "access_token" => "fake-at-2"}
      r3 = %{r1 | "refresh_token" => "fake-refresh-token-rt-3", "access_token" => "fake-at-3"}
      auth = AuthServer.start(refreshes: [r1, r2, r3])
      AuthServer.issue_refresh(auth, ctx.token["refresh_token"])

      fake =
        Fake.start(
          faults: [
            {"get_accounts", {:http, 401}},
            {"get_accounts", {:http, 429}},
            {"get_accounts", {:http, 401}},
            {"get_accounts", {:http, 429}},
            {"get_accounts", {:http, 401}}
          ]
        )

      broker =
        start_supervised!(
          {Client,
           store: ctx.store,
           auth: [http_fn: AuthServer.http_fn(auth)],
           mcp: Fake.mcp_opts(fake),
           connect_timeout: 5_000,
           backoff: [base_ms: 1]}
        )

      assert Client.call(broker, "get_accounts", %{}) == {:error, :unauthorized}
      assert AuthServer.refresh_count(auth) == 1
      assert statuses(fake, "get_accounts") == [401, 429, 401]
    end

    test "invalid :backoff values stop the session at start" do
      fake = Fake.start()

      for backoff <- [
            [retries: :infinity],
            [base_ms: 1.5],
            [max_ms: 4_294_967_296],
            [jitter: 1],
            :fast
          ] do
        assert {:error, {{:invalid_backoff, ^backoff}, _child}} =
                 start_supervised({Client, Fake.client_opts(fake, backoff: backoff)}),
               inspect(backoff)
      end
    end
  end
end
