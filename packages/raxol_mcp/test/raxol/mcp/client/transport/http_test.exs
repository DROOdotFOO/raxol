defmodule Raxol.MCP.Client.Transport.HttpTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Core.Outbound
  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Era
  alias Raxol.MCP.Client.Reservation
  alias Raxol.MCP.Client.ReferenceServer
  alias Raxol.MCP.Client.ReferenceServer.Legacy
  alias Raxol.MCP.Client.ReferenceServer.Modern
  alias Raxol.MCP.Client.Transport

  # ADR-0037 validation items 3, 4, 6, 7 and the transport half of 9. The two
  # reference servers live in `lib/` (ADR-0033 section 3's convention: a
  # reference implementation, never a mocking library) and are driven through
  # the transport's `:exchange` seam, so the scheme check, the reject set, the
  # era probe, the era headers, the metering gate and the SSE parser all run for
  # real. The socket itself is tested in `Transport.Http.ExchangeTest`, because
  # a local listener answers on loopback and the reject set refuses loopback by
  # design.

  setup_all do
    # The build shape matters: these servers need `plug`, which is optional
    # here. Their absence must fail the run rather than skip it.
    unless Code.ensure_loaded?(Modern) and Code.ensure_loaded?(Transport.Http) do
      raise "raxol_mcp must be built with plug and mint for the remote transport tests"
    end

    :ok
  end

  @url "https://mcp.example.test/mcp"
  @key {"https://mcp.example.test:443", "/mcp"}
  @origin "https://mcp.example.test:443"
  @accept "application/json, text/event-stream"
  @public {93, 184, 216, 34}

  defp tables do
    %{
      eras: :ets.new(:eras, [:set, :public]),
      breakers: CircuitBreaker.new(:breakers),
      reservations: Reservation.new(:reservations)
    }
  end

  # What the spend hook hands the transport for a priced call: a handle it
  # minted and the transport spends exactly once.
  defp reservation(tables), do: Reservation.mint(tables.reservations)

  defp resolver(addresses \\ [@public]) do
    fn
      _host, :inet -> {:ok, addresses}
      _host, :inet6 -> {:ok, []}
    end
  end

  defp modern(opts \\ []), do: ReferenceServer.seam(Modern, ReferenceServer.state(:modern, opts))
  defp legacy(opts \\ []), do: ReferenceServer.seam(Legacy, ReferenceServer.state(:legacy, opts))

  defp spec(seam, tables, extra \\ []) do
    [
      name: :"remote_#{System.unique_integer([:positive])}",
      url: @url,
      tables: tables,
      resolver: resolver(),
      exchange: seam
    ] ++ extra
  end

  defp start_client!(spec) do
    {:ok, client} = Client.start_link(spec)
    on_exit(fn -> stop_quietly(client) end)
    client
  end

  # An `on_exit` stop races the exit signal a linked client is already getting.
  defp stop_quietly(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end

  defp handle!(seam, tables, extra \\ []) do
    config = seam |> spec(tables, extra) |> Map.new()
    {:ok, handle} = Transport.Http.connect(config)
    handle
  end

  # One real round trip, decoded the way the client decodes it. `send/3`
  # registers a monitored task and this process is its owner, so the reply
  # arrives here carrying the reference `decode_info/2` verifies.
  defp round_trip(handle, id, request) do
    assert {:ok, handle} = Transport.Http.send(handle, id, request)
    assert_receive {:mcp_http, ref, ^id, outcome}, 1_000
    Transport.Http.decode_info(handle, {:mcp_http, ref, id, outcome})
  end

  defp initialize, do: %{method: "initialize", params: %{}}
  defp list_tools, do: %{method: "tools/list", params: %{}}

  # Readiness is an event the client answers, not a state to poll for: a
  # sleep loop can only observe a state the client has already left, and on a
  # loaded runner it observes none.
  #
  # The handshake is not over at `:ready` though: `notifications/initialized`
  # is a POST, it holds an in-flight slot, and a test that proceeds while it
  # is still running races it -- for the session it is about to expire, for
  # the in-flight cap it occupies, and for the ETS tables its task reads.
  defp await_ready(client, timeout \\ 5_000) do
    assert {:ok, _ready} = Client.await_ready(client, timeout)
    await_status(client, %{pending: 0})
  end

  defp await_status(client, expected, tries \\ 100) do
    status = Client.status(client)

    if Map.take(status, Map.keys(expected)) == expected do
      status
    else
      if tries > 0 do
        Process.sleep(10)
        await_status(client, expected, tries - 1)
      else
        flunk("client status settled at #{inspect(status)}, wanted #{inspect(expected)}")
      end
    end
  end

  defp request_method(request) do
    request.body |> IO.iodata_to_binary() |> Jason.decode!() |> Map.get("method")
  end

  defp initialization_response(request, response) do
    id = request.body |> IO.iodata_to_binary() |> Jason.decode!() |> Map.fetch!("id")

    {:ok,
     %{
       status: 200,
       headers: [{"content-type", "application/json"}],
       body: Jason.encode!(Map.put(response, "id", id))
     }}
  end

  # Every request the reference servers saw, in order. Called after the calls
  # under test have returned, so the mailbox is complete rather than raced.
  defp observations(acc \\ []) do
    receive do
      {:reference_server, observation} -> observations([observation | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp methods(observations), do: Enum.map(observations, & &1.method)

  defp header(%{headers: headers}, name) do
    case List.keyfind(headers, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end

  # A legacy server that refuses the probe rather than answering
  # method-not-found under a 200, which is what both measured stateful
  # upstreams do. Everything after the probe is the ordinary legacy server.
  defp refusing_probe(body) do
    inner = legacy()

    fn vetted, request, opts ->
      if String.contains?(IO.iodata_to_binary(request.body), "server/discover") do
        {:ok, %{status: 400, headers: [{"content-type", "application/json"}], body: body}}
      else
        inner.(vetted, request, opts)
      end
    end
  end

  defp tool(name) do
    %{"name" => name, "description" => name, "inputSchema" => %{"type" => "object"}}
  end

  describe "the era probe" do
    test "a modern origin skips the handshake and caches its verdict" do
      tables = tables()
      client = start_client!(spec(modern(), tables))

      assert %{status: :ready, version: "2026-07-28", concurrency: :stateless} =
               Client.status(client)

      assert {:ok, [%{name: "echo"}]} = Client.list_tools(client)
      assert Era.verdict(tables.eras, @key) == {:ok, :modern}

      seen = methods(observations())
      assert "server/discover" in seen
      assert "tools/list" in seen
      # SEP-2575 removed it, and a modern server is specified not to answer it.
      refute "initialize" in seen
    end

    test "a legacy origin handshakes, and its verdict comes from method-not-found" do
      tables = tables()
      client = start_client!(spec(legacy(), tables))

      assert %{version: "2025-06-18", concurrency: :serialized} = await_ready(client)
      assert {:ok, [%{name: "echo"}]} = Client.list_tools(client)
      assert Era.verdict(tables.eras, @key) == {:ok, :legacy}

      seen = observations()
      assert ["server/discover", "initialize" | rest] = methods(seen)
      assert "notifications/initialized" in rest
      assert "tools/list" in rest
    end

    test "a second client on the same tables reuses the cached verdict" do
      tables = tables()
      seam = modern()

      start_client!(spec(seam, tables)) |> Client.list_tools()
      _first = observations()

      start_client!(spec(seam, tables)) |> Client.list_tools()
      assert methods(observations()) == ["tools/list"]
    end

    test "a verdict past its TTL is re-probed, and one inside it is not" do
      tables = tables()
      seam = legacy()

      # A TTL of zero trusts no cached verdict, so the second client probes.
      start_client!(spec(seam, tables, era_ttl_ms: 0)) |> await_ready()
      start_client!(spec(seam, tables, era_ttl_ms: 0)) |> await_ready()
      assert Enum.count(methods(observations()), &(&1 == "server/discover")) == 2

      # And with the default TTL the verdict written above is still good.
      start_client!(spec(seam, tables)) |> await_ready()
      refute Enum.any?(methods(observations()), &(&1 == "server/discover"))
    end

    test "a rejected session re-probes once, re-handshakes, and works again" do
      tables = tables()
      state = ReferenceServer.state(:legacy, [])
      client = start_client!(spec(ReferenceServer.seam(Legacy, state), tables))
      await_ready(client)

      # Expire every session behind the client's back, which is what a restarted
      # or evicting upstream does.
      :ets.delete_all_objects(state.sessions)
      _handshake = observations()

      assert {:error, :session_rejected} = Client.call_tool(client, "echo", %{})

      # The re-probe runs in a monitored task, so its observation is awaited
      # rather than drained: draining would race the task.
      assert_receive {:reference_server, %{method: "server/discover"}}, 1_000

      # The rejection also re-handshakes, and that half was missing: the
      # transport can forget a dead session id but only the client can mint a
      # new one. Without it every later request went out with no
      # `mcp-session-id`, the origin answered 404 to all of them, and
      # `{:http, 404}` is neither a failover reason nor a breaker failure --
      # the client was wedged for the lifetime of the node.
      assert {:ok, _result} = Client.call_tool(client, "echo", %{})
      assert "initialize" in methods(observations())
    end

    test "a client whose first connect failed serves a later request" do
      # The connect ran once. On failure the client sat in `:closed` forever,
      # and a live process is one its supervisor will not restart, so a DNS
      # blip or an inherited open breaker at boot removed that upstream until
      # the VM was restarted.
      tables = tables()
      inner = modern()
      refusals = :counters.new(1, [])

      seam = fn vetted, request, opts ->
        if request_method(request) == "server/discover" and :counters.get(refusals, 1) == 0 do
          :counters.add(refusals, 1, 1)
          {:error, {:transport, :econnrefused}}
        else
          inner.(vetted, request, opts)
        end
      end

      client = start_client!(spec(seam, tables, reconnect_ms: 10))

      await_ready(client)
      assert :counters.get(refusals, 1) == 1
      assert {:ok, [%{name: "echo"}]} = Client.list_tools(client)
    end

    test "a successful round trip restores the ability to re-probe" do
      # `reprobed?` was set in `reprobe/2` and reset nowhere in the module, so a
      # legacy origin whose session expired a SECOND time -- routine across a
      # server restart -- failed every later request as `:session_rejected`
      # forever, with no path back to a fresh probe.
      tables = tables()
      state = ReferenceServer.state(:legacy, [])
      handle = handle!(ReferenceServer.seam(Legacy, state), tables)

      # The handshake the client's session machine performs: it mints the
      # session, and it is the success this transport counts.
      assert {:messages, _initialized, handle} = round_trip(handle, 1, initialize())
      _probe_and_handshake = observations()

      # Expire every session behind the handle's back, which is what a restarted
      # upstream does. The rejection re-probes.
      :ets.delete_all_objects(state.sessions)
      assert {:failed, 2, :session_rejected, handle} = round_trip(handle, 2, list_tools())
      assert_receive {:reference_server, %{method: "server/discover"}}, 1_000
      _first_reprobe = observations()

      # Handshake again, expire again: this rejection must re-probe too.
      assert {:messages, _reinitialized, handle} = round_trip(handle, 3, initialize())
      :ets.delete_all_objects(state.sessions)
      _second_handshake = observations()

      assert {:failed, 4, :session_rejected, _handle} = round_trip(handle, 4, list_tools())
      assert_receive {:reference_server, %{method: "server/discover"}}, 1_000
    end

    @tag timeout: 10_000
    test "a re-probe does not block the process that decoded the rejection" do
      # `reprobe/2` called `resolve_era/1` -> `probe/1` -> the exchange, a
      # synchronous connect-and-read, and `decode_info/2` runs inside the
      # client's `handle_manager_info`. One `:session_rejected` therefore
      # stalled the whole mailbox -- every queued `call_tool` and every
      # `{:request_timeout, id}` -- for up to `deadline_ms`, which is the
      # opposite of what this module's moduledoc claims.
      #
      # The gate is ordering, not elapsed time: this process is the only one
      # that can release the probe's exchange, so a synchronous probe deadlocks
      # and a probe in a task returns here first. The tag bounds that deadlock.
      tables = tables()
      state = ReferenceServer.state(:legacy, [])
      inner = ReferenceServer.seam(Legacy, state)
      test = self()
      probes = :counters.new(1, [])

      seam = fn vetted, request, opts ->
        if String.contains?(IO.iodata_to_binary(request.body), "server/discover") do
          :counters.add(probes, 1, 1)

          # The connect-time probe runs in this process by design, so only the
          # re-probe is held open.
          if :counters.get(probes, 1) > 1 do
            Kernel.send(test, {:probing, self()})
            receive do: (:release -> :ok)
          end
        end

        inner.(vetted, request, opts)
      end

      handle = handle!(seam, tables)
      assert {:messages, _initialized, handle} = round_trip(handle, 1, initialize())

      :ets.delete_all_objects(state.sessions)
      assert {:ok, handle} = Transport.Http.send(handle, 2, list_tools())
      assert_receive {:mcp_http, ref, 2, :session_rejected}, 1_000

      # The call that used to run the probe's whole round trip inline.
      assert {:failed, 2, :session_rejected, handle} =
               Transport.Http.decode_info(handle, {:mcp_http, ref, 2, :session_rejected})

      assert_receive {:probing, task}, 1_000
      refute task == self()

      Kernel.send(task, :release)
      assert_receive {:mcp_http_probe, probe_ref, result}, 1_000

      # And the verdict is applied where the handle lives, not in the task.
      assert {:messages, [], %{era: :legacy}} =
               Transport.Http.decode_info(handle, {:mcp_http_probe, probe_ref, result})
    end

    test "a probe refused with HTTP 400 is not persisted as legacy" do
      tables = tables()
      client = start_client!(spec(refusing_probe("bad request"), tables))

      assert {:error, {:connect_failed, {:http, 400}}} = Client.list_tools(client)
      assert Era.verdict(tables.eras, @key) == :miss
      assert %{failures: 1} = CircuitBreaker.status(tables.breakers, {:origin, @origin})
    end

    test "initialization timeout closes the client instead of leaving it stuck" do
      inner = legacy()

      seam = fn vetted, request, opts ->
        if request_method(request) == "initialize" do
          receive do: (:release_initialization -> inner.(vetted, request, opts))
        else
          inner.(vetted, request, opts)
        end
      end

      client = start_client!(spec(seam, tables(), init_timeout: 30))

      assert %{status: :closed, pending: 0} =
               await_status(client, %{status: :closed, pending: 0})

      assert {:error, {:connect_failed, {:initialization_failed, :timeout}}} =
               Client.list_tools(client)
    end

    test "an explicit initialization error closes the client with the reason" do
      inner = legacy()
      error = %{"code" => -32_603, "message" => "initialization refused"}

      seam = fn vetted, request, opts ->
        if request_method(request) == "initialize" do
          initialization_response(request, %{"jsonrpc" => "2.0", "error" => error})
        else
          inner.(vetted, request, opts)
        end
      end

      client = start_client!(spec(seam, tables()))

      assert %{status: :closed, pending: 0} =
               await_status(client, %{status: :closed, pending: 0})

      assert {:error, {:connect_failed, {:initialization_failed, {:jsonrpc, ^error}}}} =
               Client.list_tools(client)
    end
  end

  describe "a refusal is not an era" do
    test "a 403 records unhealth, leaves the verdict unset, and the next 200 says modern" do
      # The wedge. Demoting on a transport-level 4xx would cache `legacy`
      # forever after one Cloudflare mitigation, after which every call sends an
      # `initialize` that a modern server is specified not to answer.
      tables = tables()
      seam = modern(refuse: 1)

      client = start_client!(spec(seam, tables))
      assert {:error, {:connect_failed, {:http, 403}}} = Client.list_tools(client)
      assert Era.verdict(tables.eras, @key) == :miss
      assert %{failures: 1} = CircuitBreaker.status(tables.breakers, {:origin, @origin})

      second = start_client!(spec(seam, tables))
      assert {:ok, [%{name: "echo"}]} = Client.list_tools(second)
      assert Era.verdict(tables.eras, @key) == {:ok, :modern}
    end

    test "a breaker that has opened refuses before any request is issued" do
      tables = tables()
      seam = modern()

      for _ <- 1..5,
          do: CircuitBreaker.record_failure(tables.breakers, {:origin, @origin})

      client = start_client!(spec(seam, tables))
      assert {:error, {:connect_failed, :breaker_open}} = Client.list_tools(client)
      assert observations() == []
    end
  end

  describe "header compliance" do
    test "every post carries the mandatory Accept and the modern era headers" do
      client = start_client!(spec(modern(tools: [tool("echo")]), tables()))
      assert {:ok, _tools} = Client.list_tools(client)
      assert {:ok, _result} = Client.call_tool(client, "echo", %{"x" => 1})

      seen = observations()
      assert length(seen) == 3

      for observation <- seen do
        assert header(observation, "accept") == @accept
        assert header(observation, "mcp-method") == observation.method
        assert header(observation, "mcp-name") != nil
        # SEP-2567 removed the session header; the reference server rejects one.
        assert header(observation, "mcp-session-id") == nil
      end

      call = Enum.find(seen, &(&1.method == "tools/call"))
      assert header(call, "mcp-name") == "echo"
    end

    test "a legacy post carries the revision and echoes the session it was issued" do
      client = start_client!(spec(legacy(), tables()))
      await_ready(client)
      assert {:ok, _tools} = Client.list_tools(client)

      seen = observations()
      probe = Enum.find(seen, &(&1.method == "server/discover"))
      list = Enum.find(seen, &(&1.method == "tools/list"))

      # The probe carries both eras' required headers, because it runs before
      # the verdict exists and a 2025-06-18 server answers 400 without the
      # revision -- which is not era evidence, so the probe would wedge.
      assert header(probe, "mcp-protocol-version") == "2025-06-18"
      assert header(probe, "mcp-method") == "server/discover"

      assert header(list, "mcp-protocol-version") == "2025-06-18"
      assert is_binary(header(list, "mcp-session-id"))
      # Once the era is known the headers are the era's, and the legacy era has
      # no routing headers at all.
      assert header(list, "mcp-method") == nil
    end

    test "a spec cannot override a header the transport owns" do
      headers = [
        {"accept", "application/json"},
        {"mcp-method", "evil/method"},
        {"authorization", "Bearer token"}
      ]

      client = start_client!(spec(modern(), tables(), headers: headers))
      assert {:ok, _tools} = Client.list_tools(client)

      list = Enum.find(observations(), &(&1.method == "tools/list"))
      assert header(list, "accept") == @accept
      assert header(list, "mcp-method") == "tools/list"
      # What a spec IS for still arrives.
      assert header(list, "authorization") == "Bearer token"
    end
  end

  describe "the target rules" do
    test "an http:// url is refused before anything is dialled" do
      assert {:error, {:blocked, :invalid_url}} =
               Transport.Http.connect(%{
                 name: :insecure,
                 url: "http://mcp.example.test/mcp",
                 tables: tables(),
                 resolver: resolver(),
                 exchange: modern()
               })

      assert observations() == []
    end

    test "the reject set refuses literals, mapped literals and resolver answers" do
      for url <- [
            "https://127.0.0.1/mcp",
            "https://169.254.169.254/mcp",
            "https://[::1]/mcp",
            "https://[::ffff:127.0.0.1]/mcp",
            "https://[::ffff:169.254.169.254]/mcp",
            "https://[2002:7f00:1::]/mcp",
            "https://10.0.0.1/mcp"
          ] do
        assert {:error, {:blocked, :address}} =
                 Transport.Http.connect(%{
                   name: :inward,
                   url: url,
                   tables: tables(),
                   exchange: modern()
                 }),
               "#{url} was not refused"
      end

      # And a name that resolves inward is refused too, which is the half an IP
      # literal cannot cover.
      assert {:error, {:blocked, :address}} =
               Transport.Http.connect(%{
                 name: :inward_name,
                 url: @url,
                 tables: tables(),
                 resolver: resolver([{10, 1, 2, 3}]),
                 exchange: modern()
               })
    end

    test "a resolver that changes its answer does not change the dialled address" do
      # The address handed to the exchange is the one that was CHECKED. A
      # transport that passed the hostname down instead would let the second
      # answer through, which is the rebinding gap rule 3 closes. The exchange
      # itself accepts nothing but address tuples, which is asserted where it
      # lives.
      counter = :counters.new(1, [])

      flipping = fn
        _host, :inet ->
          if :counters.get(counter, 1) == 0 do
            :counters.add(counter, 1, 1)
            {:ok, [@public]}
          else
            {:ok, [{127, 0, 0, 1}]}
          end

        _host, :inet6 ->
          {:ok, []}
      end

      client =
        start_client!(
          name: :flipping,
          url: @url,
          tables: tables(),
          resolver: flipping,
          exchange: modern()
        )

      assert {:ok, _tools} = Client.list_tools(client)

      for observation <- observations() do
        assert observation.addresses == [@public]
      end

      # The resolver really did change, so the first answer was not merely
      # returned twice.
      assert {:error, {:blocked_address, _host}} =
               Outbound.vet(@url, schemes: [:https], resolver: flipping)
    end

    test "a 3xx is an error rather than a location to follow" do
      # Following one would replay this transport's Authorization header at an
      # origin the upstream chose.
      test = self()

      redirecting = fn vetted, request, _opts ->
        Kernel.send(test, {:issued, vetted.uri.host, request})

        {:ok,
         %{
           status: 302,
           headers: [{"location", "https://elsewhere.test/mcp"}],
           body: ""
         }}
      end

      client =
        start_client!(
          name: :redirecting,
          url: @url,
          tables: tables(),
          resolver: resolver(),
          exchange: redirecting
        )

      assert {:error, {:connect_failed, {:redirect_refused, 302}}} = Client.list_tools(client)

      # The invariant is the target, not the count: a failed connect now
      # retries on a backoff, so "exactly one request" is a wall-clock
      # window and this is not.
      assert_receive {:issued, host, _probe}
      assert host == "mcp.example.test"
      assert Enum.all?(issued(), &(&1 == "mcp.example.test"))
    end

    defp issued(hosts \\ []) do
      receive do
        {:issued, host, _request} -> issued([host | hosts])
      after
        0 -> hosts
      end
    end

    test "no header value reaches an error term or a log line" do
      # ADR-0033 section 7 names the error path as where a credential leaks in
      # practice, so this is asserted on the error path specifically.
      secret = "Bearer sk-live-must-never-appear"

      failing = fn _vetted, _request, _opts ->
        {:ok, %{status: 500, headers: [], body: "upstream exploded"}}
      end

      log =
        capture_log(fn ->
          client =
            start_client!(
              name: :leaky,
              url: @url,
              tables: tables(),
              resolver: resolver(),
              exchange: failing,
              headers: [{"authorization", secret}]
            )

          assert {:error, reason} = Client.list_tools(client)
          assert reason == {:connect_failed, {:http, 500}}
          refute inspect(reason) =~ "sk-live"
          # Nor does the upstream's own body ride out in the error.
          refute inspect(reason) =~ "exploded"

          # The handle is in a GenServer's state, which a crash report prints.
          assert %{status: :closed} = Client.status(client)
        end)

      refute log =~ "sk-live"
    end

    test "the handle's inspect redacts what it holds" do
      handle = handle!(modern(), tables(), headers: [{"authorization", "Bearer sk-live-xyz"}])

      rendered = inspect(handle)
      refute rendered =~ "sk-live"
      assert rendered =~ "[redacted]"
    end
  end

  describe "metering at the transport" do
    test "a priced tool with no reservation issues no request" do
      handle = handle!(modern(tools: [tool("paid")]), tables(), prices: %{"paid" => 1})
      # Drained first: the probe's observation is already in the mailbox.
      assert methods(observations()) == ["server/discover"]

      request = %{method: "tools/call", params: %{name: "paid", arguments: %{}}}
      assert {:error, :unmetered_call} = Transport.Http.send(handle, 7, request)

      # `send/3` is synchronous up to spawning the task, so a refusal means
      # no task exists and the drained mailbox is exact. A `refute_receive`
      # window would be a false pass on a loaded runner either way.
      assert observations() == []
    end

    test "an invented reservation handle is refused like an absent one" do
      # The gate was `Map.get(request, :reservation)` truthiness, so this
      # string -- which is what a caller of the public `call_tool/4` can
      # invent -- bought a priced call. A handle now has to have been minted.
      handle = handle!(modern(tools: [tool("paid")]), tables(), prices: %{"paid" => 1})
      _probe = observations()

      request = %{
        method: "tools/call",
        params: %{name: "paid", arguments: %{}},
        reservation: "cost-ref-1"
      }

      assert {:error, :unmetered_call} = Transport.Http.send(handle, 7, request)
      assert observations() == []
    end

    test "a minted handle is spent once and refused the second time" do
      tables = tables()
      handle = handle!(modern(tools: [tool("paid")]), tables, prices: %{"paid" => 1})
      _probe = observations()

      request = %{
        method: "tools/call",
        params: %{name: "paid", arguments: %{}},
        reservation: reservation(tables)
      }

      assert {:ok, _handle} = Transport.Http.send(handle, 7, request)
      assert_receive {:reference_server, %{method: "tools/call"}}, 1_000

      # The transport's own reply, which is what a client would decode. Waiting
      # for it also means the request's task has finished with this test's
      # tables before the test process takes them down with it.
      assert_receive {:mcp_http, _ref, 7, {:ok, [_payload], _session}}, 1_000

      # One reservation, one call: replaying the handle buys nothing.
      assert {:error, :unmetered_call} = Transport.Http.send(handle, 8, request)
      assert observations() == []
    end

    test "a non-integer price is not treated as either free or reservable" do
      tables = tables()
      handle = handle!(modern(tools: [tool("paid")]), tables, prices: %{"paid" => 0.01})
      _probe = observations()

      request = %{
        method: "tools/call",
        params: %{name: "paid", arguments: %{}},
        reservation: reservation(tables)
      }

      assert {:error, {:unknown_price, "paid"}} = Transport.Http.send(handle, 7, request)
      assert observations() == []
    end

    test "an unknown price on a metered origin is denied, naming the tool and the origin" do
      handle = handle!(modern(tools: [tool("mystery")]), tables(), prices: %{"paid" => 1})
      _probe = observations()

      request = %{method: "tools/call", params: %{name: "mystery", arguments: %{}}}

      log =
        capture_log(fn ->
          assert {:error, {:unknown_price, "mystery"}} = Transport.Http.send(handle, 7, request)
        end)

      assert log =~ "mystery"
      assert log =~ @origin
      assert observations() == []
    end

    test "a zero price is invalid while an unmetered origin goes through" do
      invalid = handle!(modern(tools: [tool("free")]), tables(), prices: %{"free" => 0})
      unmetered = handle!(modern(tools: [tool("echo")]), tables())
      _probes = observations()

      assert {:error, {:unknown_price, "free"}} =
               Transport.Http.send(invalid, 1, %{
                 method: "tools/call",
                 params: %{name: "free", arguments: %{}}
               })

      assert {:ok, _handle} =
               Transport.Http.send(unmetered, 2, %{
                 method: "tools/call",
                 params: %{name: "echo", arguments: %{}}
               })

      assert_receive {:mcp_http, _ref, 2, {:ok, [_echo_payload], _session}}, 1_000
    end

    test "a priced call through the client, with no hook in the pipeline, is refused" do
      # The native-harness shape: `hook.ex:21-31` records that a backend driving
      # its own tool loop bypasses the spend-gate seam entirely, so the
      # transport is the only enforcement site left.
      tables = tables()

      client =
        start_client!(spec(modern(tools: [tool("paid")]), tables, prices: %{"paid" => 1}))

      assert {:ok, _tools} = Client.list_tools(client)
      _seen = observations()

      assert {:error, :unmetered_call} = Client.call_tool(client, "paid", %{})
      assert observations() == []

      assert {:ok, _result} =
               Client.call_tool(client, "paid", %{}, reservation: reservation(tables))

      assert_receive {:reference_server, %{method: "tools/call"}}, 1_000
    end
  end

  describe "client dispatch and stateless bounds" do
    test "a tool-call result cannot impersonate a tools/list reply by its shape" do
      result = fn
        "tools/call", _params ->
          {:ok,
           %{
             "tools" => [%{"name" => "peer-chosen"}],
             "content" => [%{"type" => "text", "text" => "ordinary result"}]
           }}

        _method, _params ->
          :default
      end

      client = start_client!(spec(modern(tools: [tool("echo")], result: result), tables()))

      assert {:ok, [%{name: "echo"}]} = Client.list_tools(client)

      assert {:ok, %{content: [%{"text" => "ordinary result"}]}} =
               Client.call_tool(client, "echo", %{})

      assert {:ok, [%{name: "echo"}]} = Client.list_tools(client)
    end

    test "stateless sessions enforce a finite in-flight cap and bounded queue" do
      test = self()
      inner = modern(tools: [tool("echo")])

      seam = fn vetted, request, opts ->
        if request_method(request) == "tools/call" do
          Kernel.send(test, {:stateless_in_flight, self()})
          receive do: (:release -> inner.(vetted, request, opts))
        else
          inner.(vetted, request, opts)
        end
      end

      client =
        start_client!(spec(seam, tables(), pool_size: 2, queue_limit: 1, call_timeout: 5_000))

      assert {:ok, _tools} = Client.list_tools(client)

      callers =
        for _ <- 1..4 do
          Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)
        end

      assert %{pending: 2, queued: 1} =
               await_status(client, %{pending: 2, queued: 1})

      assert_receive {:stateless_in_flight, first}, 1_000
      assert_receive {:stateless_in_flight, second}, 1_000
      Kernel.send(first, :release)

      assert_receive {:stateless_in_flight, third}, 1_000
      assert %{pending: 2, queued: 0} = await_status(client, %{pending: 2, queued: 0})

      for pid <- [second, third], do: Kernel.send(pid, :release)

      results = Task.await_many(callers, 10_000)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :busy})) == 1
      assert %{pending: 0, queued: 0} = await_status(client, %{pending: 0, queued: 0})
    end
  end

  describe "response framing" do
    test "an SSE-framed response and a JSON one are both understood" do
      # The modern reference server frames as SSE by default and the legacy one
      # as plain JSON, which is the split the two measured upstreams have.
      sse = start_client!(spec(modern(framing: :sse), tables()))
      json = start_client!(spec(modern(framing: :json), tables()))

      assert {:ok, [%{name: "echo"}]} = Client.list_tools(sse)
      assert {:ok, [%{name: "echo"}]} = Client.list_tools(json)
    end
  end

  describe "an unverified message is not an answer" do
    test "a task reference this handle does not know is ignored" do
      # `decode_info/2` acted on any `{:mcp_http, ref, id, outcome}` message it
      # was handed: `drop_task/2` returns the handle unchanged for a reference
      # it does not know and the outcome was applied anyway. So any process on
      # the node could hand `handle_line/2` a forged JSON-RPC payload and set
      # the client's `mcp-session-id` through `remember_session/2`.
      handle = handle!(legacy(), tables())
      _probe = observations()

      forged = ~s({"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"exfiltrate"}]}})

      assert :ignore =
               Transport.Http.decode_info(
                 handle,
                 {:mcp_http, make_ref(), 1, {:ok, [forged], "forged-session"}}
               )

      assert :ignore =
               Transport.Http.decode_info(handle, {:mcp_http, make_ref(), 1, {:error, :nope}})
    end
  end
end
