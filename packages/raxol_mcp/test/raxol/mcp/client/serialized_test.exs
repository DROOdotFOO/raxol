defmodule Raxol.MCP.Client.SerializedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.ReferenceServer
  alias Raxol.MCP.Client.ReferenceServer.Legacy

  # ADR-0037 validation item 8: a concurrent fan-out over one `:serialized`
  # session issues exactly one request at a time, the excess beyond the queue
  # bound is `{:error, :busy}`, and `pending` is empty once the fan-out settles,
  # including for the requests that timed out.
  #
  # Property-tested because the upstream failure this models is invisible to a
  # single-call test: TronScan answers 500 to BOTH of two parallel calls on one
  # session, reproducibly, and every call in isolation succeeds
  # (`docs/proposals/web3-upstream-survey.md:72-78`).

  @url "https://mcp.example.test/mcp"
  @public {93, 184, 216, 34}

  defp tables do
    %{eras: :ets.new(:eras, [:set, :public]), breakers: CircuitBreaker.new(:breakers)}
  end

  defp resolver do
    fn
      _host, :inet -> {:ok, [@public]}
      _host, :inet6 -> {:ok, []}
    end
  end

  defp legacy_seam do
    ReferenceServer.seam(Legacy, ReferenceServer.state(:legacy, observer: nil))
  end

  defp start_client!(exchange, extra) do
    spec =
      [
        name: :"serialized_#{System.unique_integer([:positive])}",
        url: @url,
        tables: tables(),
        resolver: resolver(),
        exchange: exchange
      ] ++ extra

    {:ok, client} = Client.start_link(spec)
    on_exit(fn -> stop_quietly(client) end)
    client
  end

  # An `on_exit` stop races the exit signal a linked client is already getting,
  # and the property stops its client explicitly between runs.
  defp stop_quietly(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end

  defp await_ready(client, tries \\ 200) do
    case Client.status(client) do
      %{status: :ready} = status -> status
      %{status: _other} when tries > 0 -> Process.sleep(5) && await_ready(client, tries - 1)
      %{status: other} -> flunk("client never became ready, stuck in #{inspect(other)}")
    end
  end

  defp await_drained(client, tries \\ 200) do
    case Client.status(client) do
      %{pending: 0, queued: 0} = status -> status
      %{} when tries > 0 -> Process.sleep(5) && await_drained(client, tries - 1)
      status -> flunk("in-flight state never drained: #{inspect(status)}")
    end
  end

  # A seam that blocks until the test releases it, which is what makes "exactly
  # one at a time" assertable rather than merely likely.
  defp gated_seam(test) do
    inner = legacy_seam()

    fn vetted, request, opts ->
      Kernel.send(test, {:in_flight, self()})

      receive do
        :release -> inner.(vetted, request, opts)
      after
        10_000 -> {:error, :gate_timeout}
      end
    end
  end

  defp release_next do
    assert_receive {:in_flight, pid}, 2_000
    Kernel.send(pid, :release)
    :ok
  end

  # The handshake is three requests: the era probe, `initialize`, and the
  # `notifications/initialized` that follows it.
  defp release_handshake do
    release_next()
    release_next()
    release_next()
  end

  describe "a gated fan-out" do
    test "issues one request at a time and refuses the excess beyond the queue bound" do
      client = start_client!(gated_seam(self()), concurrency: :serialized, queue_limit: 2)
      release_handshake()
      await_ready(client)

      # One in flight, two queued, one refused. Nothing can complete while the
      # gate is shut, so the arithmetic is not a race.
      callers =
        for _ <- 1..4 do
          Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)
        end

      for _ <- 1..3 do
        assert_receive {:in_flight, pid}, 2_000
        # The cap is one, so while this request is held nothing else may reach
        # the wire.
        refute_receive {:in_flight, _another}, 30
        Kernel.send(pid, :release)
      end

      results = Task.await_many(callers, 10_000)

      assert Enum.count(results, &match?({:ok, _result}, &1)) == 3
      assert Enum.count(results, &(&1 == {:error, :busy})) == 1
      assert %{pending: 0, queued: 0} = Client.status(client)
    end

    test "a queued request that never dispatches expires rather than hanging" do
      # The gate is never opened for the fan-out, so every admitted request
      # expires on its own timer. What must not happen is an entry left behind.
      client =
        start_client!(gated_seam(self()),
          concurrency: :serialized,
          queue_limit: 2,
          call_timeout: 150
        )

      release_handshake()
      await_ready(client)

      callers =
        for _ <- 1..3 do
          Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)
        end

      assert Task.await_many(callers, 10_000) == [
               {:error, :timeout},
               {:error, :timeout},
               {:error, :timeout}
             ]

      assert %{pending: 0, queued: 0} = Client.status(client)

      # The gate was never opened, so a still-blocked task would wake at its own
      # deadline and touch this test's ETS tables after the test process has
      # taken them down with it. Killed rather than released: there is nothing
      # left to observe.
      kill_gated()
    end

    defp kill_gated do
      receive do
        {:in_flight, pid} ->
          Process.exit(pid, :kill)
          kill_gated()
      after
        0 -> :ok
      end
    end
  end

  # Counts concurrent entries into the wire. `notifications/initialized` is
  # excluded: the in-flight cap governs requests that carry an id and can be
  # correlated back, and the one notification this client ever sends belongs to
  # the handshake, before any caller has been admitted.
  defp counting_seam(counters) do
    inner = legacy_seam()

    fn vetted, request, opts ->
      correlated? = not String.contains?(IO.iodata_to_binary(request.body), "notifications/")

      if correlated?, do: enter(counters)
      Process.sleep(2)
      result = inner.(vetted, request, opts)
      if correlated?, do: :atomics.sub(counters, 1, 1)
      result
    end
  end

  defp enter(counters) do
    in_flight = :atomics.add_get(counters, 1, 1)
    if in_flight > :atomics.get(counters, 2), do: :atomics.put(counters, 2, in_flight)
  end

  property "a serialized origin neither over-dispatches nor leaks" do
    check all(
            callers <- integer(1..8),
            limit <- integer(1..3),
            max_runs: 12
          ) do
      counters = :atomics.new(2, [])

      client =
        start_client!(counting_seam(counters), concurrency: :serialized, queue_limit: limit)

      await_ready(client)

      results =
        1..callers
        |> Enum.map(fn _ ->
          Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)
        end)
        |> Task.await_many(10_000)

      assert :atomics.get(counters, 2) == 1,
             "#{:atomics.get(counters, 2)} requests were in flight at once"

      # Every caller got an answer, and only the two the policy admits.
      assert Enum.all?(results, fn
               {:ok, _result} -> true
               {:error, :busy} -> true
               _other -> false
             end),
             "unexpected results: #{inspect(results)}"

      assert length(results) == callers
      await_drained(client)
      stop_quietly(client)
    end
  end
end
