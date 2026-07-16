defmodule Raxol.Agent.Red.SteerFaults do
  @moduledoc """
  Fired-counter harness for the U6-R negative controls (harness-invariants.md
  meta-invariant 1: "every named fault site keeps a counter; the suite FAILS if a
  site never fired — a dead injector = green lies").

  Mirrors `Raxol.Agent.Invariants.FaultJournal`'s counter mechanics, scoped to
  the seven U6 steer dead injectors (see `Raxol.Agent.Red.SteerInjectors`'s
  moduledoc table for the full injector -> contour map). A control arms every
  site, records each one as it confirms the matching contour is caught, and
  calls `assert_all_fired!/2` so an injector that silently stopped injecting
  fails the control instead of passing quietly.
  """

  @sites [
    :skip_cas,
    :journal_before_cas,
    :drop_dedup,
    :in_memory_only_dedup,
    :repeatable_token,
    :nil_turn_accept,
    :ignore_payload_mismatch
  ]

  @doc "All named U6 steer fault sites (the seven dead injectors)."
  def sites, do: @sites

  @doc """
  Start a fresh harness (armed-site set + per-site fire counters).

  The backing `Agent` is started via `ExUnit.Callbacks.start_supervised!/2`
  (must be called from the test process), so it is torn down automatically at
  the end of the test — no per-control-test process leak, no manual `on_exit`.
  """
  def new do
    ExUnit.Callbacks.start_supervised!(%{
      id: {__MODULE__, System.unique_integer([:positive])},
      start: {Agent, :start_link, [fn -> %{armed: MapSet.new(), fired: %{}} end]},
      restart: :temporary
    })
  end

  @doc "Arm a fault site: it MUST fire before `assert_all_fired!/2` or the control fails."
  def arm(harness, site) when site in @sites do
    Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    harness
  end

  @doc "Record that a site fired (the control calls this after confirming the injector is caught)."
  def record_fired(harness, site) when site in @sites do
    Agent.update(harness, fn s ->
      %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
    end)

    :ok
  end

  @doc "Per-site fire counts."
  def fired(harness), do: Agent.get(harness, & &1.fired)

  @doc """
  Fail if any armed site never fired (dead injector). `schedule` (any term) is
  echoed into the failure message so a failing run dumps the schedule alongside
  the ExUnit seed. Returns the fire-count map on success.
  """
  def assert_all_fired!(harness, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(harness, & &1)
    dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed U6 steer fault site(s) never fired: #{inspect(dead)}\n" <>
            "fired counts: #{inspect(fired)}\n" <>
            "schedule: #{inspect(schedule)}"
    end

    fired
  end
end
