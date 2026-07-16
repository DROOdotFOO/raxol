# U8-R — permanent failing-first red suite for BlastRadiusGate + approvals
# (AD-6b / AD-14), authored against the ratified freeze contracts
# (docs/proposals/in-flight/harness-freeze-contracts.md §1.1 / §2.1 / §5.2 and
# harness-yolo-safe-research.md §2/§5/§7) BEFORE any implementation exists.
#
# Two modules, one file, by design:
#
#   * `U8BlastRadiusRedTest` (GRADUATED — carries only `@moduletag :capture_log`,
#     runs untagged in CI) — the contours, run against the now-implemented
#     `Raxol.Agent.Authorization.BlastRadiusGate`. They were authored RED and
#     turned green IN PLACE when U8 landed; no assertion changed.
#   * `U8BlastRadiusControlsTest` (untagged — runs in CI every push) — proves
#     the contours have teeth: the correct ReferenceGate passes every contour
#     (discrimination / non-vacuity), and every dead injector fails its contour
#     with the exact violation signature (negative controls, meta-inv m4), with
#     fired-counters over all injector sites (meta-inv m1) and seed-reported
#     schedules (meta-inv m2).

defmodule Raxol.Agent.Red.U8BlastRadiusRedTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # U8-R has GRADUATED: U8 implemented `Raxol.Agent.Authorization.BlastRadiusGate`
  # (BlastRadiusGate + approvals + decision-time taint fold, AD-6b/AD-14), so all
  # contours — including the §5.2 predicate table (C8/C9) — now run untagged and
  # GREEN in CI. The predicate reads a structural `effect_class` field supplied
  # directly by the call map, so it needs no F2 `Raxol.Action` draft to exercise.
  @moduletag :capture_log

  # Fixed, reproducible fold-rebuild schedules (meta-inv m2); keep in sync with
  # the controls module below.
  @seeds [11, 23, 37, 58, 71]

  alias Raxol.Agent.Authorization.BlastRadiusGate
  alias Raxol.Agent.Red.U8Gates.Contours

  describe "U8-R positive contours (RED until U8 lands)" do
    test "C1 — locked by default: a write tool without approval is a typed reject and the side effect never runs" do
      assert :ok = Contours.locked_by_default(BlastRadiusGate)
    end

    test "C2 — escalation emits approval_requested as family :loop (frozen F3) and it is the tip when trailing" do
      assert :ok =
               Contours.escalation_emits_tip_eligible_request(BlastRadiusGate)
    end

    test "C3 — approval_decided :approved with refs to the request unlocks exactly that request (scope :once)" do
      assert :ok = Contours.approve_once_unlocks(BlastRadiusGate)
    end

    test "C4 — deny is durable: a post-deny retry without a NEW approval cycle never succeeds" do
      assert :ok = Contours.deny_is_durable(BlastRadiusGate)
    end

    test "C5 — :session scope persists across calls within the session" do
      assert :ok = Contours.session_scope_persists(BlastRadiusGate)
    end

    test "C6 — fold-rebuild: approval state folded from approval_decided events equals live state (replay law)" do
      for seed <- @seeds do
        assert :ok = Contours.fold_rebuild_equals_live(BlastRadiusGate, seed),
               "rebuild diverged from live enforcement under seed #{seed}"
      end
    end

    test "C7 — a forged/dangling approval_decided (refs match no live request) is rejected" do
      assert :ok = Contours.forged_decision_rejected(BlastRadiusGate)
    end

    test "C10 — taint is a FOLD over refs: a :trusted-STAMPED arg over a tainted chain escalates (HIGH-1, FI-5)" do
      assert :ok = Contours.taint_escalates(BlastRadiusGate)
    end

    test "C11 — request_ref is injective + string-canonical: a STRING tool and a ':'-bearing tool/call_id round-trip and rebuild == live (Fix 1)" do
      assert :ok = Contours.ref_roundtrips_string_and_colon(BlastRadiusGate)
    end

    test "C12 — a :once grant unlocks exactly that request: (tool_a, cid) does not admit (tool_b, cid), and a tainted (tool_b, cid) still escalates (Fix 2)" do
      assert :ok = Contours.once_grant_is_request_scoped(BlastRadiusGate)
    end

    test "C13 — a consumed :once grant is reconstructed as consumed: rebuild does not resurrect a spent grant (Fix 3)" do
      assert :ok = Contours.once_consumption_survives_rebuild(BlastRadiusGate)
    end

    test "C14 — the §5.2 predicate fails closed: an unknown effect_class and a non-boolean egress both escalate (Fix 4)" do
      assert :ok = Contours.escalate_predicate_fails_closed(BlastRadiusGate)
    end

    test "C15 — the taint fold fails closed: an unknown-trust leaf and a malformed lineage entry both escalate (Fix 5)" do
      assert :ok = Contours.taint_fold_fails_closed(BlastRadiusGate)
    end
  end

  describe "U8-R predicate contours (§5.2 — runs green in CI)" do
    test "C8 — escalate iff effect_class == :irreversible_external OR egress == true (§5.2 normative)" do
      assert :ok = Contours.escalate_predicate(BlastRadiusGate)
    end

    test "C9 — :reversible_local + no egress + trusted auto-proceeds; a self-reported destructiveHint never gates" do
      assert :ok = Contours.predicate_ignores_destructive_hint(BlastRadiusGate)
    end
  end
end

defmodule Raxol.Agent.Red.U8BlastRadiusControlsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  @moduletag :capture_log

  @seeds [11, 23, 37, 58, 71]

  alias Raxol.Agent.Red.U8Gates.Contours
  alias Raxol.Agent.Red.U8Gates.Fired
  alias Raxol.Agent.Red.U8Gates.ReferenceGate

  alias Raxol.Agent.Red.U8Gates.{
    AcceptsForgedDecision,
    EmitsMetaFamily,
    ExecutesWhilePending,
    ForgetsDeny,
    IgnoresTaint,
    InMemoryOnly,
    ReadsDestructiveHint,
    ReadsStampedTrust
  }

  # ===========================================================================
  # Discrimination — the correct ReferenceGate passes every contour, proving
  # the contours are satisfiable (not vacuous) exactly as written.
  # ===========================================================================

  describe "discrimination — ReferenceGate satisfies every contour" do
    test "C1 locked by default" do
      assert :ok = Contours.locked_by_default(ReferenceGate)
    end

    test "C2 escalation emits tip-eligible approval_requested" do
      assert :ok = Contours.escalation_emits_tip_eligible_request(ReferenceGate)
    end

    test "C3 approve :once unlocks exactly that request" do
      assert :ok = Contours.approve_once_unlocks(ReferenceGate)
    end

    test "C4 deny is durable" do
      assert :ok = Contours.deny_is_durable(ReferenceGate)
    end

    test "C5 session scope persists" do
      assert :ok = Contours.session_scope_persists(ReferenceGate)
    end

    test "C6 fold-rebuild equals live (all seeds)" do
      for seed <- @seeds do
        assert :ok = Contours.fold_rebuild_equals_live(ReferenceGate, seed),
               "reference rebuild diverged under seed #{seed}"
      end
    end

    test "C7 forged decision rejected" do
      assert :ok = Contours.forged_decision_rejected(ReferenceGate)
    end

    test "C8 §5.2 escalate predicate table" do
      assert :ok = Contours.escalate_predicate(ReferenceGate)
    end

    test "C9 predicate ignores self-reported destructive_hint" do
      assert :ok = Contours.predicate_ignores_destructive_hint(ReferenceGate)
    end

    test "C10 taint fold over refs (mis-stamped chain escalates; clean chain proceeds)" do
      assert :ok = Contours.taint_escalates(ReferenceGate)
    end

    test "C11 request_ref injective + string-canonical (string tool, ':'-bearing tool/call_id round-trip)" do
      assert :ok = Contours.ref_roundtrips_string_and_colon(ReferenceGate)
    end

    test "C12 once grant is request-scoped (tool+call_id), never admits another tool, never bypasses the taint fold" do
      assert :ok = Contours.once_grant_is_request_scoped(ReferenceGate)
    end

    test "C13 consumed once grant reconstructed as consumed (rebuild == post-consumption live)" do
      assert :ok = Contours.once_consumption_survives_rebuild(ReferenceGate)
    end

    test "C14 §5.2 predicate fails closed on unknown effect_class / non-boolean egress" do
      assert :ok = Contours.escalate_predicate_fails_closed(ReferenceGate)
    end

    test "C15 taint fold fails closed on unknown-trust leaf / malformed entry (spec matches production)" do
      assert :ok = Contours.taint_fold_fails_closed(ReferenceGate)
    end
  end

  # ===========================================================================
  # Negative controls — each dead injector fails its contour with the exact
  # violation signature (branch probes, meta-inv m3 — never just "not :ok").
  # ===========================================================================

  # {site, injector, contour id, signature-predicate function name}
  @injector_table [
    {:executes_while_pending, ExecutesWhilePending, :c1, :sig_executed_while_locked},
    {:emits_meta_family, EmitsMetaFamily, :c2, :sig_not_loop_family},
    {:forgets_deny, ForgetsDeny, :c4, :sig_proceeded_after_deny},
    {:accepts_forged_decision, AcceptsForgedDecision, :c7, :sig_forged_accepted},
    {:in_memory_only, InMemoryOnly, :c6, :sig_rebuild_diverged},
    {:reads_destructive_hint_c8, ReadsDestructiveHint, :c8, :sig_predicate_wrong},
    {:reads_destructive_hint_c9, ReadsDestructiveHint, :c9, :sig_trusted_self_report},
    {:ignores_taint, IgnoresTaint, :c10, :sig_tainted_auto_proceeded},
    {:reads_stamped_trust, ReadsStampedTrust, :c10, :sig_mis_stamped_proceeded}
  ]

  def sig_executed_while_locked({:violation, {:executed_while_locked, n}})
      when n > 0, do: true

  def sig_executed_while_locked(_), do: false

  def sig_not_loop_family({:violation, {:not_loop_family, :meta}}), do: true
  def sig_not_loop_family(_), do: false

  def sig_proceeded_after_deny({:violation, {:proceeded_after_deny, _}}),
    do: true

  def sig_proceeded_after_deny(_), do: false

  def sig_forged_accepted({:violation, :forged_decision_accepted}), do: true
  def sig_forged_accepted(_), do: false

  def sig_rebuild_diverged({:violation, {:rebuild_diverged, _seed, [_ | _]}}),
    do: true

  def sig_rebuild_diverged(_), do: false

  def sig_predicate_wrong({:violation, {:predicate_wrong, _, _, _}}), do: true
  def sig_predicate_wrong(_), do: false

  def sig_trusted_self_report({:violation, {:trusted_self_report, _}}), do: true
  def sig_trusted_self_report(_), do: false

  # IgnoresTaint fails at the FIRST taint leg (direct tainted arg auto-proceeds).
  def sig_tainted_auto_proceeded({:violation, :tainted_auto_proceeded}),
    do: true

  def sig_tainted_auto_proceeded(_), do: false

  # ReadsStampedTrust PASSES the direct leg (the stamp there is honest) and
  # fails only the fold-only leg — the discrimination between field-read and
  # fold is exactly this signature difference.
  def sig_mis_stamped_proceeded({:violation, :mis_stamped_auto_proceeded}),
    do: true

  def sig_mis_stamped_proceeded(_), do: false

  defp run_contour(:c1, gate), do: Contours.locked_by_default(gate)

  defp run_contour(:c2, gate),
    do: Contours.escalation_emits_tip_eligible_request(gate)

  defp run_contour(:c4, gate), do: Contours.deny_is_durable(gate)

  defp run_contour(:c6, gate),
    do: Contours.fold_rebuild_equals_live(gate, hd(@seeds))

  defp run_contour(:c7, gate), do: Contours.forged_decision_rejected(gate)
  defp run_contour(:c8, gate), do: Contours.escalate_predicate(gate)

  defp run_contour(:c9, gate),
    do: Contours.predicate_ignores_destructive_hint(gate)

  defp run_contour(:c10, gate), do: Contours.taint_escalates(gate)

  describe "negative controls — every dead injector fails its contour with its signature" do
    test "(a) a gate that executes while the approval is pending fails C1" do
      result = run_contour(:c1, ExecutesWhilePending)

      assert sig_executed_while_locked(result),
             "expected executed-while-locked, got: #{inspect(result)}"
    end

    test "(F3) a gate emitting approval_requested as family :meta fails C2 (never tip-eligible)" do
      result = run_contour(:c2, EmitsMetaFamily)

      assert sig_not_loop_family(result),
             "expected not-loop-family, got: #{inspect(result)}"
    end

    test "(b) an engine that forgets deny (retry succeeds) fails C4" do
      result = run_contour(:c4, ForgetsDeny)

      assert sig_proceeded_after_deny(result),
             "expected proceeded-after-deny, got: #{inspect(result)}"
    end

    test "(c) a gate accepting an approval_decided without a matching live request fails C7" do
      result = run_contour(:c7, AcceptsForgedDecision)

      assert sig_forged_accepted(result),
             "expected forged-accepted, got: #{inspect(result)}"
    end

    test "(d) in-memory-only approval state (not rebuildable by fold) fails C6 on every seed" do
      for seed <- @seeds do
        result = Contours.fold_rebuild_equals_live(InMemoryOnly, seed)

        assert sig_rebuild_diverged(result),
               "expected rebuild-diverged under seed #{seed}, got: #{inspect(result)}"
      end
    end

    test "(e) a gate reading self-reported destructiveHint instead of effect_class fails C8 and C9" do
      c8 = run_contour(:c8, ReadsDestructiveHint)
      c9 = run_contour(:c9, ReadsDestructiveHint)

      assert sig_predicate_wrong(c8),
             "expected predicate-wrong, got: #{inspect(c8)}"

      assert sig_trusted_self_report(c9),
             "expected trusted-self-report, got: #{inspect(c9)}"
    end

    test "(FI-5) a gate ignoring lineage taint entirely fails C10 at the direct-taint leg" do
      result = run_contour(:c10, IgnoresTaint)

      assert sig_tainted_auto_proceeded(result),
             "expected tainted-auto-proceeded, got: #{inspect(result)}"
    end

    test "(HIGH-1) a field-reading gate passes the honest stamp but lets the mis-stamped tainted chain through" do
      result = run_contour(:c10, ReadsStampedTrust)

      assert sig_mis_stamped_proceeded(result),
             "expected mis-stamped-auto-proceeded (the fold-only leg), got: #{inspect(result)}"
    end
  end

  # ===========================================================================
  # Fired-counters (meta-inv m1): run the whole injector table in one pass;
  # every site must fire its signature. A dead injector = green lies.
  # ===========================================================================

  test "m1 — every dead-injector site fires (no dead injectors)" do
    {:ok, fired} = Fired.start()

    for {site, injector, contour, sig} <- @injector_table do
      result = run_contour(contour, injector)
      if apply(__MODULE__, sig, [result]), do: Fired.fire(fired, site)
    end

    all = MapSet.new(Enum.map(@injector_table, fn {site, _, _, _} -> site end))
    missing = MapSet.difference(all, Fired.fired(fired))

    assert MapSet.size(missing) == 0,
           "dead injector site(s) never fired their signature: #{inspect(MapSet.to_list(missing))}"
  end
end
