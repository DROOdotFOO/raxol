defmodule Raxol.Agent.Red.MetaJournalGen do
  @moduledoc """
  Seeded journal generators for the U11-R red suite.

  Every generator is **seed-reproducible** (meta-invariant m2) — pass an integer
  seed, get the same journal — and each one is written to GUARANTEE the required
  non-vacuity pattern the freeze demands (meta-invariant m5): taint chains ≥3
  deep, speculation begins with ≥2 parents, journals that mix loop + meta
  events, actor write-generations that mix present + absent actors. A generator
  that failed to produce its pattern would make the property vacuous, so each
  returns the pattern facts alongside the records for an explicit assertion.

  Records are string-keyed maps exactly as `Raxol.Agent.Journal.FileStore.Reader`
  returns them (so a red may either fold them directly or seed a real journal
  and read them back).
  """

  @session "red-u11-sess"

  @doc "A fresh seed (varies per run); dump it in every failure message."
  def fresh_seed, do: System.unique_integer([:positive])

  @doc "Deterministic pseudo-random integer stream from a seed."
  def rng(seed), do: :rand.seed_s(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})

  # ===========================================================================
  # Record builder
  # ===========================================================================

  @doc false
  def rec(id, family, type, payload, opts \\ []) do
    %{
      "id" => id,
      "schema_version" => "1.0.0",
      "kind" => Keyword.get(opts, :kind, "event"),
      "v" => 0,
      "session_id" => @session,
      "turn_id" => Keyword.get(opts, :turn_id),
      "ts" => id,
      "family" => Atom.to_string(family),
      "type" => Atom.to_string(type),
      "tier" => "durable",
      "payload" => stringify(payload),
      "scope" => Keyword.get(opts, :scope, "session") |> to_string(),
      "provenance" => %{
        "source" => Keyword.get(opts, :source, "primary") |> to_string(),
        "trust" => Keyword.get(opts, :trust, "trusted") |> to_string()
      },
      "actor" => Keyword.get(opts, :actor)
    }
  end

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other

  # ===========================================================================
  # P-U11.3 — taint monotonicity: a chain ≥ `depth` deep (tainted-absorbing)
  # ===========================================================================

  @doc """
  A journal whose taint propagates through a chain of length `depth` (≥3):
  `tool_result(:tainted) → extract → promote-draft → …`. Every meta link stores
  the CORRECT derived trust (`:tainted`), so it is a consistent journal. A few
  trusted meta events are interleaved so the property is not "everything tainted".

  Returns `%{records, tainted_offsets, trusted_offsets, depth}`.
  """
  def tainted_chain(seed, opts \\ []) do
    depth = max(Keyword.get(opts, :depth, 3), 3)
    _ = seed

    # offset 1: tainted tool_result (the entry point).
    entry =
      rec(
        1,
        :loop,
        :tool_result,
        %{name: "fetch", result: "<<untrusted>>", refs: []},
        trust: "tainted"
      )

    # offsets 2..depth: meta links, each refs the previous, each stored :tainted.
    chain_types =
      Stream.cycle([:extract, :residual, :promote]) |> Enum.take(depth - 1)

    {chain, _} =
      Enum.map_reduce(chain_types, 1, fn t, prev ->
        id = prev + 1
        payload = meta_payload(t, [prev])
        scope = if t == :promote, do: "global", else: "session"

        {rec(id, :meta, t, payload,
           trust: "tainted",
           scope: scope,
           source: "probe_c2_rules"
         ), id}
      end)

    tainted_offsets = for r <- chain, do: r["id"]

    # A parallel trusted meta chain off a trusted loop event, so not-all-tainted.
    trusted_loop =
      rec(depth + 1, :loop, :item_completed, %{
        item_type: "message",
        content: "ok",
        refs: []
      })

    trusted_meta =
      rec(depth + 2, :meta, :extract, meta_payload(:extract, [depth + 1]), trust: "trusted")

    records = [entry | chain] ++ [trusted_loop, trusted_meta]

    %{
      records: records,
      tainted_offsets: tainted_offsets,
      trusted_offsets: [trusted_meta["id"]],
      depth: depth
    }
  end

  # ===========================================================================
  # Exponential-fold regression — Fibonacci-shaped multi-parent ref DAG
  # ===========================================================================

  @doc """
  A Fibonacci-shaped multi-parent ref DAG: two loop leaves (offsets 1 and 2,
  both stored `leaf_trust`), then `depth` chained meta `speculation` events
  where event `n` refs `[n-1, n-2]` — the plural-parent shape the freeze
  REQUIRES (N-U11.10 / P-U11.8), so this journal is legitimate, not exotic.
  Every meta record stores the correct derived trust (all `leaf_trust`), so
  the journal is consistent (`taint_violations/1` must be `[]`).

  Without cross-branch memoization the taint fold over this shape recurses
  `T(n) = T(n-1) + T(n-2)` — exponential. The worst case is `leaf_trust:
  :trusted` (the tainted-absorbing `any?` cannot short-circuit, so every
  branch is explored): measured ~4.4s at depth 32, ~x2.6 per +2 depth —
  minutes at depth 40. The tainted variant short-circuits pre-fix and pins
  correctness rather than the blow-up.

  Returns `%{records, meta_offsets, leaf_trust}`.
  """
  def fibonacci_dag(depth, opts \\ []) when depth >= 2 do
    leaf_trust = Keyword.get(opts, :leaf_trust, :trusted)
    trust = to_string(leaf_trust)

    leaves =
      for id <- [1, 2] do
        rec(
          id,
          :loop,
          :tool_result,
          %{name: "fetch", result: "r#{id}", refs: []},
          trust: trust
        )
      end

    metas =
      for id <- 3..(depth + 2) do
        rec(
          id,
          :meta,
          :speculation,
          meta_payload(:speculation, [id - 1, id - 2]),
          trust: trust
        )
      end

    %{
      records: leaves ++ metas,
      meta_offsets: Enum.to_list(3..(depth + 2)),
      leaf_trust: leaf_trust
    }
  end

  # ===========================================================================
  # OQ-U11.3 — a hand-crafted taint violation (stored :trusted, tainted ref)
  # ===========================================================================

  @doc """
  A journal with exactly one taint VIOLATION: a meta event storing
  `trust: :trusted` while one of its `refs` is tainted. Replay must stay
  `{:ok, _}`; the violation surfaces only as a fold marker (never damage).

  Returns `%{records, violated_offset, tainted_ref}`.
  """
  def violated_journal(seed) do
    _ = seed

    entry =
      rec(
        1,
        :loop,
        :tool_result,
        %{name: "fetch", result: "<<untrusted>>", refs: []},
        trust: "tainted"
      )

    # offset 2 refs the tainted entry but LIES that it is trusted.
    liar =
      rec(2, :meta, :extract, meta_payload(:extract, [1]), trust: "trusted")

    tail =
      rec(3, :loop, :item_completed, %{
        item_type: "message",
        content: "x",
        refs: []
      })

    %{records: [entry, liar, tail], violated_offset: 2, tainted_ref: 1}
  end

  # ===========================================================================
  # P-U11.5 — interleaved loop + meta (fold independence)
  # ===========================================================================

  @doc """
  A journal interleaving loop and meta events. Returns `%{records, stripped}`
  where `stripped` is the same journal with every `family: :meta` record removed
  (offsets are NOT renumbered — a fold must be position-stable, not id-dense).
  """
  def interleaved(seed) do
    st = rng(seed)

    {records, _} =
      Enum.map_reduce(1..8, st, fn id, st ->
        {roll, st} = :rand.uniform_s(2, st)

        rec =
          if rem(roll, 2) == 0 do
            rec(id, :meta, :research, meta_payload(:research, [max(id - 1, 1)]),
              source: "probe_c5"
            )
          else
            rec(id, :loop, :item_completed, %{
              item_type: "message",
              content: "m#{id}",
              refs: []
            })
          end

        {rec, st}
      end)

    # Guarantee the pattern is non-vacuous: at least one of each family.
    records = ensure_both_families(records)
    stripped = Enum.reject(records, fn r -> r["family"] == "meta" end)
    %{records: records, stripped: stripped}
  end

  defp ensure_both_families(records) do
    has_loop? = Enum.any?(records, &(&1["family"] == "loop"))
    has_meta? = Enum.any?(records, &(&1["family"] == "meta"))

    records
    |> then(fn rs ->
      if has_loop?,
        do: rs,
        else:
          List.replace_at(
            rs,
            0,
            rec(1, :loop, :item_completed, %{
              item_type: "message",
              content: "seed",
              refs: []
            })
          )
    end)
    |> then(fn rs ->
      if has_meta?,
        do: rs,
        else:
          List.replace_at(
            rs,
            -1,
            rec(length(rs), :meta, :research, meta_payload(:research, [1]), source: "probe_c5")
          )
    end)
  end

  # ===========================================================================
  # P-U11.6 — actor write-generations (present + absent → system)
  # ===========================================================================

  @doc """
  A journal spanning ≥2 write generations. Generation A carries a human actor,
  generation B carries an agent actor, generation C carries NO actor (absent →
  folds to `%{kind: :system}` by rule). Returns `%{records, expected_actors}`
  where `expected_actors` is recomputed from the generation context — an
  independent oracle, not the stamped field.
  """
  def actor_generations(seed) do
    _ = seed

    gens = [
      {[1, 2], %{"kind" => "human", "id" => "u-42"}, %{kind: :human, id: "u-42"}},
      {[3, 4], %{"kind" => "agent", "id" => "agent-7"}, %{kind: :agent, id: "agent-7"}},
      # Absent actor generation — stamped nil, expected system by rule.
      {[5, 6], nil, %{kind: :system}}
    ]

    records =
      for {ids, stamped, _expected} <- gens, id <- ids do
        turn = "turn-gen-#{hd(ids)}"

        rec(
          id,
          :loop,
          :item_completed,
          %{item_type: "message", content: "g#{id}", refs: []},
          turn_id: turn,
          actor: stamped
        )
      end

    expected =
      for {ids, _stamped, expected} <- gens,
          id <- ids,
          into: %{},
          do: {id, expected}

    %{records: records, expected_actors: expected}
  end

  # ===========================================================================
  # P-U11.7 — fingerprint precedence (head X, turn override Y, item Z)
  # ===========================================================================

  @doc """
  A journal with three DISTINCT fingerprints: the session head config (X, "what
  the session defaults to"), a `turn_started` override (Y, "what was asked"), and
  an `item_completed` fingerprint (Z, "what produced this content"). Returns
  `%{records, item_offset, x, y, z}` with `x != y != z`; the fingerprints are
  returned in the Reader-shaped (string-keyed) form the records carry, so folds
  compare like-for-like.
  """
  def fingerprint_precedence(seed) do
    _ = seed
    x = fp("head-provider", "model-x", "hash-x")
    y = fp("turn-provider", "model-y", "hash-y")
    z = fp("item-provider", "model-z", "hash-z")

    head = rec(1, :loop, :head_config, %{fingerprint: x, refs: []})

    started =
      rec(
        2,
        :loop,
        :turn_started,
        %{prompt: "p", fingerprint_override: y, refs: []},
        turn_id: "t1"
      )

    item =
      rec(
        3,
        :loop,
        :item_completed,
        %{item_type: "message", content: "answer", fingerprint: z, refs: []},
        turn_id: "t1"
      )

    %{
      records: [head, started, item],
      item_offset: 3,
      x: stringify(x),
      y: stringify(y),
      z: stringify(z)
    }
  end

  defp fp(provider, name, hash) do
    %{
      provider: provider,
      name: name,
      revision: nil,
      params_hash: hash,
      params_inline: %{temperature: 0.7, top_p: 1.0, max_tokens: 256, seed: 11},
      prompt_cache_key: nil
    }
  end

  # ===========================================================================
  # P-U11.8 — speculation with ≥2 in-session parents (plural refs)
  # ===========================================================================

  @doc """
  A `speculation{phase: :begin}` naming `n` (≥2) in-session parent tip offsets in
  `refs`. Returns `%{event, record, parents}` — `event` is the atom-keyed emit
  form for `validate/1`, `record` the string-keyed journal form.
  """
  def speculation_plural(seed, opts \\ []) do
    _ = seed
    n = max(Keyword.get(opts, :parents, 2), 2)
    parents = Enum.to_list(1..n)

    payload = %{
      phase: :begin,
      branch_ref: "branch-spec-1",
      outcome: nil,
      refs: parents
    }

    event = %{
      family: :meta,
      type: :speculation,
      payload: payload,
      scope: :session
    }

    record = rec(n + 1, :meta, :speculation, payload, source: "primary")
    %{event: event, record: record, parents: parents}
  end

  # ===========================================================================
  # Registry coverage — one valid event per registry meta type (codec / scope)
  # ===========================================================================

  @doc """
  One well-formed, valid event per registry meta type (atom-keyed emit form +
  string-keyed record form), for the codec round-trip and scope-discipline reds.
  Returns `[%{type, event, record}]`.
  """
  def one_per_type(seed) do
    _ = seed

    for {type, _entry} <- Raxol.Agent.Meta.Registry.types() do
      payload = meta_payload(type, [1])
      scope = Raxol.Agent.Meta.Registry.scope(type)
      event = %{family: :meta, type: type, payload: payload, scope: scope}
      record = rec(1, :meta, type, payload, scope: scope)
      %{type: type, event: event, record: record}
    end
  end

  # ===========================================================================
  # Payload skeletons (every required key present; grow-only values)
  # ===========================================================================

  @doc "A valid payload for `type` with the given `refs`."
  def meta_payload(:gate_decision, refs),
    do: %{
      gate: :c1,
      score: 0.9,
      threshold: 0.5,
      choice: :proceed,
      seed: 7,
      refs: refs
    }

  def meta_payload(:extract, refs),
    do: %{class: :fact, op: :add, item: %{k: "v"}, refs: refs}

  def meta_payload(:residual, refs), do: %{description: "unknown-x", refs: refs}

  def meta_payload(:calibrate, refs),
    do: %{
      gate: :c1,
      observed_score: 0.4,
      quantile: 0.9,
      new_threshold: 0.45,
      refs: refs
    }

  def meta_payload(:verdict, refs),
    do: %{family: :drift, drift_score: 0.2, advice: "hold", refs: refs}

  def meta_payload(:research, refs), do: %{conclusion: "c", refs: refs}

  # promote requires refs != [] — never hand it an empty list here.
  def meta_payload(:promote, refs),
    do: %{
      item: %{k: "v"},
      justification: "j",
      refs: if(refs == [], do: [1], else: refs)
    }

  def meta_payload(:probe_run, refs),
    do: %{
      probe: :c1_gate,
      run_id: "run-1",
      status: :completed,
      charge: %{
        prompt_tokens: 1,
        cached_prompt_tokens: 0,
        completion_tokens: 1,
        calls: 1
      },
      refs: refs
    }

  def meta_payload(:attach, refs),
    do: %{
      from_offset: 0,
      history_policy: :full,
      surface: :surface_tui,
      refs: refs
    }

  def meta_payload(:speculation, refs),
    do: %{
      phase: :begin,
      branch_ref: "b1",
      outcome: nil,
      refs: if(refs == [], do: [1], else: refs)
    }

  def meta_payload(:approval_decided, refs),
    do: %{request_ref: 1, decision: :approved, refs: refs}

  def meta_payload(:policy_amended, refs),
    do: %{
      scope: :session,
      rule_id: "r1",
      before: %{},
      after: %{x: 1},
      source: :human,
      refs: refs
    }
end
