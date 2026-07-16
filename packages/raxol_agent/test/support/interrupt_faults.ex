defmodule Raxol.Agent.Interrupt.Faults do
  @moduledoc """
  Fired-counter harness for the U5-R dead-injector controls — the meta-invariant
  layer (`harness-invariants.md`, meta-invariants 1 & 2) applied to the interrupt
  reds.

  Named fault sites, one per dead injector:

    * `:skip_wait`         — an interrupt that skips the bounded-wait stage
      (signal → kill), violating the staging contour.
    * `:trust_exit_status` — an interrupt that top-pid-kills and trusts
      `:exit_status` instead of confirming process-group death, violating the
      effectiveness contour (orphaned grandchild).
    * `:late_result`       — an interrupt that lets a tool-result through AFTER
      kill-complete, violating the post-kill quiescence contour.
    * `:trust_reason`      — an interrupt that emits the wrong terminal event
      type (trusts the outcome's `:reason` field instead of journaling the
      frozen `:turn_canceled` record), violating the turn-canceled contour (P2).
    * `:trailing_output`   — mid-provider-stream (no tool Port): an interrupt
      that lets a stream chunk through AFTER `:turn_canceled`, violating the
      no-trailing-output contour (P3b).
    * `:naive_escalate`    — an interrupt that hard-kills unconditionally even
      when the tool already exited cooperatively during the grace window,
      violating the escalation-conditionality contour (the staged kill's
      short-circuit).
    * `:wait_kill_transposed` — an interrupt that kills BEFORE waiting (signal
      → kill → wait instead of signal → wait → kill), violating the staging
      contour's ordering.

  Each injector calls `record_fired/2` when it runs; a control arms its site and
  `assert_all_fired!/2` fails if an armed site never fired (a dead injector =
  green lies). Failure messages carry the seed/schedule for reproduction (m2).
  """

  @sites [
    :skip_wait,
    :trust_exit_status,
    :late_result,
    :trust_reason,
    :trailing_output,
    :naive_escalate,
    :wait_kill_transposed
  ]

  @doc "All named interrupt fault sites."
  @spec sites() :: [atom()]
  def sites, do: @sites

  @doc "Start a fresh harness (armed-site set + per-site fire counters)."
  @spec new() :: pid()
  def new do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  @doc "Arm a fault site: it MUST fire before `assert_all_fired!/2` or the control fails."
  @spec arm(pid(), atom()) :: pid()
  def arm(harness, site) when site in @sites do
    Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    harness
  end

  @doc "Record that a site fired (called by the dead injectors)."
  @spec record_fired(pid(), atom()) :: :ok
  def record_fired(harness, site) when site in @sites do
    Agent.update(harness, fn s ->
      %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
    end)

    :ok
  end

  @doc "Per-site fire counts."
  @spec fired(pid()) :: %{optional(atom()) => non_neg_integer()}
  def fired(harness), do: Agent.get(harness, & &1.fired)

  @doc """
  Fail if any armed site never fired (meta-inv 1). `schedule` (the run's seed and
  site list) is echoed in the failure message so a dead-injector failure is
  reproducible (meta-inv 2).
  """
  @spec assert_all_fired!(pid(), term()) :: %{optional(atom()) => non_neg_integer()}
  def assert_all_fired!(harness, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(harness, & &1)
    dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed interrupt fault site(s) never fired: #{inspect(dead)}\n" <>
            "fired counts: #{inspect(fired)}\n" <>
            "schedule: #{inspect(schedule)}"
    end

    fired
  end
end
