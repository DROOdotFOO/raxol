defmodule Raxol.Core.Telemetry.InvariantSentinel do
  @moduledoc """
  Arms a registry's `invariant_events/0` for the duration of each test and
  fails the test if one of them fired.

      defmodule Raxol.Payments.SettlementTest do
        use ExUnit.Case, async: false
        use Raxol.Core.Telemetry.InvariantSentinel, registry: Raxol.Payments.Telemetry
      end

  `registry:` is the only option and it is required: it names a module built
  with `use Raxol.Core.Telemetry.Invariants`. An invariant event is one that
  can only fire if Raxol itself is wrong. Before this mechanism existed, such
  an event was emitted, logged, and ignored -- which is how a turn that
  delivered zero content shipped while the library was warning about it on
  stderr. A guard that nothing asserts on is not a guard.

  ## Why this module lives in `lib/` and not `test/support/`

  Dependent packages `use` it from THEIR tests, and a dependency's
  `test/support` tree is not on the consumer's load path -- only `lib/` is
  compiled into the delivered application. ExUnit is therefore touched only
  inside functions that this module injects into, or that are called from, a
  test module (`ExUnit.Callbacks.on_exit/1`, `ExUnit.Assertions.flunk/1`).
  Nothing here requires ExUnit at runtime for a normal library consumer, and
  nothing here is executed by simply loading `raxol_core`.

  ## Declaring an invariant on purpose

  A test that DELIBERATELY drives a bad path declares it:

      @tag expect_invariant: [[:raxol, :payments, :xochi, :unchecked_settlement]]

  A single event may be given unwrapped (`expect_invariant: [:raxol, :payments,
  :xochi, :unchecked_settlement]`). The declaration is an ASSERTION, not a mute
  button: such a test also fails when the event does NOT fire. That is the
  point -- it converts "this test happens to drive a bad path" into "this test
  pins the bad path". Declaring an event the registry does not classify as
  `:invariant` is itself a failure, so the tag cannot drift away from the
  registry.

  ## Only sound in `async: false` modules

  `:telemetry` handlers are global and run in the EMITTING process, so a
  handler cannot tell which concurrently-running test caused an event: an
  invariant fired by test A would be reported against test B. Every module that
  uses this sentinel MUST therefore be `async: false`. A few hundred
  milliseconds of serial runtime is worth a guard that cannot misattribute.

  Pid-ancestry filtering is deliberately NOT attempted: `$ancestors` does not
  survive the `Task.Supervisor` hops these systems use, so it would silently
  drop the events most worth catching.

  ## How the events survive the test process

  The handler runs in whichever process emitted the event, and the verdict is
  rendered from `on_exit/1` (the only hook that runs after the test body), by
  which time the test process is already gone -- so messaging `self()` from the
  handler cannot work. Fired events are parked in a public ETS table owned by
  one long-lived collector process, keyed by the per-test handler id, and
  dropped when the verdict is rendered. Table and collector names are derived
  from the registry module, so two packages' sentinels cannot collide in one
  BEAM.
  """

  defmacro __using__(opts) do
    registry =
      case Keyword.fetch(opts, :registry) do
        {:ok, registry} ->
          registry

        :error ->
          raise ArgumentError, """
          `use Raxol.Core.Telemetry.InvariantSentinel` requires `registry:`, a
          module built with `use Raxol.Core.Telemetry.Invariants`, e.g.

              use Raxol.Core.Telemetry.InvariantSentinel, registry: Raxol.Payments.Telemetry
          """
      end

    quote do
      setup context do
        unquote(__MODULE__).arm(context, unquote(registry))
      end
    end
  end

  @doc """
  Attach a per-test handler for every invariant event in `registry` and
  register the end-of-test verdict. Called by the `setup` that `__using__/1`
  injects.
  """
  @spec arm(map(), module()) :: :ok
  def arm(context, registry) do
    assert_registry!(registry)
    expected = expected_invariants(context, registry)
    handler_id = {__MODULE__, registry, System.unique_integer([:positive])}

    attach(handler_id, registry)

    ExUnit.Callbacks.on_exit(fn ->
      :telemetry.detach(handler_id)
      verdict(handler_id, expected, registry)
    end)

    :ok
  end

  @doc false
  # Public so raxol_core's own tests can drive the failure paths: a verdict is
  # rendered from `on_exit/1`, where a flunk fails the test outright, so the
  # only way to assert on the failure MESSAGES is to call the halves directly.
  @spec attach(term(), module()) :: :ok
  def attach(handler_id, registry) do
    ensure_collector(registry)

    case registry.invariant_events() do
      [] ->
        # `attach_many` with no events would still register a handler; skipping
        # keeps the handler table clean for registries that (legitimately)
        # classify nothing as :invariant.
        :ok

      events ->
        :ok =
          :telemetry.attach_many(
            handler_id,
            events,
            &__MODULE__.handle/4,
            {table_name(registry), handler_id}
          )
    end
  end

  @doc false
  def handle(event, measurements, metadata, {table, handler_id}) do
    :ets.insert(table, {handler_id, event, measurements, metadata})
    :ok
  end

  # -- verdict ----------------------------------------------------------------

  @doc false
  @spec verdict(term(), [[atom()]], module()) :: :ok
  def verdict(handler_id, expected, registry) do
    table = table_name(registry)
    fired = if :ets.whereis(table) == :undefined, do: [], else: :ets.lookup(table, handler_id)
    if fired != [], do: :ets.delete(table, handler_id)

    fired_events = fired |> Enum.map(fn {_id, event, _m, _md} -> event end) |> Enum.uniq()

    unexpected = Enum.reject(fired, fn {_id, event, _m, _md} -> event in expected end)
    missing = expected -- fired_events

    cond do
      unexpected != [] -> ExUnit.Assertions.flunk(unexpected_message(unexpected, registry))
      missing != [] -> ExUnit.Assertions.flunk(missing_message(missing, fired_events))
      true -> :ok
    end
  end

  defp unexpected_message(unexpected, registry) do
    detail =
      unexpected
      |> Enum.map_join("\n\n", fn {_id, event, measurements, metadata} ->
        "    event:        #{inspect(event)}\n" <>
          "    measurements: #{inspect(measurements)}\n" <>
          "    metadata:     #{inspect(metadata, pretty: true, limit: 20)}"
      end)

    tag = unexpected |> Enum.map(fn {_id, e, _m, _md} -> e end) |> Enum.uniq()

    """
    An INVARIANT telemetry event fired during this test.

    #{detail}

    #{inspect(registry)} classifies these events as ones that can only fire if
    this library is wrong -- not a peer, not the network, not the chain, not
    the filesystem, not the user. Fix the code path, or, if this test drives
    the bad path deliberately, declare it so the test PINS that path:

        @tag expect_invariant: #{inspect(tag)}
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

  defp expected_invariants(context, registry) do
    context
    |> Map.get(:expect_invariant)
    |> normalize_expected()
    |> tap(&assert_classified(&1, registry))
  end

  defp normalize_expected(nil), do: []
  defp normalize_expected([head | _] = event) when is_atom(head), do: [event]

  defp normalize_expected(events) when is_list(events) do
    Enum.map(events, fn
      event when is_list(event) -> event
      other -> bad_tag!(other)
    end)
  end

  defp normalize_expected(other), do: bad_tag!(other)

  defp bad_tag!(other) do
    ExUnit.Assertions.flunk(
      "expect_invariant must be a telemetry event (a list of atoms) or a " <>
        "list of them; got #{inspect(other)}"
    )
  end

  # A tag naming a non-invariant event would be silently inert, so it is an
  # error: the tag must not be able to drift away from the registry.
  defp assert_classified(events, registry) do
    classified = registry.invariant_events()

    case Enum.reject(events, &(&1 in classified)) do
      [] ->
        :ok

      bogus ->
        ExUnit.Assertions.flunk("""
        expect_invariant names #{inspect(bogus)}, which #{inspect(registry)}
        does not classify as :invariant. The sentinel only arms invariants, so
        this tag can never be satisfied. Either classify the event as
        :invariant in #{inspect(registry)} or drop the tag.
        """)
    end
  end

  defp assert_registry!(registry) do
    if Code.ensure_loaded?(registry) and function_exported?(registry, :invariant_events, 0) do
      :ok
    else
      ExUnit.Assertions.flunk("""
      #{inspect(registry)} is not a telemetry invariant registry: it does not
      export invariant_events/0. Build it with

          use Raxol.Core.Telemetry.Invariants, events: %{...}
      """)
    end
  end

  # -- collector --------------------------------------------------------------

  defp table_name(registry), do: :"#{registry}.InvariantSentinel"
  defp collector_name(registry), do: :"#{registry}.InvariantSentinel.Collector"

  # One process per registry for the whole run, owning the public table. It
  # holds no state of its own: it exists only so the table outlives every test
  # process, since the verdict is rendered after the test process is gone.
  defp ensure_collector(registry) do
    case Process.whereis(collector_name(registry)) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        ref = make_ref()
        parent = self()
        spawn(fn -> boot_collector(registry, parent, ref) end)

        receive do
          {^ref, :ready} -> :ok
        after
          5_000 ->
            ExUnit.Assertions.flunk(
              "invariant sentinel collector for #{inspect(registry)} did not start; " <>
                "the sentinel cannot observe events without it"
            )
        end
    end
  end

  defp boot_collector(registry, parent, ref) do
    owner? =
      try do
        :ets.new(table_name(registry), [:named_table, :public, :duplicate_bag])
        Process.register(self(), collector_name(registry))
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
