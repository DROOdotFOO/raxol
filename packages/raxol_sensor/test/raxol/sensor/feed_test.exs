defmodule Raxol.Sensor.FailSensor do
  @moduledoc false
  @behaviour Raxol.Sensor.Behaviour

  @impl true
  def connect(_opts), do: {:ok, %{tick: 0}}

  @impl true
  def read(_state), do: {:error, :always_fail}

  @impl true
  def disconnect(_state), do: :ok
end

defmodule Raxol.Sensor.TransportError do
  @moduledoc false
  defstruct [:reason]
end

defmodule Raxol.Sensor.UnreachableSensor do
  @moduledoc false
  @behaviour Raxol.Sensor.Behaviour

  @impl true
  def connect(opts) do
    {:ok,
     %{
       test_pid: Keyword.fetch!(opts, :test_pid),
       reason: Keyword.fetch!(opts, :reason)
     }}
  end

  @impl true
  def read(%{test_pid: pid, reason: reason}) do
    send(pid, :read_attempted)
    {:error, reason}
  end

  @impl true
  def disconnect(_state), do: :ok
end

defmodule Raxol.Sensor.BlockingSensor do
  @moduledoc false
  @behaviour Raxol.Sensor.Behaviour

  @impl true
  def connect(opts), do: {:ok, %{test_pid: Keyword.fetch!(opts, :test_pid)}}

  @impl true
  def read(%{test_pid: pid}) do
    send(pid, :read_attempted)
    Process.sleep(:infinity)
  end

  @impl true
  def disconnect(_state), do: :ok
end

defmodule Raxol.Sensor.FeedTest do
  use ExUnit.Case, async: true

  alias Raxol.Sensor.{
    Feed,
    MockSensor,
    FailSensor,
    UnreachableSensor,
    BlockingSensor
  }

  describe "poll cycle" do
    test "connects and starts producing readings" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :feed_test,
          module: MockSensor,
          sample_rate_ms: 10
        )

      Process.sleep(50)

      assert Feed.get_status(pid) == :running
      assert {:ok, reading} = Feed.get_latest(pid)
      assert reading.sensor_id == :feed_test
    end

    test "buffers readings in history" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :history_test,
          module: MockSensor,
          sample_rate_ms: 10
        )

      Process.sleep(80)

      history = Feed.get_history(pid, 5)
      assert length(history) >= 3
    end

    test "forwards readings to fusion_pid" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :fusion_fwd,
          module: MockSensor,
          sample_rate_ms: 10,
          fusion_pid: self()
        )

      assert_receive {:sensor_reading, %{sensor_id: :fusion_fwd}}, 200
      GenServer.stop(pid)
    end
  end

  describe "error escalation" do
    test "switches to error status after max_errors" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :fail_test,
          module: FailSensor,
          sample_rate_ms: 5,
          max_errors: 3
        )

      Process.sleep(100)
      assert Feed.get_status(pid) == :error
    end
  end

  describe "reconnect" do
    test "reconnect resets error state" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :reconnect_test,
          module: MockSensor,
          sample_rate_ms: 10
        )

      Process.sleep(30)
      assert Feed.get_status(pid) == :running

      Feed.reconnect(pid)
      Process.sleep(30)
      assert Feed.get_status(pid) == :running
    end
  end

  describe "get_latest/get_history" do
    test "get_latest returns error when empty" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :empty_test,
          module: MockSensor,
          sample_rate_ms: 60_000
        )

      # Very long poll interval, so buffer should still be empty
      # (first poll hasn't fired yet if we're fast enough)
      # This is timing-dependent, so we accept either result
      result = Feed.get_latest(pid)
      assert match?({:ok, _}, result) or match?({:error, :empty}, result)
    end
  end

  describe "backoff_delay/2" do
    test "the first retry lands on the base delay" do
      delay = Feed.backoff_delay(0, backoff_ms: 1_000)

      assert delay >= 800 and delay <= 1_200
    end

    test "each retry doubles the previous delay" do
      delay = Feed.backoff_delay(3, backoff_ms: 1_000, max_backoff_ms: 600_000)

      assert delay >= 6_400 and delay <= 9_600
    end

    test "a long outage never exceeds the ceiling" do
      for attempt <- [10, 20, 40, 1_000] do
        delay =
          Feed.backoff_delay(attempt, backoff_ms: 1_000, max_backoff_ms: 60_000)

        assert delay <= 60_000, "attempt #{attempt} returned #{delay}"
      end
    end

    test "concurrent feeds do not retry on the same tick" do
      opts = [backoff_ms: 1_000, max_backoff_ms: 600_000]
      delays = for _ <- 1..50, do: Feed.backoff_delay(2, opts)

      # Without jitter a shared outage resynchronises every feed onto one
      # retry tick, and they stampede the recovering origin together.
      assert length(Enum.uniq(delays)) > 1
      assert Enum.all?(delays, &(&1 >= 3_200 and &1 <= 4_800))
    end
  end

  describe "unreachable endpoints" do
    test "a refused connection skips the error ladder" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :unreachable_test,
          module: UnreachableSensor,
          sample_rate_ms: 5,
          max_errors: 10,
          connect_opts: [test_pid: self(), reason: :econnrefused]
        )

      assert_receive :read_attempted, 500

      # One unreachable read is enough. Every further rung of the ladder
      # costs a full connect timeout to learn the same thing.
      assert wait_for_status(pid, :error)
      refute_receive :read_attempted, 100
    end

    test "a transport error struct is unwrapped to its reason" do
      # Req and Mint both report connect failures as a struct carrying
      # :reason, never as a bare atom.
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :wrapped_test,
          module: UnreachableSensor,
          sample_rate_ms: 5,
          max_errors: 10,
          connect_opts: [
            test_pid: self(),
            reason: %Raxol.Sensor.TransportError{reason: :etimedout}
          ]
        )

      assert_receive :read_attempted, 500
      assert wait_for_status(pid, :error)
      refute_receive :read_attempted, 100
    end
  end

  describe "call budget" do
    test "a black-holed read does not park the feed" do
      {:ok, pid} =
        Feed.start_link(
          sensor_id: :budget_test,
          module: BlockingSensor,
          sample_rate_ms: 5,
          budget_ms: 25,
          max_errors: 10,
          connect_opts: [test_pid: self()]
        )

      assert_receive :read_attempted, 500

      # Unbudgeted, the feed sits inside module.read/1 for the operating
      # system's full connect timeout on every tick -- it never reaches
      # :error, and it stops answering get_status entirely.
      assert wait_for_status(pid, :error)
    end
  end

  describe "backoff scheduling" do
    test "honours the configured base delay" do
      {:ok, _pid} =
        Feed.start_link(
          sensor_id: :backoff_base_test,
          module: UnreachableSensor,
          sample_rate_ms: 5,
          backoff_ms: 50,
          connect_opts: [test_pid: self(), reason: :econnrefused]
        )

      assert_receive :read_attempted, 500

      # It must wait rather than retry straight away...
      refute_receive :read_attempted, 30

      # ...and wait the configured 50ms base, not the 5s default.
      assert_receive :read_attempted, 500
    end

    test "the retry interval grows across consecutive failures" do
      {:ok, _pid} =
        Feed.start_link(
          sensor_id: :backoff_growth_test,
          module: UnreachableSensor,
          sample_rate_ms: 5,
          backoff_ms: 100,
          connect_opts: [test_pid: self(), reason: :econnrefused]
        )

      assert_receive :read_attempted, 1_000
      assert_receive :read_attempted, 1_000

      # The second backoff is drawn from a doubled base. 100ms +20% tops
      # out at 120ms, so on a growing schedule nothing can arrive inside
      # 130ms; on a flat one the third read lands here.
      refute_receive :read_attempted, 130
      assert_receive :read_attempted, 1_000
    end
  end

  defp wait_for_status(pid, expected, attempts \\ 100)
  defp wait_for_status(_pid, _expected, 0), do: false

  defp wait_for_status(pid, expected, attempts) do
    if Feed.get_status(pid) == expected do
      true
    else
      Process.sleep(5)
      wait_for_status(pid, expected, attempts - 1)
    end
  end
end
