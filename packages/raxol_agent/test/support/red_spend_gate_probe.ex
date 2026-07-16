defmodule Raxol.Agent.Red.SpendGateProbe do
  @moduledoc """
  Support harness for the U7-R red suite (SpendGate reserve-before-call, AD-6a).

  Everything the red suite folds and the negative controls mutate lives here:

    * **cost journal** — the injectable `context.emit` sink and the fold source.
      A serialized recorder (Agent) so concurrent `around/4` calls under one
      budget still yield a total-ordered record stream.
    * **provider stub** — a `:counters` call-counter. The fail-closed contour is
      caught by this counter (a provider invocation on a refused reserve bumps
      it past the expected count).
    * **budget** — an atomic `try_reserve` reference in the `Ledger.try_spend`
      shape (serialized get_and_update). The single source of truth for the
      run/session cap; the dual-truth dead injector deliberately bypasses it.
      `try_reserve_fun/1` closes over it as the frozen `context.try_reserve`
      seam (`Raxol.Agent.SpendGate` context shape) — BOTH the real gate and
      every injector below reserve through this SAME closure, so the
      atomicity guarantee binds the context contract, not this probe module.
    * **checkers** — pure folds over the record stream: reserve→call→settle
      order, fail-closed, no-over-reserve (PEAK concurrent, not cumulative),
      no-double-settle, dangling-reserve-visible.
    * **fired counters** (meta-invariant m1) — every dead injector arms a site
      and must fire; `assert_all_fired!/2` fails on a dead injector.
    * **dead injectors** — wrong SpendGate implementations (settle-only,
      call-on-refused, dual-truth, crash-loses-reserve). Each is a one-mutation
      negative control (m4): the matching checker MUST flag it.

  Record shape (the frozen observable):

      %{kind: :reserve | :reserve_refused | :call | :settle,
        cost_ref: String.t(),
        estimate: non_neg_integer() | nil,
        actual: non_neg_integer() | nil,
        reason: atom() | nil,
        seq: non_neg_integer()}
  """

  # --- cost journal (injectable emit sink + fold source) ---------------------

  @doc "A fresh serialized cost journal. Returns the recorder pid."
  def new_journal do
    {:ok, pid} = Agent.start_link(fn -> %{seq: 0, records: []} end)
    pid
  end

  @doc """
  The `context.emit` closure to hand the gate. Appends one record, stamping a
  monotonic `:seq`. Missing optional fields default to nil.
  """
  def emit_fun(journal) do
    fn record when is_map(record) -> record(journal, record) end
  end

  @doc "Append one record to the journal (used by the emit closure and injectors)."
  def record(journal, record) when is_map(record) do
    Agent.update(journal, fn %{seq: seq, records: records} ->
      stamped =
        %{kind: nil, cost_ref: nil, estimate: nil, actual: nil, reason: nil}
        |> Map.merge(record)
        |> Map.put(:seq, seq + 1)

      %{seq: seq + 1, records: [stamped | records]}
    end)

    :ok
  end

  @doc "All records in emission (fold) order."
  def records(journal), do: Agent.get(journal, fn %{records: r} -> Enum.reverse(r) end)

  # --- provider stub (call counter) ------------------------------------------

  @doc "A fresh provider stub. Returns a `:counters` ref."
  def new_provider, do: :counters.new(1, [])

  @doc "Invoke the provider: bump the call counter, return `actual`."
  def provider_call(provider, actual) do
    :counters.add(provider, 1, 1)
    actual
  end

  @doc "How many times the provider stub was actually invoked."
  def provider_calls(provider), do: :counters.get(provider, 1)

  @doc """
  Build a `call_fun` for `around/4`: invokes the provider stub for `actual`
  tokens and returns `{actual, result}`.
  """
  def call_fun(provider, cost_ref, actual) do
    fn -> {provider_call(provider, actual), {:result, cost_ref}} end
  end

  # --- atomic budget (the try_spend-shaped reference) ------------------------

  @doc "A fresh budget with cap `cap` tokens. Returns the budget pid."
  def new_budget(cap) do
    {:ok, pid} = Agent.start_link(fn -> %{reserved: 0, cap: cap} end)
    pid
  end

  @doc """
  Atomically reserve `amount` against the cap — the frozen `context.try_reserve`
  seam shape (`Raxol.Agent.SpendGate` context; the `Ledger.try_spend` shape):
  `{:ok, remaining}` on success (`remaining` = cap minus now-reserved),
  `{:error, :over_limit}` when it would exceed the cap. Serialized by the
  Agent in one `get_and_update`, so concurrent reservers can never
  over-reserve and never read a stale `remaining`.
  """
  def try_reserve(budget, amount) do
    Agent.get_and_update(budget, fn %{reserved: reserved, cap: cap} = s ->
      new_reserved = reserved + amount

      if new_reserved <= cap do
        {{:ok, cap - new_reserved}, %{s | reserved: new_reserved}}
      else
        {{:error, :over_limit}, s}
      end
    end)
  end

  @doc """
  Build the `context.try_reserve` closure for `budget` — the frozen reserve
  seam BOTH the real `Raxol.Agent.SpendGate` implementation and every dead
  injector below MUST reserve through. Freezing this in the context shape
  (rather than each caller reaching into a test-support module function)
  is what binds the atomicity guarantee to the GATE, not to the probe.
  """
  def try_reserve_fun(budget), do: fn amount -> try_reserve(budget, amount) end

  @doc "Total currently reserved against the budget."
  def budget_reserved(budget), do: Agent.get(budget, fn %{reserved: r} -> r end)

  # --- checkers (pure folds over the record stream) --------------------------

  @canonical_orders [
    [],
    [:reserve_refused],
    [:reserve],
    [:reserve, :call],
    [:reserve, :call, :settle]
  ]

  @doc "The kinds recorded for `cost_ref`, in fold (seq) order."
  def kinds_for(records, cost_ref) do
    records
    |> Enum.filter(&(&1.cost_ref == cost_ref))
    |> Enum.sort_by(& &1.seq)
    |> Enum.map(& &1.kind)
  end

  @doc """
  Reserve→call→settle order, per call. Every cost_ref's record subsequence must
  be a legal prefix of `reserve → call → settle` (or a lone `reserve_refused`).
  A `:call` with no prior `:reserve`, or a `:settle` with no prior `:call`, or a
  post-hoc settle-only trace, all fail here.
  """
  def reserve_before_call(records) do
    records
    |> group_refs()
    |> Enum.reduce_while(:ok, fn cost_ref, :ok ->
      kinds = kinds_for(records, cost_ref)

      if kinds in @canonical_orders do
        {:cont, :ok}
      else
        {:halt, {:error, {:bad_order, cost_ref, kinds}}}
      end
    end)
  end

  @doc """
  Fail-closed: no reserve ⇒ no call. For every refused cost_ref there is no
  `:call` record, AND the provider was invoked exactly `expected_calls` times —
  the stub counter is what catches a provider call snuck in on a refused reserve.
  """
  def fail_closed(records, provider_calls, expected_calls) do
    refused = for r <- records, r.kind == :reserve_refused, do: r.cost_ref

    called_after_refusal =
      Enum.find(refused, fn cost_ref -> :call in kinds_for(records, cost_ref) end)

    cond do
      called_after_refusal != nil ->
        {:error, {:call_after_refusal, called_after_refusal}}

      provider_calls != expected_calls ->
        {:error, {:provider_calls, provider_calls, expected_calls}}

      true ->
        :ok
    end
  end

  @doc """
  No over-reserve: the PEAK concurrent reserved total, folded in `seq` order,
  never exceeds `cap`. A `:reserve` adds its `estimate` to the running total;
  a `:settle` refunds `estimate - actual` back (the amount that stays
  permanently spent is `actual`; the freed `estimate - actual` is available
  for reuse). The checker tracks the running total's PEAK over the whole
  fold — not the cumulative sum of every `:reserve` ever emitted.

  Cumulative-summing every reserve (the old checker) wrongly rejects a
  legitimate refund-and-reuse gate: an early settle with `actual < estimate`
  frees budget for a LATER reserve in the same run, and a cumulative sum has
  no notion of "freed." Peak-tracking still catches the dual-truth class
  exactly as before, since a gate that never consults the shared budget only
  ever grows the running total (no settle event can bring the peak down).
  """
  def reserved_within_cap(records, cap) do
    estimate_by_ref =
      for(r <- records, r.kind == :reserve, do: {r.cost_ref, r.estimate}) |> Map.new()

    {peak, _running} =
      records
      |> Enum.sort_by(& &1.seq)
      |> Enum.reduce({0, 0}, fn record, {peak, running} -> fold_reserved(record, estimate_by_ref, peak, running) end)

    if peak <= cap, do: :ok, else: {:error, {:over_reserve, peak, cap}}
  end

  defp fold_reserved(%{kind: :reserve, estimate: estimate}, _estimate_by_ref, peak, running) do
    new_running = running + estimate
    {max(peak, new_running), new_running}
  end

  defp fold_reserved(%{kind: :settle, cost_ref: cost_ref, actual: actual}, estimate_by_ref, peak, running) do
    refund = Map.get(estimate_by_ref, cost_ref, actual) - actual
    new_running = running - refund
    {max(peak, new_running), new_running}
  end

  defp fold_reserved(_record, _estimate_by_ref, peak, running), do: {peak, running}

  @doc """
  No double-settle: a reservation must be settled exactly once. A second
  `:settle` for the same `cost_ref` is a reservation-token replay — each
  settle independently refunds `estimate - actual`, so double-settling
  refunds TWICE (money inflation: the budget ends up with more available
  capacity than the true accounting allows).
  """
  def no_double_settle(records) do
    records
    |> group_refs()
    |> Enum.reduce_while(:ok, fn cost_ref, :ok ->
      count = records |> kinds_for(cost_ref) |> Enum.count(&(&1 == :settle))

      if count <= 1 do
        {:cont, :ok}
      else
        {:halt, {:error, {:double_settle, cost_ref, count}}}
      end
    end)
  end

  @doc """
  A reserve for `cost_ref` with no matching settle is PRESENT (dangling, not
  silently lost) — the crash-between-reserve-and-call contour. `:reserve_lost`
  when the reserve vanished; `:not_dangling` when it actually settled.
  """
  def dangling_reserve_visible(records, cost_ref) do
    kinds = kinds_for(records, cost_ref)

    cond do
      :reserve not in kinds -> {:error, :reserve_lost}
      :settle in kinds -> {:error, :not_dangling}
      true -> :ok
    end
  end

  @doc "Number of successful spend-bearing calls in the fold (one `:call` each)."
  def call_count(records), do: Enum.count(records, &(&1.kind == :call))

  defp group_refs(records) do
    records |> Enum.map(& &1.cost_ref) |> Enum.uniq()
  end

  # --- fired counters (meta-invariant m1) ------------------------------------

  @doc "A fresh fired-counter probe."
  def new_probe do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  @doc "Arm an injector site: it MUST fire before `assert_all_fired!/2`."
  def arm(probe, site) do
    Agent.update(probe, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    probe
  end

  @doc "Record that an injector site fired (called by the injectors below)."
  def fire(probe, site) do
    Agent.update(probe, fn s ->
      %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
    end)

    :ok
  end

  @doc "Per-site fire counts."
  def fired(probe), do: Agent.get(probe, & &1.fired)

  @doc """
  meta-invariant m1: fail if any armed injector never fired (a dead injector =
  a green lie). `schedule` is dumped in the message for seed reproduction (m2).
  """
  def assert_all_fired!(probe, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(probe, & &1)
    dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed site(s) never fired: #{inspect(dead)}\n" <>
            "fired counts: #{inspect(fired)}\n" <>
            "schedule: #{inspect(schedule)}"
    end

    fired
  end

  # --- dead injectors (one mutation each; the negative controls, m4) ---------
  #
  # Each is a WRONG SpendGate implementation. The matching checker MUST flag it,
  # proving the checker is not vacuous. Every injector reads context.emit /
  # context.probe / context.budget exactly as the real gate would.

  defmodule SettleOnlyInjector do
    @moduledoc "Post-hoc accounting: settles without reserving. Fails the ORDER red."
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def around(ctx, cost_ref, _estimate, call_fun) do
      P.fire(ctx.probe, :settle_only)
      {actual, result} = call_fun.()
      # No reserve, no call record — a lone settle after the fact.
      ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
      {:ok, result}
    end
  end

  defmodule CallOnRefusedInjector do
    @moduledoc "Calls the provider on a refused reserve. Fails the FAIL-CLOSED red."
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def around(ctx, cost_ref, estimate, call_fun) do
      P.fire(ctx.probe, :call_on_refused)

      # Reserves through the FROZEN context.try_reserve seam, same as the
      # real gate would — the violation is calling the provider anyway.
      case ctx.try_reserve.(estimate) do
        {:error, reason} ->
          ctx.emit.(%{kind: :reserve_refused, cost_ref: cost_ref, reason: reason})
          # VIOLATION: makes the call anyway. The stub counter catches it.
          {_actual, _result} = call_fun.()
          {:error, {:reserve_refused, reason}}

        {:ok, _remaining} ->
          {actual, result} = call_fun.()
          ctx.emit.(%{kind: :reserve, cost_ref: cost_ref, estimate: estimate})
          ctx.emit.(%{kind: :call, cost_ref: cost_ref})
          ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
          {:ok, result}
      end
    end
  end

  defmodule DualTruthInjector do
    @moduledoc """
    Reserves against a stale/second counter (here: nothing) instead of the one
    atomic budget, so concurrent calls over-reserve past the cap. Fails the
    NO-OVER-RESERVE red.
    """
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def around(ctx, cost_ref, estimate, call_fun) do
      P.fire(ctx.probe, :dual_truth)
      # Never consults ctx.budget or ctx.try_reserve — every call "succeeds".
      ctx.emit.(%{kind: :reserve, cost_ref: cost_ref, estimate: estimate})
      {actual, result} = call_fun.()
      ctx.emit.(%{kind: :call, cost_ref: cost_ref})
      ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
      {:ok, result}
    end
  end

  defmodule DuplicateReserveInjector do
    @moduledoc """
    Reserves the SAME cost_ref TWICE before calling (e.g. a naive retry that
    re-reserves instead of checking for an already-dangling reservation).
    Fails the ORDER red: `[:reserve, :reserve, :call, :settle]` is not a
    legal prefix of reserve → call → settle.
    """
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def around(ctx, cost_ref, estimate, call_fun) do
      P.fire(ctx.probe, :duplicate_reserve)

      with {:ok, _} <- ctx.try_reserve.(estimate),
           {:ok, _} <- ctx.try_reserve.(estimate) do
        ctx.emit.(%{kind: :reserve, cost_ref: cost_ref, estimate: estimate})
        ctx.emit.(%{kind: :reserve, cost_ref: cost_ref, estimate: estimate})
        {actual, result} = call_fun.()
        ctx.emit.(%{kind: :call, cost_ref: cost_ref})
        ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
        {:ok, result}
      end
    end
  end

  defmodule DoubleSettleInjector do
    @moduledoc """
    Settles the same reservation TWICE — a reservation-token replay. Each
    `:settle` independently refunds `estimate - actual`, so double-settling
    refunds twice: money inflation (the budget ends up with more available
    capacity than the true accounting allows). Fails the DOUBLE-SETTLE red.
    """
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def around(ctx, cost_ref, estimate, call_fun) do
      P.fire(ctx.probe, :double_settle)

      with {:ok, _remaining} <- ctx.try_reserve.(estimate) do
        ctx.emit.(%{kind: :reserve, cost_ref: cost_ref, estimate: estimate})
        {actual, result} = call_fun.()
        ctx.emit.(%{kind: :call, cost_ref: cost_ref})
        # VIOLATION: settles (and refunds) twice — replaying the reservation token.
        ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
        ctx.emit.(%{kind: :settle, cost_ref: cost_ref, actual: actual})
        {:ok, result}
      end
    end
  end

  defmodule CrashLosesReserveInjector do
    @moduledoc """
    Loses the reserve on a crash: the reservation is in-memory only, never
    journaled, so a crash before the call silently drops it. Fails the
    DANGLING-RESERVE-VISIBLE red.
    """
    alias Raxol.Agent.Red.SpendGateProbe, as: P

    def reserve(ctx, cost_ref, estimate) do
      P.fire(ctx.probe, :crash_loses_reserve)
      # VIOLATION: emits nothing durable — the reserve is invisible after a crash.
      {:ok, %{cost_ref: cost_ref, estimate: estimate}}
    end
  end
end
