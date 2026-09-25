defmodule Raxol.Core.Utils.GenServerHelpersTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Utils.GenServerHelpers

  # ------------------------------------------------------------------
  # handle_get_state/1
  # ------------------------------------------------------------------

  describe "handle_get_state/1" do
    test "returns the state as reply and preserves it" do
      state = %{foo: 1, bar: 2}
      assert {:reply, ^state, ^state} = GenServerHelpers.handle_get_state(state)
    end

    test "works with an empty map" do
      assert {:reply, %{}, %{}} = GenServerHelpers.handle_get_state(%{})
    end

    test "works with non-map state" do
      assert {:reply, :atom, :atom} = GenServerHelpers.handle_get_state(:atom)
      assert {:reply, 42, 42} = GenServerHelpers.handle_get_state(42)
      assert {:reply, nil, nil} = GenServerHelpers.handle_get_state(nil)
    end
  end

  # ------------------------------------------------------------------
  # handle_get_field/2
  # ------------------------------------------------------------------

  describe "handle_get_field/2" do
    test "returns the value for an existing key" do
      state = %{name: "raxol", version: 1}
      assert {:reply, "raxol", ^state} = GenServerHelpers.handle_get_field(:name, state)
    end

    test "returns nil for a missing key in a map" do
      state = %{name: "raxol"}
      assert {:reply, nil, ^state} = GenServerHelpers.handle_get_field(:missing, state)
    end

    test "returns nil for non-map state" do
      assert {:reply, nil, :not_a_map} = GenServerHelpers.handle_get_field(:key, :not_a_map)
      assert {:reply, nil, 42} = GenServerHelpers.handle_get_field(:key, 42)
    end

    test "handles string keys" do
      state = %{"string_key" => "value"}
      assert {:reply, "value", ^state} = GenServerHelpers.handle_get_field("string_key", state)
    end

    test "preserves original state unchanged" do
      state = %{a: 1, b: 2}
      {:reply, _value, returned_state} = GenServerHelpers.handle_get_field(:a, state)
      assert returned_state === state
    end
  end

  # ------------------------------------------------------------------
  # handle_get_metrics/1
  # ------------------------------------------------------------------

  describe "handle_get_metrics/1" do
    test "returns metrics from state" do
      metrics = %{requests: 10, errors: 2}
      state = %{metrics: metrics}
      assert {:reply, ^metrics, ^state} = GenServerHelpers.handle_get_metrics(state)
    end

    test "returns empty map when no metrics key exists" do
      state = %{other: :data}
      assert {:reply, %{}, ^state} = GenServerHelpers.handle_get_metrics(state)
    end

    test "returns empty map for non-map state" do
      assert {:reply, %{}, :atom} = GenServerHelpers.handle_get_metrics(:atom)
    end

    test "preserves original state" do
      state = %{metrics: %{count: 5}}
      {:reply, _metrics, returned_state} = GenServerHelpers.handle_get_metrics(state)
      assert returned_state === state
    end
  end

  # ------------------------------------------------------------------
  # handle_get_status/1
  # ------------------------------------------------------------------

  describe "handle_get_status/1" do
    test "returns status map with status, uptime, and metrics" do
      state = %{
        status: :running,
        start_time: System.monotonic_time(:millisecond) - 1000,
        metrics: %{requests: 5}
      }

      {:reply, status, ^state} = GenServerHelpers.handle_get_status(state)

      assert status.status == :running
      assert status.metrics == %{requests: 5}
      assert is_integer(status.uptime)
      assert status.uptime >= 1000
    end

    test "defaults status to :running when not present" do
      state = %{start_time: System.monotonic_time(:millisecond)}
      {:reply, status, _state} = GenServerHelpers.handle_get_status(state)
      assert status.status == :running
    end

    test "defaults metrics to empty map when not present" do
      state = %{start_time: System.monotonic_time(:millisecond)}
      {:reply, status, _state} = GenServerHelpers.handle_get_status(state)
      assert status.metrics == %{}
    end

    test "uptime is non-negative when start_time is recent" do
      state = %{start_time: System.monotonic_time(:millisecond)}
      {:reply, status, _state} = GenServerHelpers.handle_get_status(state)
      assert status.uptime >= 0
    end

    test "returns unknown status for non-map state" do
      assert {:reply, %{status: :unknown}, :atom} =
               GenServerHelpers.handle_get_status(:atom)
    end

    test "preserves custom status values" do
      state = %{status: :paused, start_time: System.monotonic_time(:millisecond)}
      {:reply, status, _state} = GenServerHelpers.handle_get_status(state)
      assert status.status == :paused
    end
  end

  # ------------------------------------------------------------------
  # handle_update_config/2
  # ------------------------------------------------------------------

  describe "handle_update_config/2" do
    test "merges new config into existing config" do
      state = %{config: %{timeout: 5000}}
      new_config = %{retries: 3}

      assert {:reply, :ok, new_state} =
               GenServerHelpers.handle_update_config(new_config, state)

      assert new_state.config == %{timeout: 5000, retries: 3}
    end

    test "overwrites existing config keys" do
      state = %{config: %{timeout: 5000, retries: 1}}
      new_config = %{retries: 10}

      {:reply, :ok, new_state} =
        GenServerHelpers.handle_update_config(new_config, state)

      assert new_state.config == %{timeout: 5000, retries: 10}
    end

    test "creates config key when not present in state" do
      state = %{other: :data}
      new_config = %{timeout: 3000}

      {:reply, :ok, new_state} =
        GenServerHelpers.handle_update_config(new_config, state)

      assert new_state.config == %{timeout: 3000}
    end

    test "preserves other state keys" do
      state = %{config: %{}, metrics: %{count: 1}, status: :running}
      new_config = %{debug: true}

      {:reply, :ok, new_state} =
        GenServerHelpers.handle_update_config(new_config, state)

      assert new_state.metrics == %{count: 1}
      assert new_state.status == :running
    end

    test "returns error for non-map new_config" do
      state = %{config: %{}}

      assert {:reply, {:error, :invalid_config}, ^state} =
               GenServerHelpers.handle_update_config(:bad, state)
    end

    test "returns error for non-map state" do
      assert {:reply, {:error, :invalid_config}, :atom} =
               GenServerHelpers.handle_update_config(%{key: :val}, :atom)
    end

    test "handles empty new_config" do
      state = %{config: %{timeout: 5000}}

      {:reply, :ok, new_state} =
        GenServerHelpers.handle_update_config(%{}, state)

      assert new_state.config == %{timeout: 5000}
    end
  end

  # ------------------------------------------------------------------
  # handle_reset_metrics/1
  # ------------------------------------------------------------------

  describe "handle_reset_metrics/1" do
    test "clears metrics to empty map" do
      state = %{metrics: %{requests: 100, errors: 5}}

      assert {:reply, :ok, new_state} = GenServerHelpers.handle_reset_metrics(state)
      assert new_state.metrics == %{}
    end

    test "preserves other state keys" do
      state = %{metrics: %{count: 1}, config: %{debug: true}, status: :running}

      {:reply, :ok, new_state} = GenServerHelpers.handle_reset_metrics(state)

      assert new_state.config == %{debug: true}
      assert new_state.status == :running
    end

    test "is idempotent on already-empty metrics" do
      state = %{metrics: %{}}

      {:reply, :ok, new_state} = GenServerHelpers.handle_reset_metrics(state)
      assert new_state.metrics == %{}
    end

    test "returns :ok for non-map state without modification" do
      assert {:reply, :ok, :atom} = GenServerHelpers.handle_reset_metrics(:atom)
    end

    test "adds metrics key if not present" do
      state = %{status: :running}

      {:reply, :ok, new_state} = GenServerHelpers.handle_reset_metrics(state)
      assert new_state.metrics == %{}
    end
  end

  # ------------------------------------------------------------------
  # increment_metric/3
  # ------------------------------------------------------------------

  describe "increment_metric/3" do
    test "creates a new metric with default amount of 1" do
      state = %{metrics: %{}}
      new_state = GenServerHelpers.increment_metric(state, :requests)
      assert new_state.metrics.requests == 1
    end

    test "creates a new metric with specified amount" do
      state = %{metrics: %{}}
      new_state = GenServerHelpers.increment_metric(state, :requests, 5)
      assert new_state.metrics.requests == 5
    end

    test "increments an existing metric by default amount" do
      state = %{metrics: %{requests: 10}}
      new_state = GenServerHelpers.increment_metric(state, :requests)
      assert new_state.metrics.requests == 11
    end

    test "increments an existing metric by specified amount" do
      state = %{metrics: %{requests: 10}}
      new_state = GenServerHelpers.increment_metric(state, :requests, 5)
      assert new_state.metrics.requests == 15
    end

    test "initializes metrics map when not present" do
      state = %{status: :running}
      new_state = GenServerHelpers.increment_metric(state, :calls)
      assert new_state.metrics.calls == 1
    end

    test "preserves other metrics" do
      state = %{metrics: %{errors: 3, warnings: 7}}
      new_state = GenServerHelpers.increment_metric(state, :errors, 2)
      assert new_state.metrics.errors == 5
      assert new_state.metrics.warnings == 7
    end

    test "handles negative increment" do
      state = %{metrics: %{balance: 100}}
      new_state = GenServerHelpers.increment_metric(state, :balance, -25)
      assert new_state.metrics.balance == 75
    end

    test "handles zero increment" do
      state = %{metrics: %{count: 42}}
      new_state = GenServerHelpers.increment_metric(state, :count, 0)
      assert new_state.metrics.count == 42
    end

    test "returns non-map state unchanged" do
      assert :atom == GenServerHelpers.increment_metric(:atom, :requests, 1)
      assert 42 == GenServerHelpers.increment_metric(42, :requests, 1)
    end

    test "preserves other state keys" do
      state = %{metrics: %{}, config: %{debug: true}}
      new_state = GenServerHelpers.increment_metric(state, :ops)
      assert new_state.config == %{debug: true}
    end
  end

  # ------------------------------------------------------------------
  # update_metric/3
  # ------------------------------------------------------------------

  describe "update_metric/3" do
    test "sets a new metric value" do
      state = %{metrics: %{}}
      new_state = GenServerHelpers.update_metric(state, :latency, 42)
      assert new_state.metrics.latency == 42
    end

    test "overwrites an existing metric value" do
      state = %{metrics: %{latency: 42}}
      new_state = GenServerHelpers.update_metric(state, :latency, 99)
      assert new_state.metrics.latency == 99
    end

    test "initializes metrics map when not present" do
      state = %{status: :running}
      new_state = GenServerHelpers.update_metric(state, :latency, 10)
      assert new_state.metrics.latency == 10
    end

    test "preserves other metrics" do
      state = %{metrics: %{requests: 10, errors: 2}}
      new_state = GenServerHelpers.update_metric(state, :errors, 0)
      assert new_state.metrics.errors == 0
      assert new_state.metrics.requests == 10
    end

    test "accepts any value type" do
      state = %{metrics: %{}}

      new_state = GenServerHelpers.update_metric(state, :last_error, "timeout")
      assert new_state.metrics.last_error == "timeout"

      new_state = GenServerHelpers.update_metric(state, :active, true)
      assert new_state.metrics.active == true

      new_state = GenServerHelpers.update_metric(state, :tags, [:a, :b])
      assert new_state.metrics.tags == [:a, :b]
    end

    test "returns non-map state unchanged" do
      assert :atom == GenServerHelpers.update_metric(:atom, :key, :value)
    end

    test "preserves other state keys" do
      state = %{metrics: %{}, config: %{a: 1}, status: :running}
      new_state = GenServerHelpers.update_metric(state, :count, 5)
      assert new_state.config == %{a: 1}
      assert new_state.status == :running
    end
  end

  # ------------------------------------------------------------------
  # init_default_state/1
  # ------------------------------------------------------------------

  describe "init_default_state/1" do
    test "creates state with default fields" do
      state = GenServerHelpers.init_default_state()

      assert state.status == :running
      assert is_integer(state.start_time)
      assert state.metrics == %{}
      assert state.config == %{}
    end

    test "merges custom state over defaults" do
      custom = %{status: :paused, custom_field: :hello}
      state = GenServerHelpers.init_default_state(custom)

      assert state.status == :paused
      assert state.custom_field == :hello
      assert is_integer(state.start_time)
      assert state.metrics == %{}
      assert state.config == %{}
    end

    test "custom state can override all defaults" do
      custom = %{
        status: :stopped,
        start_time: 0,
        metrics: %{preloaded: true},
        config: %{debug: true}
      }

      state = GenServerHelpers.init_default_state(custom)

      assert state.status == :stopped
      assert state.start_time == 0
      assert state.metrics == %{preloaded: true}
      assert state.config == %{debug: true}
    end

    test "start_time is close to current monotonic time" do
      before = System.monotonic_time(:millisecond)
      state = GenServerHelpers.init_default_state()
      after_time = System.monotonic_time(:millisecond)

      assert state.start_time >= before
      assert state.start_time <= after_time
    end

    test "empty map produces same result as no argument" do
      state = GenServerHelpers.init_default_state(%{})

      assert state.status == :running
      assert state.metrics == %{}
      assert state.config == %{}
    end
  end

  # ------------------------------------------------------------------
  # ensure_started/2
  # ------------------------------------------------------------------

  describe "ensure_started/2" do
    setup do
      name = :"genserver_helpers_test_#{System.unique_integer([:positive])}"

      on_exit(fn ->
        try do
          Agent.stop(name)
        catch
          :exit, _ -> :ok
        end
      end)

      %{name: name}
    end

    test "a server started by a concurrent caller counts as started", %{
      name: name
    } do
      start = fn -> Agent.start(fn -> :first end, name: name) end

      # Another caller registers the name after the `whereis` check but
      # before this caller's own start runs.
      racing_start = fn ->
        {:ok, _winner} = start.()
        start.()
      end

      assert :ok = GenServerHelpers.ensure_started(name, racing_start)
      assert Agent.get(name, & &1) == :first
    end
  end

  # ------------------------------------------------------------------
  # Integration: round-trip workflows
  # ------------------------------------------------------------------

  describe "round-trip workflows" do
    test "init -> increment -> get_metrics" do
      state = GenServerHelpers.init_default_state()

      state =
        state
        |> GenServerHelpers.increment_metric(:requests)
        |> GenServerHelpers.increment_metric(:requests)
        |> GenServerHelpers.increment_metric(:errors)

      {:reply, metrics, _state} = GenServerHelpers.handle_get_metrics(state)
      assert metrics == %{requests: 2, errors: 1}
    end

    test "init -> update_config -> get_field" do
      state = GenServerHelpers.init_default_state()

      {:reply, :ok, state} =
        GenServerHelpers.handle_update_config(%{timeout: 5000}, state)

      {:reply, config, _state} = GenServerHelpers.handle_get_field(:config, state)
      assert config == %{timeout: 5000}
    end

    test "init -> increment -> reset -> get_metrics returns empty" do
      state = GenServerHelpers.init_default_state()

      state = GenServerHelpers.increment_metric(state, :requests, 100)
      {:reply, :ok, state} = GenServerHelpers.handle_reset_metrics(state)
      {:reply, metrics, _state} = GenServerHelpers.handle_get_metrics(state)

      assert metrics == %{}
    end

    test "init -> update_metric -> get_status includes metric" do
      state = GenServerHelpers.init_default_state()
      state = GenServerHelpers.update_metric(state, :latency, 42)

      {:reply, status, _state} = GenServerHelpers.handle_get_status(state)

      assert status.status == :running
      assert status.metrics == %{latency: 42}
      assert status.uptime >= 0
    end
  end
end
