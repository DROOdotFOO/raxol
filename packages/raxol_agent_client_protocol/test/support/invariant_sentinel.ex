defmodule Raxol.AgentClientProtocol.Test.InvariantSentinel do
  @moduledoc """
  Turns `Raxol.AgentClientProtocol.Telemetry.invariant_events/0` into test
  failures.

  An `:invariant` event can only fire if this library is wrong (see
  `Raxol.AgentClientProtocol.Telemetry` for the criterion). Emitting one and
  carrying on is how a `[:raxol, :acp, :zero_updates_turn]` bug shipped: the
  signal existed, nothing consumed it. Arming this sentinel in a suite makes the
  signal load-bearing.

  ## Usage

      defmodule MySuite do
        use ExUnit.Case, async: false
        use Raxol.AgentClientProtocol.Test.InvariantSentinel
      end

  A test that DELIBERATELY drives an invariant declares it:

      @tag expect_invariant: [[:raxol, :acp, :dup_reply]]
      test "second reply on a consumed obligation is a suppressed no-op" do

  A single event name (`expect_invariant: [:raxol, :acp, :dup_reply]`) is
  accepted too. The declaration is an assertion, not a mute button: a declared
  event that does NOT fire fails the test just as loudly as an undeclared one
  that does. That is what converts a "drives the bad path" test into a test that
  pins the bad path.

  ## Why `async: false` is mandatory

  `:telemetry` handlers are global and run in the EMITTING process. There is no
  reliable way to attribute an event to the async test that caused it --
  `$ancestors` does not survive the `Task.Supervisor` hops these sessions use,
  and the emitting process is frequently a Connection or Session owned by a
  supervisor, not a descendant of the test pid. So the sentinel is only sound in
  `async: false` modules: with serialised tests, "an armed event fired while
  this test was running" is unambiguous. `__using__/1` therefore raises at
  compile time if the module is `async: true`.
  """

  alias Raxol.AgentClientProtocol.Telemetry

  @doc false
  defmacro __using__(_opts) do
    quote do
      require Raxol.AgentClientProtocol.Test.InvariantSentinel

      setup context do
        Raxol.AgentClientProtocol.Test.InvariantSentinel.arm(context)
      end
    end
  end

  @doc """
  Arm the sentinel for one test. Called by the `setup` that `__using__/1`
  injects; returns `:ok` so it composes with other `setup` blocks.
  """
  @spec arm(map()) :: :ok
  def arm(context) when is_map(context) do
    verify_serialised!(context)

    expected = expected_events(context)
    handler_id = {__MODULE__, context[:test], make_ref()}

    # Deliberately UNLINKED: ExUnit runs `on_exit` callbacks in a separate
    # process, after the test process has already exited, so a collector tied
    # to the test pid (its mailbox, or a linked/supervised child) would be gone
    # exactly when the verdict needs to read it. `on_exit` below always stops
    # it, so it cannot leak.
    {:ok, collector} = Agent.start(fn -> [] end)

    :ok =
      :telemetry.attach_many(
        handler_id,
        Telemetry.invariant_events(),
        &__MODULE__.__handle__/4,
        %{collector: collector}
      )

    ExUnit.Callbacks.on_exit(fn ->
      :telemetry.detach(handler_id)
      fired = Agent.get(collector, &Enum.reverse(&1))
      Agent.stop(collector)
      verdict(fired, expected, context)
    end)

    :ok
  end

  @doc false
  # Runs in the EMITTING process (a Connection, Session, or dispatch Task --
  # never reliably a descendant of the test pid), which is why the collector is
  # an independent process addressed by pid.
  def __handle__(event, _measurements, metadata, %{collector: collector}) do
    Agent.update(collector, &[{event, metadata} | &1])
    :ok
  end

  # -- Internals --------------------------------------------------------------

  @spec verify_serialised!(map()) :: :ok
  defp verify_serialised!(context) do
    if Map.get(context, :async) do
      raise ArgumentError, """
      #{inspect(__MODULE__)} requires `async: false`.

      #{inspect(context[:module])} is `async: true`. :telemetry handlers are
      global and run in the emitting process, so a fired invariant cannot be
      attributed to the test that caused it while tests run concurrently. Flip
      the module to `async: false`.
      """
    end

    :ok
  end

  @spec expected_events(map()) :: [[atom()]]
  defp expected_events(context) do
    case Map.get(context, :expect_invariant) do
      nil -> []
      [head | _] = events when is_list(head) -> events
      event when is_list(event) -> [event]
    end
  end

  @spec verdict([{[atom()], map()}], [[atom()]], map()) :: :ok
  defp verdict(fired, expected, context) do
    fired_names = fired |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    unexpected = Enum.reject(fired, fn {event, _md} -> event in expected end)
    missing = expected -- fired_names

    cond do
      unexpected != [] -> raise ExUnit.AssertionError, message: violation(unexpected, context)
      missing != [] -> raise ExUnit.AssertionError, message: unfired(missing, context)
      true -> :ok
    end
  end

  @spec violation([{[atom()], map()}], map()) :: String.t()
  defp violation(unexpected, context) do
    """
    ACP invariant telemetry fired during this test.

    An :invariant event can only fire if this library is wrong
    (Raxol.AgentClientProtocol.Telemetry). Either the code under test broke a
    contract, or -- if this test drives the bad path on purpose -- declare it:

        @tag expect_invariant: #{inspect(Enum.map(unexpected, &elem(&1, 0)) |> Enum.uniq())}

    Test: #{inspect(context[:module])} #{inspect(context[:test])}

    Fired:
    #{Enum.map_join(unexpected, "\n", fn {event, md} -> "  * #{inspect(event)} #{inspect(md)}" end)}
    """
  end

  @spec unfired([[atom()]], map()) :: String.t()
  defp unfired(missing, context) do
    """
    Declared @tag expect_invariant event(s) never fired: #{inspect(missing)}

    `expect_invariant` is an assertion, not a mute button: this test claims to
    drive that bad path, so the path must actually be driven. Either the test no
    longer reaches it (fix the test) or the behaviour changed and the tag should
    be removed.

    Test: #{inspect(context[:module])} #{inspect(context[:test])}
    """
  end
end
