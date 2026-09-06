defmodule Raxol.Agent.Test.InvariantSentinel do
  @moduledoc """
  Arms `Raxol.Agent.Telemetry.invariant_events/0` for the duration of each
  test and fails the test if one of them fired.

      defmodule MyTest do
        use ExUnit.Case, async: false
        use Raxol.Agent.Test.InvariantSentinel
      end

  An invariant event is one that can only fire if this library is wrong (see
  `Raxol.Agent.Telemetry`). Before this module existed, such an event was
  emitted, logged, and ignored -- which is how a turn that delivered zero
  content shipped while the library was warning about it on stderr. A guard
  that nothing asserts on is not a guard.

  ## Declaring an invariant on purpose

  A test that DELIBERATELY drives a bad path declares it:

      @tag expect_invariant: [[:raxol, :agent, :acp_turn_runner, :interrupt_failed]]

  A single event may be given unwrapped (`expect_invariant: [:raxol, :agent,
  :acp_turn_runner, :interrupt_failed]`). The declaration is an ASSERTION, not
  a mute button: such a test also fails when the event does NOT fire. That is
  the point -- it converts "this test happens to drive a bad path" into "this
  test pins the bad path". Declaring an event that `Raxol.Agent.Telemetry` does
  not classify as `:invariant` is itself a failure, so the tag cannot drift
  away from the registry.

  ## Only sound in `async: false` modules

  `:telemetry` handlers are global and run in the EMITTING process, so a
  handler cannot tell which concurrently-running test caused an event: an
  invariant fired by test A would be reported against test B. Every module that
  uses this sentinel MUST therefore be `async: false`. A few hundred
  milliseconds of serial runtime is worth a guard that cannot misattribute.

  Pid-ancestry filtering is deliberately NOT attempted: `$ancestors` does not
  survive the `Task.Supervisor` hops these sessions use, so it would silently
  drop the events most worth catching.

  ## How the events survive the test process

  The handler runs in whichever process emitted the event, and the verdict is
  rendered from `on_exit/1` (the only hook that runs after the test body),
  by which time the test process is already gone. Fired events are therefore
  parked in a public ETS table owned by one long-lived collector process, keyed
  by the per-test handler id, and dropped when the verdict is rendered.
  """

  @table :raxol_agent_invariant_sentinel
  @collector :raxol_agent_invariant_sentinel_collector

  defmacro __using__(_opts) do
    quote do
      setup context do
        unquote(__MODULE__).arm(context)
      end
    end
  end

  @doc """
  Attach a per-test handler for every invariant event and register the
  end-of-test verdict. Called by the `setup` that `__using__/1` injects.
  """
  @spec arm(map()) :: :ok
  def arm(context) do
    expected = expected_invariants(context)
    handler_id = {__MODULE__, System.unique_integer([:positive])}
    events = Raxol.Agent.Telemetry.invariant_events()

    ensure_collector()

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle/4,
        handler_id
      )

    ExUnit.Callbacks.on_exit(fn ->
      :telemetry.detach(handler_id)
      verdict(handler_id, expected)
    end)

    :ok
  end

  @doc false
  def handle(event, measurements, metadata, handler_id) do
    :ets.insert(@table, {handler_id, event, measurements, metadata})
    :ok
  end

  # -- verdict ----------------------------------------------------------------

  defp verdict(handler_id, expected) do
    fired = :ets.lookup(@table, handler_id)
    :ets.delete(@table, handler_id)

    fired_events = fired |> Enum.map(fn {_id, event, _m, _md} -> event end) |> Enum.uniq()

    unexpected = Enum.reject(fired, fn {_id, event, _m, _md} -> event in expected end)
    missing = expected -- fired_events

    cond do
      unexpected != [] -> ExUnit.Assertions.flunk(unexpected_message(unexpected))
      missing != [] -> ExUnit.Assertions.flunk(missing_message(missing, fired_events))
      true -> :ok
    end
  end

  defp unexpected_message(unexpected) do
    detail =
      unexpected
      |> Enum.map_join("\n\n", fn {_id, event, measurements, metadata} ->
        "    event:        #{inspect(event)}\n" <>
          "    measurements: #{inspect(measurements)}\n" <>
          "    metadata:     #{inspect(metadata, pretty: true, limit: 20)}"
      end)

    """
    An INVARIANT telemetry event fired during this test.

    #{detail}

    Raxol.Agent.Telemetry classifies these events as ones that can only fire
    if this library is wrong -- not a peer, not the filesystem, not the user.
    Fix the code path, or, if this test drives the bad path deliberately,
    declare it so the test PINS that path:

        @tag expect_invariant: #{inspect(Enum.map(unexpected, fn {_id, e, _m, _md} -> e end) |> Enum.uniq())}
    """
  end

  defp missing_message(missing, fired_events) do
    """
    This test declares `@tag expect_invariant:` for events that never fired:

        #{inspect(missing)}

    Fired during this test: #{inspect(fired_events)}

    An expectation is an assertion, not a mute button: the tag says "this test
    drives that bad path on purpose", so the test must fail when the path stops
    being driven. Either the code stopped emitting the event (the tag is now
    stale and should be dropped) or the test no longer reaches it.
    """
  end

  # -- tag parsing ------------------------------------------------------------

  defp expected_invariants(context) do
    context
    |> Map.get(:expect_invariant)
    |> normalize_expected()
    |> tap(&assert_classified/1)
  end

  defp normalize_expected(nil), do: []
  defp normalize_expected([head | _] = event) when is_atom(head), do: [event]

  defp normalize_expected(events) when is_list(events) do
    Enum.map(events, fn
      event when is_list(event) ->
        event

      other ->
        ExUnit.Assertions.flunk(
          "expect_invariant must be a telemetry event (a list of atoms) or a " <>
            "list of them; got #{inspect(other)}"
        )
    end)
  end

  defp normalize_expected(other) do
    ExUnit.Assertions.flunk(
      "expect_invariant must be a telemetry event (a list of atoms) or a " <>
        "list of them; got #{inspect(other)}"
    )
  end

  # A tag naming a non-invariant event would be silently inert, so it is an
  # error: the tag must not be able to drift away from the registry.
  defp assert_classified(events) do
    classified = Raxol.Agent.Telemetry.invariant_events()

    case Enum.reject(events, &(&1 in classified)) do
      [] ->
        :ok

      bogus ->
        ExUnit.Assertions.flunk("""
        expect_invariant names #{inspect(bogus)}, which Raxol.Agent.Telemetry
        does not classify as :invariant. The sentinel only arms invariants, so
        this tag can never be satisfied. Either classify the event as
        :invariant in Raxol.Agent.Telemetry or drop the tag.
        """)
    end
  end

  # -- collector --------------------------------------------------------------

  # One process for the whole run, owning the public table. It holds no state
  # of its own: it exists only so the table outlives every test process.
  defp ensure_collector do
    case Process.whereis(@collector) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        ref = make_ref()
        parent = self()
        spawn(fn -> boot_collector(parent, ref) end)

        receive do
          {^ref, :ready} -> :ok
        after
          5_000 ->
            ExUnit.Assertions.flunk(
              "invariant sentinel collector did not start; the sentinel " <>
                "cannot observe events without it"
            )
        end
    end
  end

  defp boot_collector(parent, ref) do
    owner? =
      try do
        :ets.new(@table, [:named_table, :public, :duplicate_bag])
        Process.register(self(), @collector)
        true
      rescue
        # Lost a startup race with another arming test. Fine: the winner owns
        # the table, and this process has nothing to do.
        ArgumentError -> false
      end

    send(parent, {ref, :ready})
    if owner?, do: Process.sleep(:infinity), else: :ok
  end
end
