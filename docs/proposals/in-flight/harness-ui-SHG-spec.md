# Seal-Hardening Gate — implementable spec (G1–G4 + test corpus)

Banked from close-read #1 (fable, 2026-07-16) against
`scratchpad/grok-build/crates/codegen/xai-grok-pager-minimal/src/`
({commit,live,overlay,lib}.rs). This is the correctness spec the full-logical
seal impl carries. Every claim cites the grok source file:line so it's
re-verifiable. Companion to `harness-ui-grok-reshaped-dag.md`.

---

## G1 — single shared frontier classifier

`classify(entries, i, turn_running?) :: :commit | :skip | :stop` (grok commit.rs:143-163).
Decision order — no reordering:
1. `is_last = i+1 >= length(entries)` (computed first, feeds committability).
2. index OOB → `:stop`.
3. already committed → `:skip` (committed id-set authoritative; scan cursor is a lower-bound hint only).
4. `not is_committable(entry, turn_running?, is_last)` → `:stop`.
5. else → `:commit`.

`is_committable/3` order (commit.rs:92-115):
1. `pending_user_input?` → false (UNCONDITIONAL on turn state — see G3).
2. `not turn_running?` → true (idle relaxation past stale running flags).
3. `not running?` → true.
4. running+mid-turn: true only for the two exceptions (G3), else false.

Read-only projection `scan_frontier(entries, turn_running?) :: %FrontierScan{tail_start, will_commit}`
(commit.rs:167-199): walk from scan cursor, `:stop` breaks / `:skip` advances /
`:commit` sets will_commit+advances. `tail_start` = first entry a commit pass
would NOT consume = where the live tail starts AFTER this frame's commit. No mutation.

**Four consumers that MUST call the shared classifier (never inline their own):**
| consumer | grok call site | uses |
|---|---|---|
| commit pass (`commit_leading_run`/`commit_active`) | commit.rs:227 | the ONE mutating walk |
| `will_commit` resize gate (`sync_viewport`) | overlay.rs:210 | resize path pick |
| viewport sizing (`tail_height`) | live.rs:682 | post-commit footer height |
| live tail renderer (`draw_tail`) | live.rs:363 | which entries paint in pinned region |

Consumers 2-4 run BEFORE the commit in the frame and must mirror its stop
condition exactly (commit.rs:179-181). Raxol: one pure module
`SealOracle.classify/3` + `scan_frontier/2`; the four consumers never reimplement.

## G2 — two-phase seal (write → confirm → mark)

grok commit.rs:201-242, 311-318, 439-463. Per `:commit` entry, `on_commit(state, i)`
runs FIRST (finalize, stamp display mode, render to native scrollback); ONLY if it
returns true is the entry marked committed. false (write failed) → walk breaks,
entry stays uncommitted, cursor stays strictly BEFORE it, next frame retries.
Cursor persisted only at walk end.

Invariant: mark-before-write is forbidden — "print-once means a marked-but-unprinted
block can never be emitted again; the block would silently vanish" (commit.rs:208-210).
Write error is PROPAGATED, not swallowed (commit.rs:312-318). Secondary bookkeeping
(expand-record) happens only after the print succeeds (commit.rs:457-463).

Append-only post-seal: from a successful insert on, content is frozen on the user's
terminal; in-place mutation never reaches screen. Placeholder-fill handlers
(SessionRecap pattern) MUST check `is_committed` and append a FRESH block
(commit.rs:87-91). Mandatory not optional — idle-pushed running blocks commit immediately.

Elixir shape:
```elixir
@spec seal_leading_run(state, turn_running? :: boolean(), emit_fn) :: {sealed_count, state}
  when emit_fn: (state, index -> {:ok, state} | {:error, :write_failed, state})
```
- `{:ok, state}` → mark_committed, advance.
- `{:error, :write_failed, state}` → HALT walk; entry unsealed; cursor strictly before; retry next frame.
- `fill_placeholder(state, id, content)` pattern-matches `is_committed` → `{:error, :sealed}`, forcing caller to `append_block/2`.
Expand re-print retry: failed write requeues failed id + REST of queue (commit.rs:545-556);
skip-frame guards (no agent, zero width, modal open) leave queue intact (commit.rs:509-523).

## G3 — pending-input holds frontier + two running exceptions

First clause unconditional (commit.rs:99-101): pending block's rendered form still
changes when the prompt resolves; committing (print-once) freezes the "waiting" form.
Idle case defensive — pending must never commit out from under its modal. Idle relaxation
applies ONLY to stale-running flags, not pending marks (test commit.rs:782-786) — which is
why the pending check precedes the `not turn_running?` early-true.

Two committable-despite-running exceptions (commit.rs:108-115):
```elixir
defp committable_while_running?(%{block: %BgTask{}}, _is_last), do: true
defp committable_while_running?(%{block: %AgentMessage{}}, is_last), do: not is_last
defp committable_while_running?(_entry, _is_last), do: false
```
1. **BgTask "started"** (commit.rs:67-77): is_running drives bullet animation only; content
   never changes (completion pushes a SEPARATE block; live output → task store). Async task
   outlives its turn; gating on is_running would wedge frontier (started block + everything
   after stuck invisible). Committable even as last entry.
2. **Non-last AgentMessage** (commit.rs:55-65): tracker leaves is_running set until turn end;
   a message with a LATER block is provably complete (tracker moved past). Commit pass
   finalizes before render. Tools get NO relaxation (result may still update); last entry
   always stays live.

## G4 — frame order (lib.rs draw, 91-108)

Ordered checklist a Raxol paint frame MUST follow:
0. Open synchronized-update (DEC 2026) + adopt terminal size (autoresize) BEFORE any width
   read. Then sync pending-input marks ONCE up front (lib.rs:98) — sizing, will_commit gate,
   commit pass all judge against identical marks (else a just-arrived permission looks
   committable to the sizing walk for one frame, commit.rs:399-403).
1. Commit cards (welcome above first block; ready plan).
2. Size viewport to POST-commit height (`tail_height` from `scan_frontier(...).tail_start`),
   BEFORE the commit. will_commit=true → pre-set height keeping current top, skip clear
   (the insert clears/scrolls); else clearing top-fixed resize (overlay.rs:167-190).
3. Commit (mutating walk; each block via insert-equivalent at exactly `desired_height(width)`
   rows) + expand re-prints (uncapped) below.
4. Live redraw (tail·status·overlay·prompt) into final viewport position; end sync-update here.

Two named failure modes if reordered:
- **"Input snaps to top"** — sizing AFTER committing: viewport still at tall streaming height
  at commit, following shrink strands prompt at screen top (lib.rs:60-64, live.rs:665-672).
- **Stale-width corrupts sealed history** — committing BEFORE adopting size: block finalizes at
  stale width, shrink hard-wraps over-wide rows, PERMANENTLY garbles the print-once copy
  (lib.rs:73-79). No-op on non-resize frames.
Also: block gap applied identically both sides of frontier (commit.rs:37-41); still-live
entries stamped with their eventual commit display mode so tail height doesn't snap on
finalize (commit.rs:466-479).

---

## Test corpus — port checklist for SealOracle

Pure frontier/state-machine tests (port ALL — no renderer needed), grok commit.rs:578-1324:
1. `commits_leading_finalized_run_and_stops_at_running` (:608) — leading run commits, stops at running; entry AFTER running doesn't commit; finalizing blocker releases rest.
2. `pending_user_input_holds_the_frontier` (:629) — finalized-but-pending stops walk; clearing releases.
3. `running_agent_message_commits_once_a_later_block_exists` (:645) — last running AgentMessage stays live; later block proves complete → commits mid-turn.
4. `running_tool_still_holds_the_frontier_even_with_a_later_block` (:671) — tool relaxation MUST NOT apply; running tool holds regardless.
5. `bg_task_started_commits_while_running_and_does_not_wedge_frontier` (:684).
6. `bg_task_started_commits_as_last_running_entry` (:705).
7. `no_double_commit_after_mid_list_shift_remove` (:718) — committed flags travel with entries on shift; nothing re-emitted.
8. `mid_list_removal_below_cursor_does_not_strand_uncommitted_entries` (:739) — cursor decrements with shift so appended entries still commit.
9. `pending_user_input_holds_the_frontier_even_when_idle` (:780) — holds at turn_running=false.
10. `failed_emit_leaves_entry_uncommitted_for_retry` (:810) — **G2 invariant**: 0 committed, 1 call, unmarked, cursor holds; retry commits both.
11. `scan_frontier_mirrors_commit_leading_run` (:838) — **G1 agreement**: read-only scan == mutating walk in every phase (pre-commit will_commit/tail_start, post-commit cursor==tail_start, idle).
12. `remove_from_below_frontier_then_push_still_commits` (:868) — cursor clamps on rewind.
13. `commit_leading_run_advances_frontier_and_marks_committed_once` (:887) — skip idempotent.
14. `idle_turn_commits_past_stale_running_entry` (:914) — stuck-spinner regression.
15. `clear_resets_the_frontier` (:945).
16. `commit_display_mode_policy` (:1305) — thinking→Collapsed, edit→Expanded, execute→Truncated, message→Expanded (= our seal_display_mode/1, G6).

Renderer-level (port where Raxol has the surface):
17. `committed_blocks_fit_desired_height` (:1026) — **height-exactness (K5)**: every block × widths{40,80,120}, no content glyph past desired_height (reserved rows == painted, else insert clips sealed content). Chrome cols exempt.
18. `committed_renderer_uses_owning_session_cwd_for_tool_paths` (:996).
19. `terminal_native_lock_paints_only_native_colors` (:1072) — only Reset/named ANSI-16 under native lock (ties G7).
20. `large_commit_is_capped_with_footer` (:1164) — full-height wrap (byte-identical to uncapped), cap rows only, last row `… N more lines — /transcript`.
21. `small_commit_is_not_capped` (:1205).
22. `committed_edit_keeps_diff_line_backgrounds` (:1236).
Cross-file: `tail_height_uses_owning_session_cwd_for_tool_paths` (live.rs:704) — sizing walk must measure with the EXACT renderer config draw_tail paints with (accent-reclaimed vs visible wrap divergence).

## Two tests grok does NOT have — our net-new red-first additions
- **Property test** `scan_frontier ≡ commit_leading_run` for ALL generated (entries, turn_state), not just test 11's examples. grok only example-checks the agreement; a property closes it.
- **Resize-during-commit** — the G4 stale-width failure is prose-guarded only (lib.rs:73-79), never test-covered. Add a red-first test: a block finalizing on a shrink frame must not garble (adopt-size-first proven, not asserted).
