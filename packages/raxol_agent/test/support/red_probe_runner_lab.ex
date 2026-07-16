defmodule Raxol.Agent.Red.ProbeRunnerLab do
  @moduledoc """
  Support harness for the U12-R red suite — the probe Runner interface
  (`harness-freeze-contracts.md` §3). Everything the red suite folds and the
  negative controls mutate lives here:

    * **meta-event bus** — the injectable `opts[:emit]` sink and the fold source.
      A serialized recorder (Agent) so concurrent runs still yield a
      total-ordered `probe_run` / drafted-`meta_result` / `reserve|call|settle`
      stream (the frozen observable).
    * **provider stub** — a `:counters` call-counter plus a captured-request
      list. The reserve-before-call red is caught by the counter (a call on a
      leash-exceeded/refused run bumps it past the allowed count); the
      prefix-byte-identity red is caught by the captured prefixes.
    * **budget** — an atomic `try_reserve` reference in the `Ledger.try_spend`
      shape (serialized get_and_update). The single source of truth for the
      run/session cap.
    * **checkers** — pure folds over the record stream: lifecycle completeness,
      reserve→call→settle order, fail-closed, leash, prefix byte-identity,
      family isolation, provenance/taint stamping, output atomicity, bounded
      parking, fingerprint presence, loop-fold independence.
    * **fired counters** (meta-invariant m1) — every dead injector arms a site
      and must fire; `assert_all_fired!/2` fails on a dead injector, dumping the
      seed-reproducible schedule (m2).
    * **dead injectors** — wrong Runner implementations (one mutation each, m4).
      The matching checker MUST flag each.
    * **test probes** — real `Raxol.Agent.Probe` implementations the red suite
      submits to the (unimplemented) Runner.

  Record shape (the frozen observable the checkers fold):

      # lifecycle
      %{kind: :probe_run, run_id:, probe:, status:, charge:, refs:,
        fingerprint:, reason:, seq:}
      # a result meta event the Runner drafts + emits on the probe's behalf
      %{kind: :meta_result, run_id:, type:, family:, source:, trust:, refs:,
        seq:}
      # provider accounting (reserve-before-call)
      %{kind: :reserve | :call | :settle, run_id:, estimate:, actual:, seq:}
      # a primary-loop event (isolation projection)
      %{kind: :loop, label:, seq:}
  """

  # Opening / terminal status partitions of the frozen probe_run enum.
  @opening [:started, :parked]
  @terminal [:completed, :killed, :exhausted, :timeout, :error]
  # Non-happy terminals: reaching one after drafting means output must be empty.
  @nonhappy [:killed, :exhausted, :timeout, :error]

  def opening_statuses, do: @opening
  def terminal_statuses, do: @terminal

  # ---------------------------------------------------------------------------
  # The primary loop's most recent request prefix at the tip — the cache-ride
  # byte-identity target (P-U12.3). Opaque bytes; probes ride, never rebuild.
  # ---------------------------------------------------------------------------

  @primary_prefix ~s([{"role":"system","content":"you are"},{"role":"user","content":"hi  there"}])

  @doc "The byte-exact primary request prefix every cache-riding probe must ride."
  def primary_prefix, do: @primary_prefix

  @doc """
  A re-serializing prefix builder's output: byte-divergent from `primary_prefix`
  by exactly one byte (the double space collapsed to one) — the N-U12.5 mutation.
  """
  def reserialized_prefix, do: String.replace(@primary_prefix, "hi  there", "hi there")

  # ---------------------------------------------------------------------------
  # meta-event bus (injectable emit sink + fold source)
  # ---------------------------------------------------------------------------

  @doc "A fresh serialized event bus. Returns the recorder pid."
  def new_bus do
    {:ok, pid} = Agent.start_link(fn -> %{seq: 0, events: []} end)
    pid
  end

  @doc "The `opts[:emit]` closure to hand the Runner. Stamps a monotonic `:seq`."
  def emit_fun(bus), do: fn event when is_map(event) -> emit(bus, event) end

  @doc "Append one event to the bus (used by the emit closure and injectors)."
  def emit(bus, event) when is_map(event) do
    Agent.update(bus, fn %{seq: seq, events: events} ->
      %{seq: seq + 1, events: [Map.put(event, :seq, seq + 1) | events]}
    end)

    :ok
  end

  @doc "All events in emission (fold) order."
  def events(bus), do: Agent.get(bus, fn %{events: e} -> Enum.reverse(e) end)

  # ---------------------------------------------------------------------------
  # provider stub (call counter + built-request capture)
  # ---------------------------------------------------------------------------

  @doc "A fresh provider stub. Returns `%{calls: counters, captures: pid}`."
  def new_provider do
    {:ok, cap} = Agent.start_link(fn -> [] end)
    %{calls: :counters.new(1, []), captures: cap}
  end

  @doc """
  Invoke the provider stub: bump the call counter and capture the built request
  (`%{run_id, prefix, suffix}`) so prefix byte-identity is checkable with no real
  provider. Returns a canned response map.
  """
  def provider_call(provider, run_id, %{prefix: prefix} = request) do
    :counters.add(provider.calls, 1, 1)
    suffix = Map.get(request, :suffix, [])

    Agent.update(provider.captures, fn caps ->
      [%{run_id: run_id, prefix: prefix, suffix: suffix} | caps]
    end)

    %{content: "probe-response", usage: %{output_tokens: 12}}
  end

  @doc "How many times the provider stub was actually invoked."
  def provider_calls(provider), do: :counters.get(provider.calls, 1)

  @doc "Captured built requests, in call order."
  def captures(provider), do: Agent.get(provider.captures, &Enum.reverse/1)

  # ---------------------------------------------------------------------------
  # atomic budget (the try_spend-shaped reference)
  # ---------------------------------------------------------------------------

  @doc "A fresh budget with cap `cap` tokens. Returns the budget pid."
  def new_budget(cap) do
    {:ok, pid} = Agent.start_link(fn -> %{reserved: 0, cap: cap} end)
    pid
  end

  @doc "Current reserved tokens held against the budget (0 when fully released)."
  def reserved(budget), do: Agent.get(budget, fn %{reserved: r} -> r end)

  @doc "Atomically reserve `amount` against the cap. `:ok` or `{:over, reason}`."
  def try_reserve(budget, amount) do
    Agent.get_and_update(budget, fn %{reserved: reserved, cap: cap} = s ->
      if reserved + amount <= cap,
        do: {:ok, %{s | reserved: reserved + amount}},
        else: {{:over, :over_budget}, s}
    end)
  end

  # ---------------------------------------------------------------------------
  # event constructors
  # ---------------------------------------------------------------------------

  @doc "A default model/params fingerprint (REQUIRED on probe_run terminals)."
  def fingerprint do
    %{
      provider: "anthropic",
      name: "claude",
      revision: nil,
      params_hash: "sha256:frozen-fixture",
      params_inline: %{temperature: 0.0, top_p: 1.0, max_tokens: 256, seed: 7},
      prompt_cache_key: nil
    }
  end

  @doc "The frozen `charge` split shape (cache-riding dividend visible)."
  def charge(opts \\ []) do
    %{
      prompt_tokens: Keyword.get(opts, :prompt_tokens, 100),
      cached_prompt_tokens: Keyword.get(opts, :cached_prompt_tokens, 90),
      completion_tokens: Keyword.get(opts, :completion_tokens, 12),
      calls: Keyword.get(opts, :calls, 1)
    }
  end

  def opening(run_id, status, opts \\ []) when status in @opening do
    base(run_id, status, opts)
  end

  def terminal(run_id, status, opts \\ []) when status in @terminal do
    base(run_id, status, opts)
  end

  defp base(run_id, status, opts) do
    %{
      kind: :probe_run,
      run_id: run_id,
      probe: Keyword.get(opts, :probe, :c1_gate),
      status: status,
      charge: Keyword.get(opts, :charge),
      refs: Keyword.get(opts, :refs, []),
      fingerprint: Keyword.get(opts, :fingerprint),
      reason: Keyword.get(opts, :reason)
    }
  end

  def meta_result(run_id, opts \\ []) do
    %{
      kind: :meta_result,
      run_id: run_id,
      type: Keyword.get(opts, :type, :gate_decision),
      family: Keyword.get(opts, :family, :meta),
      source: Keyword.get(opts, :source, :probe_c1_gate),
      trust: Keyword.get(opts, :trust, :trusted),
      refs: Keyword.get(opts, :refs, [])
    }
  end

  def acct(run_id, kind, opts \\ []) when kind in [:reserve, :call, :settle] do
    %{
      kind: kind,
      run_id: run_id,
      estimate: Keyword.get(opts, :estimate),
      actual: Keyword.get(opts, :actual)
    }
  end

  def loop_event(label), do: %{kind: :loop, label: label}

  # ===========================================================================
  # checkers (pure folds over the event stream)
  # ===========================================================================

  @doc """
  P-U12.1 / N-U12.8 / N-U12.3 / N-U12.7 — lifecycle completeness. Per run_id:
  exactly one opening (`:started`|`:parked`) and exactly one terminal, and no
  event of any kind after the terminal. When `submitted` (the run_ids submit
  returned) is given, a submitted run with zero events is a silent drop.
  """
  def lifecycle_complete(events, submitted \\ nil) do
    with :ok <- not_dropped(events, submitted) do
      events
      |> Enum.filter(&(&1.kind == :probe_run))
      |> Enum.group_by(& &1.run_id)
      |> Enum.reduce_while(:ok, fn {run_id, evs}, :ok ->
        openings = Enum.count(evs, &(&1.status in @opening))
        terminals = Enum.count(evs, &(&1.status in @terminal))

        cond do
          openings != 1 or terminals != 1 ->
            {:halt, {:error, {:lifecycle, run_id, %{openings: openings, terminals: terminals}}}}

          post_terminal?(events, run_id) ->
            {:halt, {:error, {:post_terminal, run_id}}}

          true ->
            {:cont, :ok}
        end
      end)
    end
  end

  defp not_dropped(_events, nil), do: :ok

  defp not_dropped(events, submitted) do
    live = events |> Enum.map(&Map.get(&1, :run_id)) |> MapSet.new()

    case Enum.find(submitted, fn run_id -> not MapSet.member?(live, run_id) end) do
      nil -> :ok
      run_id -> {:error, {:dropped, run_id}}
    end
  end

  defp post_terminal?(events, run_id) do
    case terminal_seq(events, run_id) do
      nil ->
        false

      tseq ->
        Enum.any?(events, fn e -> Map.get(e, :run_id) == run_id and e.seq > tseq end)
    end
  end

  defp terminal_seq(events, run_id) do
    events
    |> Enum.filter(&(&1.kind == :probe_run and &1.run_id == run_id and &1.status in @terminal))
    |> Enum.map(& &1.seq)
    |> case do
      [] -> nil
      seqs -> Enum.min(seqs)
    end
  end

  @doc """
  P-U12.2 / N-U12.2 — reserve→call→settle order, per run. A `:call` with no
  prior open `:reserve`, or a `:settle` with no prior `:call`, fails.
  """
  def reserve_before_call(events) do
    events
    |> Enum.filter(&(&1.kind in [:reserve, :call, :settle]))
    |> Enum.group_by(& &1.run_id)
    |> Enum.reduce_while(:ok, fn {run_id, evs}, :ok ->
      kinds = evs |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.kind)

      case walk_order(kinds, :idle) do
        :ok -> {:cont, :ok}
        {:error, why} -> {:halt, {:error, {:bad_order, run_id, kinds, why}}}
      end
    end)
  end

  defp walk_order([], _state), do: :ok
  defp walk_order([:reserve | rest], :idle), do: walk_order(rest, :reserved)
  defp walk_order([:call | rest], :reserved), do: walk_order(rest, :called)
  defp walk_order([:settle | rest], :called), do: walk_order(rest, :idle)
  defp walk_order([:call | _], _), do: {:error, :call_without_reserve}
  defp walk_order([:settle | _], _), do: {:error, :settle_without_call}
  defp walk_order([:reserve | _], _), do: {:error, :reserve_over_open}

  @doc "Fail-closed: the provider was invoked exactly `expected` times."
  def fail_closed(provider_calls, expected) when is_integer(provider_calls) do
    if provider_calls == expected,
      do: :ok,
      else: {:error, {:provider_calls, provider_calls, expected}}
  end

  @doc "N-U12.4 — the Runner-owned leash held: no more than `max_calls` calls."
  def leash_enforced(provider_calls, max_calls) do
    if provider_calls <= max_calls,
      do: :ok,
      else: {:error, {:leash_exceeded, provider_calls, max_calls}}
  end

  @doc """
  P-U12.3 / N-U12.5 — every captured cache-riding prefix is byte-identical to
  the primary's. On divergence, names the first divergent byte offset.
  """
  def prefix_identity(captures, primary) do
    Enum.reduce_while(captures, :ok, fn %{run_id: run_id, prefix: prefix}, :ok ->
      if prefix == primary,
        do: {:cont, :ok},
        else:
          {:halt, {:error, {:prefix_divergence, first_divergent_offset(primary, prefix), run_id}}}
    end)
  end

  @doc "First byte offset at which `a` and `b` differ (or their common length)."
  def first_divergent_offset(a, b), do: divergent(a, b, 0)
  defp divergent(<<x, ra::binary>>, <<x, rb::binary>>, i), do: divergent(ra, rb, i + 1)
  defp divergent(_, _, i), do: i

  @doc "N-U12.1 — every emitted `meta_result` is `family: :meta`; a loop draft leaked otherwise."
  def family_isolation(events) do
    case Enum.find(events, &(&1.kind == :meta_result and &1.family != :meta)) do
      nil -> :ok
      e -> {:error, {:family_violation_emitted, e.run_id, e.family}}
    end
  end

  @doc """
  P-U12.5 / N-U12.6 — provenance stamping. Every `meta_result` carries
  `source == expected_source` and `trust == context.taint ⊓ refs-taint`. A run
  over tainted context (`ctx_taint == :tainted`) can produce NO trusted event.
  """
  def provenance_stamped(events, expected_source, ctx_taint, tainted_refs \\ []) do
    tainted = MapSet.new(tainted_refs)

    events
    |> Enum.filter(&(&1.kind == :meta_result))
    |> Enum.reduce_while(:ok, fn m, :ok ->
      expected_trust =
        if ctx_taint == :tainted or Enum.any?(m.refs, &MapSet.member?(tainted, &1)),
          do: :tainted,
          else: :trusted

      cond do
        m.source != expected_source ->
          {:halt, {:error, {:bad_source, m.run_id, m.source}}}

        m.trust != expected_trust ->
          {:halt, {:error, {:trust_not_absorbed, m.run_id, m.trust, expected_trust}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  @doc """
  P-U12.6 / N-U12.9 — output atomicity. A run whose terminal is non-happy
  (`:exhausted`/`:timeout`/`:killed`/`:error`) emitted ZERO `meta_result`s.
  """
  def output_atomic(events) do
    nonhappy_runs =
      for %{kind: :probe_run, run_id: run_id, status: s} <- events, s in @nonhappy, do: run_id

    Enum.reduce_while(Enum.uniq(nonhappy_runs), :ok, fn run_id, :ok ->
      k = Enum.count(events, &(&1.kind == :meta_result and &1.run_id == run_id))
      if k == 0, do: {:cont, :ok}, else: {:halt, {:error, {:partial_output, run_id, k}}}
    end)
  end

  @doc """
  N-U12.10 — bounded parking. The number of simultaneously-parked runs never
  exceeds `max_parked` (peak over the seq-ordered fold).
  """
  def bounded_parking(events, max_parked) do
    {_parked, peak} =
      events
      |> Enum.filter(&(&1.kind == :probe_run))
      |> Enum.sort_by(& &1.seq)
      |> Enum.reduce({MapSet.new(), 0}, fn e, {parked, peak} ->
        parked =
          cond do
            e.status == :parked -> MapSet.put(parked, e.run_id)
            e.status in @terminal -> MapSet.delete(parked, e.run_id)
            true -> parked
          end

        {parked, max(peak, MapSet.size(parked))}
      end)

    if peak <= max_parked, do: :ok, else: {:error, {:parked_overflow, peak, max_parked}}
  end

  @doc """
  OQ-U12.1 partial-failure rollback — budget conservation. After a
  session-then-run submit whose RUN-level reserve was refused, the SESSION-level
  budget must be back to `expected_reserved` (no leaked session reservation).
  """
  def budget_conserved(session_budget, expected_reserved) do
    got = reserved(session_budget)

    if got == expected_reserved,
      do: :ok,
      else: {:error, {:session_leaked, got, expected_reserved}}
  end

  @doc "Fingerprint REQUIRED on every probe_run terminal."
  def fingerprint_present(events) do
    events
    |> Enum.filter(&(&1.kind == :probe_run and &1.status in @terminal))
    |> Enum.find(&is_nil(&1.fingerprint))
    |> case do
      nil -> :ok
      t -> {:error, {:missing_fingerprint, t.run_id}}
    end
  end

  @doc "The primary-loop projection (labels in seq order) of a mixed stream."
  def loop_projection(events) do
    events |> Enum.filter(&(&1.kind == :loop)) |> Enum.sort_by(& &1.seq) |> Enum.map(& &1.label)
  end

  @doc "P-U12.4 — the primary loop trace is identical with or without probes."
  def loop_fold_independence(with_probes, baseline_labels) do
    got = loop_projection(with_probes)
    if got == baseline_labels, do: :ok, else: {:error, {:isolation_breach, got, baseline_labels}}
  end

  # ===========================================================================
  # fired counters (meta-invariant m1)
  # ===========================================================================

  @doc "A fresh fired-counter set."
  def new_fireset do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  @doc "Arm an injector site: it MUST fire before `assert_all_fired!/2`."
  def arm(fireset, site) do
    Agent.update(fireset, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    fireset
  end

  @doc "Record that an injector site fired (called by the injectors below)."
  def fire(fireset, site) do
    Agent.update(fireset, fn s -> %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))} end)
    :ok
  end

  @doc "Per-site fire counts."
  def fired(fireset), do: Agent.get(fireset, & &1.fired)

  @doc """
  meta-invariant m1: fail if any armed injector never fired (a dead injector =
  a green lie). `schedule` is dumped for seed reproduction (m2).
  """
  def assert_all_fired!(fireset, schedule \\ nil) do
    %{armed: armed, fired: fired} = Agent.get(fireset, & &1)
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

  # ===========================================================================
  # test probes — real `Raxol.Agent.Probe` implementations (compile-checked)
  # ===========================================================================

  defmodule CacheRideProbe do
    @moduledoc "A minimal single-call cache-riding probe (id :c1_gate)."
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c1_gate,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context) do
      {:ok,
       %{suffix: [%{role: "user", content: "gate?"}], output: :structured, max_output_tokens: 256}}
    end

    @impl true
    def interpret(_response, context) do
      {:ok, [%{type: :gate_decision, refs: [context.tip_offset], payload: %{choice: :allow}}]}
    end
  end

  defmodule ShortParkProbe do
    @moduledoc """
    A cache-riding probe with a SHORT `park_timeout_ms` (and small `max_parked`)
    so the bounded-parking / kill-on-parked contours run fast in CI instead of
    waiting the 10s production TTL (adversarial-review #8). Same `id` (`:c1_gate`)
    and behaviour as `CacheRideProbe`; only the parking knobs differ.
    """
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c1_gate,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 3,
        park_timeout_ms: 300
      }
    end

    @impl true
    def build(_context),
      do:
        {:ok,
         %{
           suffix: [%{role: "user", content: "gate?"}],
           output: :structured,
           max_output_tokens: 256
         }}

    @impl true
    def interpret(_response, context),
      do: {:ok, [%{type: :gate_decision, refs: [context.tip_offset], payload: %{choice: :allow}}]}
  end

  defmodule UnregisteredSourceProbe do
    @moduledoc """
    A probe whose id (`:notreal`) maps to `:probe_notreal` — an atom that IS
    interned (referenced below) but is NOT a registered provenance source. The
    Runner must stamp `:probe_unregistered`, never the bare interned atom
    (adversarial-review #10). Interning the atom here proves the membership check
    (not merely `String.to_existing_atom/1`) is what rejects it.
    """
    @behaviour Raxol.Agent.Probe

    # Force :probe_notreal to be interned so String.to_existing_atom/1 succeeds —
    # only the Meta.Registry membership check should then reject it.
    @interned :probe_notreal
    def interned_source, do: @interned

    @impl true
    def spec do
      %{
        id: :notreal,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context),
      do:
        {:ok,
         %{suffix: [%{role: "user", content: "x"}], output: :structured, max_output_tokens: 64}}

    @impl true
    def interpret(_response, context),
      do: {:ok, [%{type: :gate_decision, refs: [context.tip_offset], payload: %{choice: :allow}}]}
  end

  defmodule HangingProbe do
    @moduledoc """
    A probe whose `build/1` never returns — a hung provider/interpret call. The
    Runner's wall-clock `timeout_ms` leash (adversarial-review #2) must kill it
    and emit the `:timeout` terminal. `timeout_ms` is short so the leash fires
    fast in CI.
    """
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c1_gate,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 300,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context) do
      Process.sleep(:infinity)
      {:ok, %{suffix: [], output: :structured, max_output_tokens: 64}}
    end

    @impl true
    def interpret(_response, context),
      do: {:ok, [%{type: :gate_decision, refs: [context.tip_offset], payload: %{choice: :allow}}]}
  end

  defmodule MultiCallProbe do
    @moduledoc "A two-call probe (id :c2_rules) for max_calls/mid-run exhaustion."
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c2_rules,
        mode: :cache_riding,
        max_calls: 2,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context),
      do:
        {:ok,
         %{suffix: [%{role: "user", content: "rules?"}], output: :text, max_output_tokens: 128}}

    @impl true
    def interpret(_response, context),
      do: {:ok, [%{type: :extract, op: :add, item: "rule", refs: [context.tip_offset]}]}
  end

  defmodule LoopDraftProbe do
    @moduledoc "Drafts a `family: :loop` event — the N-U12.1 violation (rejected whole)."
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c1_gate,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context),
      do:
        {:ok,
         %{suffix: [%{role: "user", content: "x"}], output: :structured, max_output_tokens: 64}}

    @impl true
    def interpret(_response, _context),
      do: {:ok, [%{type: :turn_started, family: :loop, refs: []}]}
  end

  defmodule TaintedTrustProbe do
    @moduledoc "Drafts `trust: :trusted` — a probe cannot stamp provenance (N-U12.6)."
    @behaviour Raxol.Agent.Probe

    @impl true
    def spec do
      %{
        id: :c1_gate,
        mode: :cache_riding,
        max_calls: 1,
        timeout_ms: 5_000,
        default_budget: 500,
        max_parked: 4,
        park_timeout_ms: 10_000
      }
    end

    @impl true
    def build(_context),
      do:
        {:ok,
         %{suffix: [%{role: "user", content: "x"}], output: :structured, max_output_tokens: 64}}

    @impl true
    def interpret(_response, context),
      do: {:ok, [%{type: :gate_decision, trust: :trusted, refs: [context.tip_offset]}]}
  end

  # ===========================================================================
  # dead injectors (one mutation each; the negative controls, m4)
  #
  # Each is a WRONG Runner implementation producing an event stream. The matching
  # checker MUST flag it, proving the checker is not vacuous.
  # ===========================================================================

  defmodule FamilyCheckRemovedRunner do
    @moduledoc "N-U12.1: emits a probe-drafted `family: :loop` event instead of rejecting the whole result."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id) do
      L.fire(fs, :family_check_removed)
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.meta_result(run_id, family: :loop, source: :probe_c1_gate, trust: :trusted))

      L.emit(
        bus,
        L.terminal(run_id, :completed, fingerprint: L.fingerprint(), charge: L.charge())
      )
    end
  end

  defmodule SettleOnlyRunner do
    @moduledoc "N-U12.2: calls the provider with no prior reserve (post-hoc accounting)."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, provider: provider, fireset: fs}, run_id) do
      L.fire(fs, :settle_only)
      L.emit(bus, L.opening(run_id, :started))
      # VIOLATION: the call happens before any reserve.
      _ = L.provider_call(provider, run_id, %{prefix: L.primary_prefix(), suffix: []})
      L.emit(bus, L.acct(run_id, :call))
      L.emit(bus, L.acct(run_id, :settle, actual: 80))

      L.emit(
        bus,
        L.terminal(run_id, :completed, fingerprint: L.fingerprint(), charge: L.charge())
      )
    end
  end

  defmodule SilentDropRunner do
    @moduledoc "N-U12.3: submit returns ok but the run is silently dropped — nothing emitted."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{fireset: fs}, _run_id) do
      L.fire(fs, :silent_drop)
      :ok
    end
  end

  defmodule ProbeControlledLeashRunner do
    @moduledoc "N-U12.4: the leash lives inside the probe, so the Runner makes max_calls+1 calls."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, provider: provider, budget: budget, fireset: fs}, run_id, max_calls) do
      L.fire(fs, :probe_leash)
      L.emit(bus, L.opening(run_id, :started))

      for _ <- 1..(max_calls + 1) do
        _ = L.try_reserve(budget, 10)
        L.emit(bus, L.acct(run_id, :reserve, estimate: 10))
        _ = L.provider_call(provider, run_id, %{prefix: L.primary_prefix(), suffix: []})
        L.emit(bus, L.acct(run_id, :call))
        L.emit(bus, L.acct(run_id, :settle, actual: 10))
      end

      L.emit(
        bus,
        L.terminal(run_id, :exhausted,
          fingerprint: L.fingerprint(),
          charge: L.charge(calls: max_calls + 1)
        )
      )
    end
  end

  defmodule ReserializingPrefixRunner do
    @moduledoc "N-U12.5: rebuilds (re-serializes) the prefix instead of riding the captured bytes."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, provider: provider, fireset: fs}, run_id) do
      L.fire(fs, :reserialize_prefix)
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.acct(run_id, :reserve, estimate: 100))
      # VIOLATION: a re-serialized prefix, byte-divergent from the primary's.
      _ = L.provider_call(provider, run_id, %{prefix: L.reserialized_prefix(), suffix: []})
      L.emit(bus, L.acct(run_id, :call))
      L.emit(bus, L.acct(run_id, :settle, actual: 90))

      L.emit(
        bus,
        L.terminal(run_id, :completed, fingerprint: L.fingerprint(), charge: L.charge())
      )
    end
  end

  defmodule HonorsProbeTrustRunner do
    @moduledoc "N-U12.6: honors the probe-drafted `trust: :trusted` under a tainted context."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id) do
      L.fire(fs, :honors_probe_trust)
      L.emit(bus, L.opening(run_id, :started))
      # Context is tainted, but the Runner honors the probe's :trusted draft.
      L.emit(bus, L.meta_result(run_id, family: :meta, source: :probe_c1_gate, trust: :trusted))

      L.emit(
        bus,
        L.terminal(run_id, :completed, fingerprint: L.fingerprint(), charge: L.charge())
      )
    end
  end

  defmodule PostKillLeakRunner do
    @moduledoc "N-U12.7: leaks a drafted meta event AFTER the :killed terminal."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id) do
      L.fire(fs, :post_kill_leak)
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.terminal(run_id, :killed, fingerprint: L.fingerprint()))
      # VIOLATION: an in-flight interpret emit that outran the kill.
      L.emit(bus, L.meta_result(run_id, family: :meta, source: :probe_c1_gate, trust: :trusted))
    end
  end

  defmodule TerminalCountRunner do
    @moduledoc "N-U12.8: emits two terminals (:double) or none (:omit) for one run."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id, :double) do
      L.fire(fs, :terminal_count)
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.terminal(run_id, :completed, fingerprint: L.fingerprint()))
      # VIOLATION: a crash-recovery re-emit after an already-terminal run.
      L.emit(bus, L.terminal(run_id, :exhausted, fingerprint: L.fingerprint()))
    end

    def run(%{bus: bus, fireset: fs}, run_id, :omit) do
      L.fire(fs, :terminal_count)
      # VIOLATION: the process is freed without ever emitting a terminal.
      L.emit(bus, L.opening(run_id, :started))
    end
  end

  defmodule StreamingDraftsRunner do
    @moduledoc "N-U12.9: streams k drafted events, then hits exhaustion (not atomic)."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id, k) do
      L.fire(fs, :streaming_drafts)
      L.emit(bus, L.opening(run_id, :started))

      for _ <- 1..k,
          do: L.emit(bus, L.meta_result(run_id, source: :probe_c1_gate, trust: :trusted))

      # VIOLATION: the k drafts already left the building when exhaustion hit.
      L.emit(bus, L.terminal(run_id, :exhausted, fingerprint: L.fingerprint()))
    end
  end

  defmodule UnboundedParkingRunner do
    @moduledoc "N-U12.10: parks every run with no cap/TTL — the parked set grows past max_parked."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_ids) do
      L.fire(fs, :unbounded_parking)
      for run_id <- run_ids, do: L.emit(bus, L.opening(run_id, :parked))
    end
  end

  defmodule LoopPerturbingRunner do
    @moduledoc "Isolation breach: a probe crash perturbs the primary loop trace (P-U12.4)."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id, baseline_labels) do
      L.fire(fs, :loop_perturb)
      Enum.each(baseline_labels, fn label -> L.emit(bus, L.loop_event(label)) end)
      # VIOLATION: the crashing probe pushed an event into the primary trace.
      L.emit(bus, L.loop_event(:probe_injected))
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.terminal(run_id, :error, reason: :crash, fingerprint: L.fingerprint()))
    end
  end

  defmodule NoFingerprintRunner do
    @moduledoc "Terminal without the REQUIRED fingerprint."
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, fireset: fs}, run_id) do
      L.fire(fs, :no_fingerprint)
      L.emit(bus, L.opening(run_id, :started))
      L.emit(bus, L.terminal(run_id, :completed, fingerprint: nil))
    end
  end

  defmodule SessionLeakRunner do
    @moduledoc """
    OQ-U12.1 partial-failure rollback violation: reserves the SESSION level, then
    the RUN level is refused, but the session reservation is NOT released — a
    leaked session budget. Flagged by BUDGET-CONSERVED (the session fold does not
    return to its pre-submit value).
    """
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, session_budget: sb, budget: rb, fireset: fs}, run_id) do
      L.fire(fs, :session_leak)
      L.emit(bus, L.opening(run_id, :started))
      # Session reserve succeeds; the run-level reserve is refused (cap 0)...
      :ok = L.try_reserve(sb, 100)
      {:over, _} = L.try_reserve(rb, 100)
      # VIOLATION: the session reservation is NOT released before parking.
      L.emit(bus, L.opening(run_id, :parked))

      L.emit(
        bus,
        L.terminal(run_id, :exhausted, fingerprint: L.fingerprint(), charge: L.charge(calls: 0))
      )
    end
  end

  defmodule ReferenceRunner do
    @moduledoc """
    A faithful (well-formed) single-call cache-riding run — the "checkers are not
    vacuous" oracle. Every checker returns `:ok` against its output.
    """
    alias Raxol.Agent.Red.ProbeRunnerLab, as: L

    def run(%{bus: bus, provider: provider, budget: budget}, run_id, ctx_taint, tip) do
      L.emit(bus, L.opening(run_id, :started))
      _ = L.try_reserve(budget, 100)
      L.emit(bus, L.acct(run_id, :reserve, estimate: 100))
      _ = L.provider_call(provider, run_id, %{prefix: L.primary_prefix(), suffix: []})
      L.emit(bus, L.acct(run_id, :call))
      L.emit(bus, L.acct(run_id, :settle, actual: 90))

      L.emit(
        bus,
        L.meta_result(run_id,
          family: :meta,
          source: :probe_c1_gate,
          trust: ctx_taint,
          refs: [tip]
        )
      )

      L.emit(
        bus,
        L.terminal(run_id, :completed,
          fingerprint: L.fingerprint(),
          charge: L.charge(),
          refs: [tip]
        )
      )
    end
  end
end
