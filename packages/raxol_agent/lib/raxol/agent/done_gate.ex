defmodule Raxol.Agent.DoneGate do
  @moduledoc """
  U21 — Evidence-gated done (FI-6). **Skeleton only** — the real gate logic is
  `:not_implemented` on purpose: this module is the enabler that the permanent
  `red/u21-evidence-done` failing-first suite is authored against, before the
  implementation exists (see
  `docs/proposals/in-flight/harness-roadmap.md` §U21 + FI-6 and
  `packages/raxol_agent/test/raxol/agent/red/u21_evidence_done_red_test.exs`).

  ## What U21 gates

  An agent may not declare a turn "done" on its own say-so. The
  done/turn-success transition (a `turn_completed` with `final: true`) is
  **gated on journaled evidence** — tool results and verification outputs (test
  runs, file checks) — that **postdates the last mutating action of the turn**.

  Evidence is named by `refs`: journal offsets carried on the proposed done.
  Each ref must

    1. **exist** — resolve to a real journal record, else `{:error, {:missing_ref, offset}}`;
    2. **be evidence-class** — a tool result / verification output, never the
       agent's own `:message` self-report and never an internal `:state_change`,
       else `{:error, {:not_evidence, offset}}`;
    3. **postdate the last mutation** — strictly greater offset than the turn's
       last mutating action; stale evidence that predates a later mutation does
       not count, else `{:error, {:stale_evidence, offset}}`.

  A done carrying no refs at all is `{:error, :evidence_required}`. Only when
  every ref satisfies (1)-(3) does the gate accept and hand back the durable
  `turn_completed{final: true, refs: [...]}` event for journaling — so a surface
  can render "done because X".

  The gate never transitions the turn to done on a rejected claim; the turn
  stays open and the typed error is surfaced.

  ## Behaviour

  `gate/3` is declared as a behaviour callback so the red suite can drive
  deliberately-broken *dead injectors* (an impl that skips the ref check, one
  that checks existence but not ordering, one that lets self-reported text
  count as evidence) through the same shape and prove each one fails its
  targeted red.
  """

  alias Raxol.Agent.Contract.Event

  @typedoc "A journal offset (`Event.id`), the currency `refs` are stated in."
  @type offset :: non_neg_integer()

  @typedoc """
  A turn's journal: contract events in offset order. Each carries `id` (the
  offset), `turn_id`, `type`, and `payload` (see `Raxol.Agent.Contract.Event`).
  """
  @type journal :: [Event.t() | map()]

  @typedoc """
  The gate verdict. Accept hands back the done event to journal; every reject is
  a distinct typed error naming the offending ref where one applies.
  """
  @type verdict ::
          {:ok, Event.t()}
          | {:error, :evidence_required}
          | {:error, {:missing_ref, offset()}}
          | {:error, {:not_evidence, offset()}}
          | {:error, {:stale_evidence, offset()}}
          | {:error, :not_implemented}

  @doc """
  Gate a proposed done for `turn_id` against `journal`, citing evidence `refs`.

  See the moduledoc for the acceptance contract. Returns `{:ok, done_event}`
  (a `turn_completed{final: true, refs: refs}` to be journaled) or a typed
  rejection; the turn does not transition to done on a rejection.
  """
  @callback gate(journal(), turn_id :: term(), refs :: [offset()]) :: verdict()

  @doc """
  Skeleton — always `{:error, :not_implemented}`. Replaced when U21 lands; the
  red suite pins the acceptance contract until then.
  """
  @spec gate(journal(), term(), [offset()]) :: verdict()
  def gate(_journal, _turn_id, _refs), do: {:error, :not_implemented}
end
