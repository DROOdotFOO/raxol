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
    %{
      eras: :ets.new(:eras, [:set, :public]),
      breakers: CircuitBreaker.new(:breakers),
      reservations: Raxol.MCP.Client.Reservation.new(:reservations)
    }
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

  # Readiness is an event the client answers; polling for it in a sleep loop
  # can only observe a state it has already left. The handshake is not over
  # at `:ready` either -- `notifications/initialized` is a POST, and it holds
  # the single in-flight slot a serialized session has -- so the settle is
  # part of the wait.
  defp await_ready(client) do
    assert {:ok, _ready} = Client.await_ready(client, 5_000)
    await_drained(client)
  end

  defp await_drained(client, tries \\ 200) do
    case Client.status(client) do
      %{pending: 0, queued: 0} = status -> status
      %{} when tries > 0 -> Process.sleep(5) && await_drained(client, tries - 1)
      status -> flunk("in-flight state never drained: #{inspect(status)}")
    end
  end

  # Blocks until the client's own in-flight bookkeeping reaches `expected`.
  # That state is what the concurrency policy decides, so it is what the cap
  # is asserted against: a wall-clock window instead is a false pass on a
  # loaded runner.
  defp await_status(client, expected, tries \\ 200) do
    status = Client.status(client)
    reached = Map.take(status, Keyword.keys(expected))

    cond do
      reached == Map.new(expected) ->
        status

      tries > 0 ->
        Process.sleep(5) && await_status(client, expected, tries - 1)

      true ->
        flunk("in-flight state settled at #{inspect(reached)}, wanted #{inspect(expected)}")
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

      # The gate holds every dispatched request, so the fan-out settles into a
      # state that can be read: one on the wire, two queued, one refused.
      await_status(client, pending: 1, queued: 2)

      for queued <- [2, 1, 0] do
        assert_receive {:in_flight, pid}, 2_000

        # The cap is one, so while this request is held the rest are queued
        # rather than on the wire. Read off the policy's own bookkeeping
        # instead of a `refute_receive` window: a loaded runner turns a window
        # into a false pass, and `Client.status/1` is a call, so it is ordered
        # behind the dispatch that admitted this request.
        assert %{pending: 1, queued: ^queued} = Client.status(client)

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

      # Every dispatched exchange was stopped with its entry, so nothing is
      # left blocked on the gate to wake at its own deadline and touch this
      # test's ETS tables afterwards. This test used to kill them by hand,
      # which hid the fact that the client was leaving them running.
      for pid <- gated(), do: refute(Process.alive?(pid))
    end

    test "an expired request's exchange is stopped, not left on the wire" do
      # The entry left `pending` on expiry while its transport task kept
      # running, and `capacity?/1` then admitted the next queued request
      # beside it: two concurrent requests on a session whose cap is one.
      # Reachable with defaults, because one exchange's wall time -- the dial
      # plus the read deadline plus a chunk overshoot -- can exceed
      # `call_timeout`. The caller being answered is therefore not enough;
      # the work has to be gone.
      client =
        start_client!(gated_seam(self()),
          concurrency: :serialized,
          queue_limit: 2,
          call_timeout: 100
        )

      release_handshake()
      await_ready(client)

      caller = Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)

      assert_receive {:in_flight, exchange}, 2_000
      ref = Process.monitor(exchange)

      assert Task.await(caller, 10_000) == {:error, :timeout}
      assert_receive {:DOWN, ^ref, :process, ^exchange, :killed}, 2_000
      assert %{pending: 0, queued: 0} = Client.status(client)
    end

    defp gated(pids \\ []) do
      receive do
        {:in_flight, pid} -> gated([pid | pids])
      after
        0 -> pids
      end
    end
  end

  property "a serialized origin neither over-dispatches nor leaks" do
    check all(
            callers <- integer(1..8),
            limit <- integer(1..3),
            max_runs: 12
          ) do
      client = start_client!(gated_seam(self()), concurrency: :serialized, queue_limit: limit)
      release_handshake()
      await_ready(client)

      tasks =
        for _ <- 1..callers do
          Task.async(fn -> Client.call_tool(client, "echo", %{}, timeout: 10_000) end)
        end

      # One in flight, the rest of the admitted set queued, the excess refused.
      admitted = min(callers, limit + 1)
      await_status(client, pending: 1, queued: admitted - 1)

      # The cap holds at every step, read off the policy's own bookkeeping
      # while the gate holds each request. The counting seam this replaces
      # widened the exchange with `Process.sleep(2)` to make an overlap likely,
      # which made its reading depend on the runner's load in both directions:
      # a fan-out dispatched two-at-once passed it whenever the first exchange
      # finished before the second was scheduled.
      for queued <- (admitted - 1)..0//-1 do
        assert_receive {:in_flight, pid}, 2_000
        assert %{pending: 1, queued: ^queued} = Client.status(client)
        Kernel.send(pid, :release)
      end

      results = Task.await_many(tasks, 10_000)

      # Every caller got an answer, and only the ones the policy admits ran.
      assert Enum.count(results, &match?({:ok, _result}, &1)) == admitted
      assert Enum.count(results, &(&1 == {:error, :busy})) == callers - admitted
      assert length(results) == callers

      await_drained(client)
      stop_quietly(client)
    end
  end
end
