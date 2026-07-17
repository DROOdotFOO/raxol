defmodule Raxol.Harness.SealFrontier do
  @moduledoc """
  The shared classifier for "which blocks may seal (commit) this frame" --
  the one piece of logic every consumer that needs to answer that question
  goes through, instead of each restating its own walk.

  ## The committed frontier

  The committed frontier is the leading contiguous run of already-committed
  entries plus whatever newly-committable entries follow them. Everything
  past that point -- `tail_start` in `scan/0` and `commit_walk/5`'s return
  -- stays in the repaintable live region (in our substrate, the
  `InlineAuthority` footer viewport) until it, in turn, becomes
  committable. Sealed history is print-once: once a block is written
  through `InlineAuthority.seal/2`, it is never repainted. Getting the
  frontier boundary wrong in either direction is user-visible: too eager
  and a still-mutating block freezes mid-change in permanent scrollback;
  too conservative and a done block never leaves the footer.

  ## Why one shared classifier

  Three concerns all need to agree on exactly where the frontier stops, or
  a block's rendered height flips between the live region and native
  scrollback and the prompt visibly jumps at commit time:

    * the seal pass -- which blocks get physically written into terminal
      scrollback this frame;
    * the footer/tail composition -- which blocks still render in the
      pinned live region (the trailing "pending" preview);
    * the synchronized-output bracket decision -- `Raxol.Harness.Surface`'s
      `seal_frame/3` reads the SAME `will_commit` projection, per-frame, to
      decide whether this frame's seal + footer repaint needs wrapping in
      a DEC 2026 bracket (see that module's moduledoc). The post-commit
      viewport-sizing seam remains future work: this substrate's footer
      row count is geometry-fixed (never a function of post-seal state),
      so there is no viewport-sizing decision left to make here.

  Consumers never inline their own walk over entries. The consumer table
  today:

    * `Raxol.Harness.Surface.paint_pending_blocks/1` -- the one mutating
      walk, via `commit_walk/5`.
    * `Raxol.Harness.Surface`'s footer pending-preview (`pending_block/1`,
      via `frontier_scan/1`, itself `scan_frontier/3`) -- read-only.
    * `Raxol.Harness.Surface`'s synchronized-output bracket gate
      (`seal_frame/3`, also via `frontier_scan/1`) -- read-only, consulted
      BEFORE the commit pass to decide whether to open a bracket around
      it.

  ## The entry contract

  Entries are projection-agnostic plain maps (`t:entry/0`) so this
  classifier stays decoupled from any one producer's data model. Today
  `Raxol.Harness.Surface.frontier_entries/1` builds them from projection
  blocks plus that module's own painted high-water mark. The live tail
  (still-streaming, not-yet-a-block items) never enters the entry list at
  all: a still-streaming item has no committable form until it completes
  into a block, so it is definitionally past the frontier already -- there
  is nothing for this classifier to say about it.

  ## Decision order and rationale (`committable?/3`)

  The order below is load-bearing -- each step assumes the ones before it
  already ran:

    1. `pending_input?` true -> not committable, UNCONDITIONALLY, regardless
       of turn state. The invariant behind the flag: the entry's rendered
       form can still change in response to user interaction, so committing
       it now (print-once) would freeze a form the user is about to change.
       The sole producer today (`Raxol.Harness.Surface.frontier_entries/1`)
       feeds it from BOTH known instances of that invariant: a live
       `:approval` block still waiting on the user's answer (the
       permission-prompt case -- per `Raxol.UI.Components.Harness.Block`'s
       own contract, "a live approval block is, by definition, waiting on
       the user"; dormant until a producer emits live blocks), and the
       surface's one-advance foldable window on the newest block (a fold
       toggle is the pending interaction). This check runs BEFORE the idle
       relaxation below on purpose: idle relaxation exists to forgive a
       *stale running flag*, never a live pending-input mark, which is
       exactly why pending input is checked first and unconditionally.
    2. `not turn_running?` -> committable (the idle relaxation). A producer
       can leave a `running?` flag set on an entry after the turn has
       already ended (a finalize event missed at a transition boundary);
       if idleness didn't override a stale flag, that entry would
       permanently wedge the frontier for the rest of the session. This
       relaxation only ever reaches entries that already passed the
       pending-input check, so it can never release something still
       awaiting input.
    3. `not running?` -> committable (the ordinary, no-exceptions case: a
       finalized entry with nothing outstanding always commits).
    4. Running, mid-turn: not committable UNLESS one of exactly two
       exceptions applies:
         * `kind == :background_task` -- always committable, even as the
           last entry of a still-running turn. A background-task entry is
           a lifecycle marker; its `running?` flag drives an animation
           only, and its *content* never subsequently changes --
           completion arrives later as a wholly SEPARATE entry. Gating it
           on the flag would wedge the frontier for the rest of the turn
           for no reason: nothing about this entry will ever change.
         * `kind == :message and not is_last?` -- committable. A message
           with a LATER entry already in the list is provably complete:
           the producer has moved on, which could only happen once this
           message stopped changing, regardless of what its own `running?`
           flag says. Tools get NO such relaxation: a running tool call
           may still mutate its own result at any time, so it holds the
           frontier regardless of what comes after it. And the relaxation
           only applies to a message that is NOT the last entry -- the
           last entry of a still-running turn always stays live, on the
           theory that it may still be the one actively streaming.

  Both exceptions are RESERVED/dormant today: `:background_task` is a kind
  no producer currently emits (there is no background-task lane yet), and
  today's block builder only ever constructs completed blocks (`running?`
  always `false`), so the `:message` relaxation never actually fires
  either. Both are corpus-tested here and load-bearing for the future
  agent lane, where entries can legitimately carry a stale or genuinely
  in-progress `running?` flag.

  ## `classify/3`

  `classify(entries, i, turn_running?)` is the public single-step
  primitive: given the FULL entry list and an absolute index, decide
  `:commit` / `:skip` / `:stop` for that one index. In order:

    1. Compute `is_last? = i + 1 >= length(entries)` first (needed by the
       `:message` exception above).
    2. Out of bounds -> `:stop`.
    3. Entry already `committed?` -> `:skip`. The per-entry `committed?`
       flag is authoritative; a caller-held cursor (see below) is only a
       lower-bound hint, never a source of truth, so a walk that starts
       before the true frontier must still skip past anything already
       committed rather than re-emit it.
    4. Not committable (per `committable?/3`) -> `:stop`. Once one entry in
       the walk order is not committable, nothing after it can commit this
       frame either -- the frontier is a contiguous prefix, not a sieve.
    5. Otherwise -> `:commit`.

  The two multi-entry walks below (`scan_frontier/3`, `commit_walk/5`) are
  implemented over the suffix list carrying the absolute index along (to
  avoid `length/1` and `Enum.at/2` costing O(n) per step, which would make
  a full walk O(n^2)) rather than by literally calling `classify/3` in a
  loop -- but they are specified to produce results IDENTICAL to repeatedly
  calling `classify/3`, and that equivalence is covered directly by the
  classify-agreement property test (a reference walk built from repeated
  `classify/3` calls, compared against both walks for arbitrary generated
  states), alongside the scan/walk-agreement property tying the two walks
  to each other.

  ## `scan_frontier/3` -- the read-only projection

  Walks from `opts[:cursor]` (default `0`) applying the `classify/3` step
  order: `:stop` breaks the walk, `:skip` advances past an already-
  committed entry, `:commit` records that a commit pass this frame would
  do work (`will_commit: true`) and advances. Returns `tail_start`, the
  first index a commit pass would NOT consume -- i.e. where the live tail
  begins after this frame's (hypothetical or already-run) commit. This
  function never mutates anything; it exists so a consumer can ask "where
  would the frontier land" without actually committing (the footer preview
  needs exactly this, and the resize seam will too).

  ## `commit_walk/5` -- the one mutating walk

  The only place entries actually get marked committed. From
  `opts[:cursor]` (default `0`): `:stop` breaks, `:skip` advances past an
  already-committed entry, and `:commit` invokes `emit_fn.(acc, index)`
  FIRST -- the entry is only marked `committed?: true` (and the count/
  cursor/acc advanced) on `{:ok, new_acc}`. Emit-before-mark is the
  print-once safety property: a write -> confirm -> mark order means a
  block can never be marked committed without having actually been
  written. On `{:error, :write_failed, new_acc}` the walk HALTS entirely --
  the entry stays uncommitted, and the returned cursor is strictly BEFORE
  it, so the very next pass retries that same entry rather than silently
  skipping past a block that was marked but never actually printed (which
  would make it vanish forever, since a print-once surface cannot re-emit
  a committed entry). This emit-then-mark contract is the seam a
  write-confirming substrate builds on -- and that substrate now exists:
  `Raxol.Harness.Surface.seal_block/2` emits through
  `InlineAuthority.try_seal/2` (write -> confirm -> mark), and the
  `{:error, :write_failed, _}` branch is exercised both by this module's
  own corpus and end-to-end through a real failing device in
  `test/harness/surface_seal_pipeline_test.exs`.

  ## The cursor

  A caller-held index into the entry list -- a lower-bound OPTIMIZATION
  hint only, never authoritative (the per-entry `committed?` flags are
  the source of truth; see `classify/3` step 3 above). A cursor lets a
  caller skip re-scanning a long already-committed prefix every frame
  without needing per-entry flags to do it safely (a stale/too-low cursor
  is always safe -- it just costs a few extra `:skip` steps -- while a
  stale/too-HIGH cursor would be a correctness bug were the flags not
  authoritative underneath it).

  A caller that persists a cursor across list mutations (removal,
  truncation) must adjust it explicitly, since indices shift:

    * `cursor_after_removal/2` -- decrements the cursor by one when the
      removed index was strictly below it (an entry above/at the cursor
      shifting the cursor's own target down by one), otherwise leaves it
      unchanged. Never goes below zero.
    * `cursor_after_truncate/2` -- clamps the cursor to the new (shorter)
      length, so a cursor that pointed past the end of a just-truncated
      list doesn't strand references to entries that no longer exist.

  ## `seal_display_mode/1`

  The print-once per-kind fidelity policy TABLE, declared here so the
  consumer that eventually applies it reads it from one place instead of
  restating it. Committed scrollback cannot be re-folded after the fact
  (it is static terminal text once written), hence per-kind fidelity is
  a seal-time decision: `:reasoning` collapses to its marker (reasoning
  traces are the least useful thing to keep expanded forever in
  scrollback), `:tool_call` truncates (tool output can be arbitrarily
  long; a truncated summary is what belongs in permanent history), and
  `:diff` stays expanded always (a diff is the key artifact of an edit --
  there is no useful truncated form of it). Everything else --
  `:message`, `:approval`, `:opaque`, and any unrecognized kind --
  defaults to `:expanded`: the safe default for a kind this policy has no
  specific opinion about is to show it in full, not to guess at a
  collapse/truncate rule that might hide something that mattered.

  NOT YET WIRED: no live seal path consults this policy today.
  `Raxol.Harness.Surface`'s `seal_block/2` seals a block at its current
  fold state, and the truncated tool-output rendering this table calls
  for does not exist yet -- both are renderer-level work owned by the
  commit-cap / frame-order follow-up, which consumes this table rather
  than inventing its own. Until that lands, sealed tool output is NOT
  bounded on its way into permanent scrollback; the table is the declared
  policy (corpus-tested for the values), not an enforced one.
  """

  @type entry :: %{
          optional(:kind) => term(),
          optional(:committed?) => boolean(),
          optional(:running?) => boolean(),
          optional(:pending_input?) => boolean()
        }

  @type scan :: %{tail_start: non_neg_integer(), will_commit: boolean()}
  @type step :: :commit | :skip | :stop
  @type emit_fn :: (acc :: term(), index :: non_neg_integer() ->
                      {:ok, term()} | {:error, :write_failed, term()})

  # -- committability ---------------------------------------------------------

  @doc """
  Whether a single entry may commit (seal) right now. See the moduledoc's
  "Decision order and rationale" section -- the order below is load-bearing.

  The two boolean arguments are positional and adjacent -- transposing them
  silently miscomputes the frontier, so the @spec names them and every
  caller in this codebase passes them via identically-named variables
  (`turn_running?`, then the is-last flag). Keyword-izing them was
  considered and declined: this signature is pinned by the ported
  reference design, and the walks are the only intended callers.
  """
  @spec committable?(
          entry :: entry(),
          turn_running? :: boolean(),
          is_last? :: boolean()
        ) :: boolean()
  def committable?(entry, turn_running?, is_last?) do
    pending_input? = Map.get(entry, :pending_input?, false)
    running? = Map.get(entry, :running?, false)
    kind = Map.get(entry, :kind, nil)

    cond do
      pending_input? -> false
      not turn_running? -> true
      not running? -> true
      kind == :background_task -> true
      kind == :message and not is_last? -> true
      true -> false
    end
  end

  # -- single-step classification ---------------------------------------------

  @doc """
  Classifies the entry at absolute index `i` in `entries`: `:commit`,
  `:skip` (already committed), or `:stop` (out of bounds, or this entry --
  and therefore everything after it this frame -- is not committable). See
  the moduledoc's "`classify/3`" section for the full step order.
  """
  @spec classify(
          entries :: [entry()],
          i :: non_neg_integer(),
          turn_running? :: boolean()
        ) :: step()
  def classify(entries, i, turn_running?) do
    # One O(i) traversal: the head of the dropped suffix is the entry, and
    # an empty rest IS the is-last check -- no length/1 + Enum.at/2 double
    # pass over the whole list.
    case Enum.drop(entries, i) do
      [] ->
        :stop

      [entry | rest] ->
        cond do
          Map.get(entry, :committed?, false) -> :skip
          not committable?(entry, turn_running?, rest == []) -> :stop
          true -> :commit
        end
    end
  end

  # -- read-only projection ----------------------------------------------------

  @doc """
  Read-only projection of where the frontier stands: walks from
  `opts[:cursor]` (default `0`) and returns `tail_start` (the first index a
  commit pass would not consume) and `will_commit` (whether that pass would
  do anything at all). Never mutates `entries`. See the moduledoc.
  """
  @spec scan_frontier(
          entries :: [entry()],
          turn_running? :: boolean(),
          opts :: keyword()
        ) :: scan()
  def scan_frontier(entries, turn_running?, opts \\ []) do
    cursor = Keyword.get(opts, :cursor, 0)

    entries
    |> Enum.drop(cursor)
    |> scan_walk(cursor, turn_running?, false)
  end

  # Suffix walk: pattern-match `[entry | rest]` carrying the absolute
  # index as a counter -- `rest == []` is the is-last check -- so the
  # whole scan is O(n), never O(n) `Enum.at/2` per step.
  defp scan_walk([], index, _turn_running?, will_commit),
    do: %{tail_start: index, will_commit: will_commit}

  defp scan_walk([entry | rest], index, turn_running?, will_commit) do
    cond do
      Map.get(entry, :committed?, false) ->
        scan_walk(rest, index + 1, turn_running?, will_commit)

      not committable?(entry, turn_running?, rest == []) ->
        %{tail_start: index, will_commit: will_commit}

      true ->
        scan_walk(rest, index + 1, turn_running?, true)
    end
  end

  # -- the one mutating walk ----------------------------------------------------

  @doc """
  The one mutating walk: from `opts[:cursor]` (default `0`), commits every
  entry it can via `emit_fn`, marking each `committed?: true` only after a
  successful emit. See the moduledoc's "`commit_walk/5`" section for the
  full emit-then-mark and failure-halt contract.
  """
  @spec commit_walk(
          entries :: [entry()],
          turn_running? :: boolean(),
          acc,
          emit_fn(),
          opts :: keyword()
        ) ::
          %{
            entries: [entry()],
            cursor: non_neg_integer(),
            committed: non_neg_integer(),
            acc: acc
          }
        when acc: term()
  def commit_walk(entries, turn_running?, acc, emit_fn, opts \\ []) do
    cursor = Keyword.get(opts, :cursor, 0)
    {prefix, suffix} = Enum.split(entries, cursor)

    commit_step(
      suffix,
      Enum.reverse(prefix),
      cursor,
      turn_running?,
      acc,
      emit_fn,
      0
    )
  end

  # Suffix walk, same shape as scan_walk/4: `rev_walked` accumulates the
  # already-walked entries in reverse (marking a just-emitted entry
  # committed is an O(1) prepend, never an O(n) List.update_at/3), and the
  # final entry list is one reverse-onto of the untouched remainder -- the
  # whole walk is O(n).
  defp commit_step([], rev_walked, index, _turn_running?, acc, _emit, count) do
    %{
      entries: Enum.reverse(rev_walked),
      cursor: index,
      committed: count,
      acc: acc
    }
  end

  defp commit_step(
         [entry | rest],
         rev_walked,
         index,
         turn_running?,
         acc,
         emit_fn,
         count
       ) do
    cond do
      Map.get(entry, :committed?, false) ->
        commit_step(
          rest,
          [entry | rev_walked],
          index + 1,
          turn_running?,
          acc,
          emit_fn,
          count
        )

      not committable?(entry, turn_running?, rest == []) ->
        halt_walk(rev_walked, [entry | rest], index, count, acc)

      true ->
        case emit_fn.(acc, index) do
          {:ok, new_acc} ->
            sealed = Map.put(entry, :committed?, true)

            commit_step(
              rest,
              [sealed | rev_walked],
              index + 1,
              turn_running?,
              new_acc,
              emit_fn,
              count + 1
            )

          {:error, :write_failed, new_acc} ->
            halt_walk(rev_walked, [entry | rest], index, count, new_acc)
        end
    end
  end

  # The walk stopped at `remaining`'s head (a blocker, or a failed emit):
  # rebuild the full entry list with the stopping entry left untouched and
  # the cursor strictly before it.
  defp halt_walk(rev_walked, remaining, index, count, acc) do
    %{
      entries: Enum.reverse(rev_walked, remaining),
      cursor: index,
      committed: count,
      acc: acc
    }
  end

  # -- cursor maintenance -------------------------------------------------------

  @doc """
  Adjusts a persisted cursor after removing the entry at `removed_index`:
  decrements by one when the removal happened strictly below the cursor
  (shifting the cursor's own target down by one), otherwise leaves it
  unchanged. Never returns below zero.
  """
  @spec cursor_after_removal(non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def cursor_after_removal(cursor, removed_index) when removed_index < cursor,
    do: max(cursor - 1, 0)

  def cursor_after_removal(cursor, _removed_index), do: cursor

  @doc """
  Adjusts a persisted cursor after the entry list is truncated to
  `new_length`: clamps the cursor so it never points past the end of the
  (now shorter) list.
  """
  @spec cursor_after_truncate(non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def cursor_after_truncate(cursor, new_length), do: min(cursor, new_length)

  # -- seal display policy ------------------------------------------------------

  @doc """
  The print-once per-kind fidelity policy: `:reasoning` collapses,
  `:tool_call` truncates, `:diff` always stays fully expanded, everything
  else defaults to `:expanded`. See the moduledoc's "`seal_display_mode/1`"
  section.
  """
  @spec seal_display_mode(term()) :: :expanded | :collapsed | :truncated
  def seal_display_mode(:reasoning), do: :collapsed
  def seal_display_mode(:tool_call), do: :truncated
  def seal_display_mode(:diff), do: :expanded
  def seal_display_mode(_other), do: :expanded
end
