# T0 — D-PA resolver core (pure module, no CLI, no deps).
#
# Loaded by scripts/harness/t0/verdict_resolver.exs (the CLI) and by
# scripts/harness/t0/test/resolver_test.exs (the discrimination fixture
# suite). Implements 01-t0-matrix.md §7.2 (D-PA) and §7.4 (GO gate)
# mechanically, with the soundness rules from the T0 review round — each
# locked by a fixture in test/resolver_fixtures/:
#
#   1. MEASURED = has a coherent, ground-truth C2 measurement AND a C1
#      measurement. A tier-1 terminal present only via non-C2 rows is NOT
#      measured — counting it inflated `measured` and let the (B)/(A)
#      computation range over a smaller C2 set than the terminals it
#      claimed to speak for (repro: kitty C2=fed + wezterm C4-only used
#      to yield "B" with wezterm's keystone never measured).
#   2. C1∧C2 JOIN — a terminal's C2=fed only counts as fed if its C1
#      (footer pinned) also passed. A DECSTBM-ignoring full-screen
#      scroller feeds scrollback beautifully while corrupting the footer;
#      "fed" without a pinned footer is not the inline-hybrid thesis.
#   3. PROVENANCE — a context=plain row captured via a proxy method
#      (tmux_capture measures tmux's emulator, not the host) is not
#      tier-1 ground truth and is excluded (counted in
#      `proxy_rows_excluded`). Ground truth for plain context is
#      native_gettext | pty_tee | human_eye. Note: Ghostty has no native
#      get-text API (as of 2026), so its plain-context cells legitimately
#      reach ground truth only via human_eye (screenshot + scroll-back) —
#      it STAYS partial/human-verified until someone does that pass;
#      its tmux_capture rows belong under context=tmux, not plain.
#   4. COHERENCE — for the decision claims (C1..C4) a row's `verdict` and
#      its observable status must agree; a row with verdict:"fed" but
#      observable:"lost" (either direction) is malformed: excluded from
#      every computation and reported in the `malformed` output field.
#      Never filter on one field and decide on the other.
#   5. TRANSPORT AGGREGATION — a terminal with multiple C2 rows (e.g.
#      local + ssh) aggregates conservatively: any `lost` → the terminal
#      counts lost; all `fed` → fed; anything else → partial. C1/C3: any
#      fail → fail. C4: any ghost/flood → bad. Tail window: the MINIMUM
#      across fed rows (the bounded depth must hold on every transport).
#   6. TWO-TERMINAL FLOOR — even a *provisional* D-PA is only shown when
#      >= 2 distinct tier-1 terminals are measured; a single terminal's
#      evidence yields dpa="pending" with provisional=nil, structurally.
#      The DEFINITIVE verdict additionally requires all four tier-1
#      terminals measured (§7.2 quantifies over "every tier-1 cell").
#   7. NULL-OBSERVABLE = UNMEASURED — a C1..C4 row whose observable
#      carries no status contributes nothing (pending-side), and is
#      never read as a lost/fail signal.
#
# Plus §7.2's second conjunct modeled explicitly: (B) soft-owned history
# requires a NON-ZERO sealed-rows-on-screen tail window measured by the
# C2/P-02 cell (`tail_window_rows`, either a top-level row field or a key
# inside a map-shaped C2 observable: {"status":"fed","tail_window_rows":21}).
# All-fed without tail-window evidence falls to (A), never (B).
#
# Idempotence/permutation invariance: the resolver's output is identical
# under row reordering and row duplication (grouping + all/any-quantifier
# aggregation + sorted/deduped report lists) — pinned by the fixture suite.

defmodule T0.VerdictResolver do
  @moduledoc """
  Pure resolver: CellResult matrix (decoded `t0-verdict.json` `matrix`)
  -> D-PA recommendation + §7.4 GO gate. See file header for the
  soundness rules; see `test/resolver_test.exs` for the fixtures that
  pin them.
  """

  @tier1 ~w(kitty iterm2 wezterm ghostty)
  @plain_ground_truth ~w(native_gettext pty_tee human_eye)
  @decision_claims ~w(C1 C2 C3 C4)

  def tier1, do: @tier1

  @doc """
  Returns a map (all values JSON-encodable; dpa/go are strings):

      %{
        dpa: "A" | "B" | "C" | "pending",
        reason: String.t(),
        go: "go" | "no_go" | "partial",
        go_reason: String.t(),
        tier1_terminals_measured: [String.t()],
        tier1_terminals_missing: [String.t()],
        proxy_rows_excluded: non_neg_integer(),
        malformed: [String.t()],
        provisional: nil | %{dpa: String.t(), based_on: [String.t()]}
      }

  Total: never raises on malformed rows — non-map entries are ignored,
  incoherent rows go to `malformed`, unmeasured observables contribute
  nothing.
  """
  def resolve(matrix) when is_list(matrix) do
    tier1_plain =
      matrix
      |> Enum.filter(&is_map/1)
      |> Enum.filter(fn r ->
        r["terminal"] in @tier1 and r["context"] == "plain" and
          not is_nil(r["verdict"])
      end)

    {ground, proxy} =
      Enum.split_with(tier1_plain, fn r ->
        r["capture"] in @plain_ground_truth
      end)

    {coherent, malformed} = check_coherence(ground)

    by_term = Enum.group_by(coherent, & &1["terminal"])
    agg = Map.new(@tier1, fn t -> {t, aggregate(Map.get(by_term, t, []))} end)

    measured =
      Enum.filter(@tier1, fn t ->
        agg[t].c2 != :unmeasured and agg[t].c1 != :unmeasured
      end)

    missing = @tier1 -- measured

    %{go: go, go_reason: go_reason} = compute_go(agg)
    dpa_fields = compute_dpa(agg, measured, missing)

    Map.merge(dpa_fields, %{
      go: go,
      go_reason: go_reason,
      tier1_terminals_measured: Enum.sort(measured),
      tier1_terminals_missing: missing,
      proxy_rows_excluded: length(proxy),
      malformed: malformed
    })
  end

  # --- coherence (rule 4) ---------------------------------------------------

  defp check_coherence(rows) do
    {ok, bad} =
      Enum.reduce(rows, {[], []}, fn r, {ok, bad} ->
        if r["claim"] in @decision_claims do
          case status_of(r) do
            nil ->
              # unmeasured (rule 7): kept, but carries no status —
              # aggregation will skip it.
              {[r | ok], bad}

            s ->
              if s == r["verdict"] do
                {[r | ok], bad}
              else
                {ok,
                 [
                   "#{r["terminal"]}/#{r["context"]}/#{r["transport"]}/#{r["claim"]}: " <>
                     "verdict=#{inspect(r["verdict"])} vs observable status=#{inspect(s)} disagree"
                   | bad
                 ]}
              end
          end
        else
          {[r | ok], bad}
        end
      end)

    {Enum.reverse(ok), bad |> Enum.uniq() |> Enum.sort()}
  end

  # --- observable accessors ---------------------------------------------------

  defp status_of(row) do
    case row["observable"] do
      s when is_binary(s) -> s
      %{"status" => s} when is_binary(s) -> s
      _ -> nil
    end
  end

  defp tail_window(row) do
    case {row["tail_window_rows"], row["observable"]} do
      {n, _} when is_integer(n) -> n
      {_, %{"tail_window_rows" => n}} when is_integer(n) -> n
      _ -> 0
    end
  end

  # --- per-terminal aggregation (rule 5) ---------------------------------------

  defp aggregate(rows) do
    %{
      c1: agg_pass(rows, "C1"),
      c3: agg_pass(rows, "C3"),
      c2: agg_c2(rows),
      c4: agg_c4(rows)
    }
  end

  defp measured_statuses(rows, claim) do
    rows
    |> Enum.filter(&(&1["claim"] == claim))
    |> Enum.map(&status_of/1)
    |> Enum.reject(&is_nil/1)
  end

  defp agg_pass(rows, claim) do
    case measured_statuses(rows, claim) do
      [] -> :unmeasured
      ss -> if Enum.all?(ss, &(&1 == "pass")), do: :pass, else: :fail
    end
  end

  defp agg_c2(rows) do
    c2_rows =
      rows
      |> Enum.filter(&(&1["claim"] == "C2"))
      |> Enum.filter(&(status_of(&1) != nil))

    case c2_rows do
      [] ->
        :unmeasured

      rs ->
        ss = Enum.map(rs, &status_of/1)

        cond do
          "lost" in ss ->
            :lost

          Enum.all?(ss, &(&1 == "fed")) ->
            {:fed, rs |> Enum.map(&tail_window/1) |> Enum.min()}

          true ->
            :partial
        end
    end
  end

  defp agg_c4(rows) do
    case measured_statuses(rows, "C4") do
      [] ->
        :unmeasured

      ss ->
        if Enum.all?(ss, &(&1 in ["reflow", "freeze_clean"])),
          do: :ok,
          else: :bad
    end
  end

  # The C1∧C2 join (rule 2): fed only counts with a pinned footer.
  defp fed?(agg_t), do: agg_t.c1 == :pass and match?({:fed, _}, agg_t.c2)

  # §7.2 second conjunct: survivable resize AND a measured non-zero tail window.
  defp tail_ok?(agg_t) do
    agg_t.c4 == :ok and match?({:fed, w} when w > 0, agg_t.c2)
  end

  # --- §7.4 GO gate ---------------------------------------------------------------

  defp compute_go(agg) do
    failures =
      @tier1
      |> Enum.flat_map(fn t ->
        a = agg[t]

        [
          if(a.c1 == :fail, do: "#{t}: C1 failed (footer_not_pinned)"),
          if(a.c3 == :fail, do: "#{t}: C3 failed (cursor protocol)"),
          if(a.c2 == :lost, do: "#{t}: C2 == lost (scrollback not fed)")
        ]
        |> Enum.reject(&is_nil/1)
      end)
      |> Enum.sort()

    complete? =
      Enum.all?(@tier1, fn t ->
        a = agg[t]
        a.c1 == :pass and a.c3 == :pass and fed?(a)
      end)

    cond do
      failures != [] ->
        %{
          go: "no_go",
          go_reason:
            "§7.4 NO-GO: " <>
              Enum.join(failures, "; ") <>
              " -- flat/tmux_conservative become primary per the roadmap's fallback triggers."
        }

      complete? ->
        %{
          go: "go",
          go_reason:
            "§7.4 GO: all tier-1 terminals pass C1+C3 and C2==fed (C1-joined, " <>
              "transport-aggregated), no footer_not_pinned trigger."
        }

      true ->
        %{
          go: "partial",
          go_reason:
            "incomplete tier-1 evidence (no disqualifying failure observed yet); " <>
              "GO cannot be declared until every tier-1 terminal has ground-truth C1+C2+C3 rows."
        }
    end
  end

  # --- §7.2 D-PA ------------------------------------------------------------------

  defp compute_dpa(agg, measured, missing) do
    cond do
      # Two-terminal floor (rule 6): with fewer than 2 measured terminals
      # even a provisional D-PA is refused structurally.
      length(measured) < 2 ->
        %{
          dpa: "pending",
          reason:
            "fewer than 2 tier-1 terminals have ground-truth C1+C2 measurements " <>
              "(measured: #{format_list(measured)}; missing: #{format_list(missing)}) -- " <>
              "the two-terminal floor refuses even a provisional D-PA from a single " <>
              "terminal's evidence. Run Ring B per docs/proposals/t0-runbook.md.",
          provisional: nil
        }

      missing == [] ->
        {dpa, why} = dpa_over(agg, @tier1)

        %{
          dpa: dpa,
          reason:
            "all tier-1 terminals measured (#{Enum.join(@tier1, ", ")}): " <>
              why,
          provisional: nil
        }

      true ->
        {dpa, why} = dpa_over(agg, measured)

        %{
          dpa: "pending",
          reason:
            "tier-1 set incomplete (missing: #{Enum.join(missing, ", ")}) -- D-PA stays " <>
              "pending; the measured subset (#{Enum.join(Enum.sort(measured), ", ")}) " <>
              "provisionally suggests (#{dpa}): #{why}",
          provisional: %{dpa: dpa, based_on: Enum.sort(measured)}
        }
    end
  end

  defp dpa_over(agg, terminals) do
    all_fed? = Enum.all?(terminals, fn t -> fed?(agg[t]) end)
    tail_ok? = Enum.all?(terminals, fn t -> tail_ok?(agg[t]) end)

    cond do
      not all_fed? ->
        {"C",
         "at least one measured terminal has C2 != fed (or C2=fed without C1 pass -- " <>
           "the join) -- live-region-only; history is terminal-owned."}

      tail_ok? ->
        {"B",
         "every measured terminal: C2=fed (C1-joined), C4 in {reflow,freeze_clean}, and a " <>
           "non-zero sealed-rows tail window measured -- soft-owned history, visible tail only."}

      true ->
        {"A",
         "every measured terminal: C2=fed (C1-joined), but resize (C4) and/or the non-zero " <>
           "tail-window conjunct is not established -- seal-time-only."}
    end
  end

  defp format_list([]), do: "none"
  defp format_list(l), do: Enum.join(Enum.sort(l), ", ")
end
