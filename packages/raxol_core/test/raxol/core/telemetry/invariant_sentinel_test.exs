defmodule Raxol.Core.Telemetry.SentinelFixtureRegistry do
  @moduledoc false
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      [:raxol, :core, :sentinel_fixture, :impossible] => :invariant,
      [:raxol, :core, :sentinel_fixture, :normal] => :operational
    }
end

defmodule Raxol.Core.Telemetry.InvariantSentinelTest do
  @moduledoc """
  Exercises the sentinel's failure paths directly.

  The verdict is rendered from `on_exit/1`, where a flunk simply fails the
  test, so the failure paths cannot be observed from a test that uses the
  sentinel: this module drives `attach/2` and `verdict/3` -- the same halves
  `arm/2` composes -- and asserts on the messages. The passing direction is
  covered end-to-end by `Raxol.Core.Telemetry.InvariantSentinelArmedTest`
  below, whose `@tag expect_invariant:` test fails if the handler never sees
  the event.

  `async: false` because `:telemetry` handlers are global and run in the
  emitting process: an event emitted here must not be attributed to a
  concurrently running test.
  """

  use ExUnit.Case, async: false

  alias Raxol.Core.Telemetry.InvariantSentinel, as: Sentinel
  alias Raxol.Core.Telemetry.SentinelFixtureRegistry, as: Registry

  @invariant [:raxol, :core, :sentinel_fixture, :impossible]
  @operational [:raxol, :core, :sentinel_fixture, :normal]

  setup do
    handler = {__MODULE__, System.unique_integer([:positive])}
    Sentinel.attach(handler, Registry)
    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, handler: handler}
  end

  test "an undeclared invariant event fails the test, naming event and metadata", ctx do
    :telemetry.execute(@invariant, %{count: 1}, %{reason: :fixture_drove_it})

    error =
      assert_raise ExUnit.AssertionError, fn -> Sentinel.verdict(ctx.handler, [], Registry) end

    assert error.message =~ "An INVARIANT telemetry event fired during this test."
    assert error.message =~ inspect(@invariant)
    assert error.message =~ "measurements: %{count: 1}"
    assert error.message =~ "reason: :fixture_drove_it"
    assert error.message =~ "Raxol.Core.Telemetry.SentinelFixtureRegistry classifies"
    assert error.message =~ "@tag expect_invariant: [#{inspect(@invariant)}]"
  end

  test "the same event passes once it is declared via expect_invariant", ctx do
    :telemetry.execute(@invariant, %{}, %{})

    assert Sentinel.verdict(ctx.handler, [@invariant], Registry) == :ok
  end

  test "a declared event that never fires fails, so the tag cannot be a mute button", ctx do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Sentinel.verdict(ctx.handler, [@invariant], Registry)
      end

    assert error.message =~ "declares `@tag expect_invariant:` for events that never fired"
    assert error.message =~ inspect([@invariant])
    assert error.message =~ "not a mute button"
  end

  test "a non-invariant event is not armed and does not fail the test", ctx do
    :telemetry.execute(@operational, %{}, %{})

    assert Sentinel.verdict(ctx.handler, [], Registry) == :ok
  end

  test "the verdict only sees its own handler's events", ctx do
    other = {__MODULE__, System.unique_integer([:positive])}
    Sentinel.attach(other, Registry)
    :telemetry.execute(@invariant, %{}, %{})
    :telemetry.detach(other)

    # Both handlers were attached, so both parked the event; each verdict must
    # consume only its own row.
    assert_raise ExUnit.AssertionError, fn -> Sentinel.verdict(other, [], Registry) end
    assert_raise ExUnit.AssertionError, fn -> Sentinel.verdict(ctx.handler, [], Registry) end
  end

  test "a tag naming an event the registry does not classify :invariant is an error" do
    error =
      assert_raise ExUnit.AssertionError, fn ->
        Sentinel.arm(%{expect_invariant: @operational}, Registry)
      end

    assert error.message =~ "expect_invariant names [#{inspect(@operational)}]"
    assert error.message =~ "does not classify as :invariant"
  end

  test "a tag that is not an event name is an error" do
    assert_raise ExUnit.AssertionError, ~r/must be a telemetry event/, fn ->
      Sentinel.arm(%{expect_invariant: "raxol.core.sentinel_fixture.impossible"}, Registry)
    end
  end

  test "a registry module without invariant_events/0 is an error" do
    assert_raise ExUnit.AssertionError, ~r/is not a telemetry invariant registry/, fn ->
      Sentinel.arm(%{}, Enum)
    end
  end
end

defmodule Raxol.Core.Telemetry.InvariantSentinelArmedTest do
  @moduledoc """
  The end-to-end proof: these tests run with the sentinel armed by the `setup`
  that `use` injects, so the verdict really is rendered from `on_exit/1`.

  `async: false` is mandatory for any module using the sentinel: `:telemetry`
  handlers are global and run in the emitting process, so a handler cannot
  attribute an event to one of several concurrently running async tests.
  """

  use ExUnit.Case, async: false

  use Raxol.Core.Telemetry.InvariantSentinel,
    registry: Raxol.Core.Telemetry.SentinelFixtureRegistry

  alias Raxol.Core.Telemetry.SentinelFixtureRegistry, as: Registry

  test "an operational event does not trip the armed sentinel" do
    :telemetry.execute([:raxol, :core, :sentinel_fixture, :normal], %{}, %{})

    assert Registry.classification([:raxol, :core, :sentinel_fixture, :normal]) == :operational
  end

  @tag expect_invariant: [:raxol, :core, :sentinel_fixture, :impossible]
  test "a declared invariant that fires satisfies the tag" do
    # No assertion here on purpose: the sentinel's on_exit verdict IS the
    # assertion, in both directions. If the handler never saw this event, this
    # test fails with the "never fired" message.
    :telemetry.execute([:raxol, :core, :sentinel_fixture, :impossible], %{}, %{ok: true})
  end
end
