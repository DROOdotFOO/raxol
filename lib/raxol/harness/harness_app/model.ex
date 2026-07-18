defmodule Raxol.Harness.HarnessApp.Model do
  @moduledoc """
  The pure TEA model for `Raxol.Harness.HarnessApp` — today's
  `Raxol.Harness.Surface` map with the paint plumbing stripped out
  (`docs/proposals/in-flight/harness-tea-migration.md` §2). Every function
  here is a pure fold: it takes the model plus one datum and returns a new
  model (or `{model, directives}` for the input path). It never writes a
  byte, touches a process, or reads a clock — wall time enters only as the
  `now` argument of `tick/2` and `advance/2`, so fixture replay and
  time-travel are deterministic.

  ## What was deleted vs. Surface (§2 line 76)

  `authority`, `device`, the `mode` ladder, `footer_rows`, `command_sink`,
  every byte-cursor field. The frame-composition half (footer, transcript
  window, cursor) is reborn in `Raxol.Harness.HarnessApp.View` as an
  element tree; the mutation half is here.

  ## The reveal/seal core (`:full_viewport` is pure)

  `advance/2` reveals one more held event, re-projects the revealed prefix
  (`Raxol.Harness.Projection.project/2`), then runs the ONE mutating
  frontier walk (`Raxol.Harness.SealFrontier.commit_walk/5`) whose emit —
  in the full-viewport model — simply prepends a frozen `seal_record` to
  `transcript_records` and advances `painted_count`. Sealing freezes a
  block with its seal-time prominence grade, so a later render re-renders
  it byte-identically (law 1, logical immutability). `transcript_records`
  is held newest-first (O(1) prepend at seal); the view reverses once.

  ## Belief split (`PumpContract` §6)

  `current_turn_id`, `steer_in_flight?`, `quit_armed?`, `session_over?` are
  MODEL beliefs (they render honestly); the Task/timeout/kill mechanics
  live in the pump. `update/2` returns `Raxol.Harness.Directive.Lane` /
  `.Editor` structs addressed to `model.pump`; when `pump` is `nil`
  (fixture mode, no live lane) a lane-crossing command folds an honest stub
  notice instead — the fixture demo's steer/interrupt/submit stubs.
  """

  alias Raxol.Harness.{
    Directive,
    Projection,
    RecencyPolicy,
    SealFrontier,
    UnreadDivider
  }

  alias Raxol.UI.Components.Harness.{Block, Composer, Picker}
  alias Raxol.UI.Harness.{InputEvent, Keymap}

  # -- geometry constants (mirror surface.ex:1285-1310) --------------------
  @margin_cols 2
  @sigil_cols 2
  @fv_frame_inset 1

  @default_sigil "❯"
  @default_reply_sigil "❮"

  # The footer-group vocabulary a debug highlight may name (fail-safe: an
  # unknown group clears — vocabulary validation is the model's job).
  @debug_highlight_groups [
    :status,
    :lane,
    :submitting,
    :overlay,
    :divider,
    :preview,
    :composer_sep,
    :composer,
    :notice
  ]

  # Fixed item-type spelling fold (never String.to_atom/1 on wire input).
  @item_type_atoms %{
    "message" => :message,
    "reasoning" => :reasoning,
    "tool_use" => :tool_use,
    "tool_result" => :tool_result
  }

  # -- honest notices (byte-relevant strings kept verbatim from Surface) ---
  @busy_notice "» a turn is already running — wait for it, then resend"
  @steer_in_flight_notice "» steer already in flight — wait for its decision"
  @interrupt_sent_notice "interrupt sent — awaiting confirmation"
  @approval_sent_notice "approval answer sent"
  @degraded_notice "» warning: input reader failed to re-enable — keyboard may be dead"

  defstruct events: [],
            revealed: 0,
            projection: nil,
            fold_defaults: %{},
            painted_count: 0,
            fold_overrides: %{},
            focused_index: nil,
            composer: nil,
            composing?: true,
            width: 80,
            rows: 24,
            status: %{},
            stub_notice: nil,
            lane_notice: nil,
            overlay: nil,
            unread: nil,
            pending_submit: nil,
            stream_open?: false,
            spinner_frame: 0,
            debug_highlight: nil,
            sealed_any?: false,
            last_sealed_kind: nil,
            transcript_records: [],
            scroll_anchor: :tail,
            greeting?: false,
            sigil: @default_sigil,
            reply_sigil: @default_reply_sigil,
            editor_session: nil,
            editor_opts: [],
            sessions_dir: nil,
            # lifted driver beliefs (PumpContract §6)
            current_turn_id: nil,
            quit_armed?: false,
            steer_in_flight?: false,
            session_over?: false,
            # the sole lane client (pid) or nil in fixture mode
            pump: nil

  @type seal_record ::
          {:block, Block.t(), float()}
          | {:marker, String.t()}
          | {:echo, String.t()}

  @type t :: %__MODULE__{}

  # ── init ────────────────────────────────────────────────────────────────

  @doc """
  Builds the initial model from config. Options:

    * `:events` — a list of event-shaped maps (live wire shape) OR a
      `Raxol.Harness.Fixture.Session` (fixture mode: all events held,
      revealed incrementally by `{:reveal}`). Defaults to `[]`.
    * `:width` / `:rows` — geometry (defaults 80×24).
    * `:pump` — the lane-client pid, or `nil` for fixture mode.
    * `:fold_defaults`, `:greeting?`, `:stream_open`, `:sigil`,
      `:reply_sigil`, `:editor_session`, `:editor_opts`, `:sessions_dir`.

  `init/1` seals NOTHING into the transcript (Surface's own contract): the
  transcript starts `[]` and blocks reveal incrementally through `advance/2`
  in the update path. Any boot POST lines are sealed via `seal_lines/2`
  after construction.
  """
  @spec build(keyword()) :: t()
  def build(opts \\ []) do
    width = Keyword.get(opts, :width, 80)
    rows = Keyword.get(opts, :rows, 24)
    fold_defaults = Keyword.get(opts, :fold_defaults, %{})
    events = events_from(Keyword.get(opts, :events, []))

    model = %__MODULE__{
      events: events,
      revealed: 0,
      projection: Projection.project([], fold_defaults: fold_defaults),
      fold_defaults: fold_defaults,
      width: width,
      rows: rows,
      unread: UnreadDivider.new(),
      greeting?: Keyword.get(opts, :greeting?, false),
      stream_open?: Keyword.get(opts, :stream_open, false),
      sigil: Keyword.get(opts, :sigil, @default_sigil),
      reply_sigil: Keyword.get(opts, :reply_sigil, @default_reply_sigil),
      editor_session: Keyword.get(opts, :editor_session),
      editor_opts: Keyword.get(opts, :editor_opts, []),
      sessions_dir: Keyword.get(opts, :sessions_dir),
      pump: Keyword.get(opts, :pump)
    }

    {:ok, composer} =
      Composer.init(%{
        id: "surface-composer",
        width: content_width(model),
        focused: true
      })

    %{model | composer: composer}
  end

  # Fixture Session -> its envelope bodies (the event-shaped maps
  # Projection.project/2 already consumes on the Session path). A plain
  # list passes through.
  defp events_from(%{envelopes: envelopes}) when is_list(envelopes),
    do: Enum.map(envelopes, & &1.body)

  defp events_from(events) when is_list(events), do: events

  # ── geometry ────────────────────────────────────────────────────────────

  @doc "The margined content width the composer and blocks render at."
  @spec content_width(t()) :: non_neg_integer()
  def content_width(model),
    do: max(model.width - @margin_cols - frame_inset(model), 0)

  @doc "The one-cell full-viewport frame inset (0 when geometry degenerate)."
  @spec frame_inset(t()) :: 0 | 1
  def frame_inset(model) do
    if model.width - @margin_cols - 1 >= 1 and model.rows - 1 >= 1,
      do: @fv_frame_inset,
      else: 0
  end

  @doc false
  def sigil_cols, do: @sigil_cols

  # ── reveal / advance (the {:reveal} fold and the {:batch} event fold) ────

  @doc """
  Reveals one more held event and seals any newly-committable block into
  `transcript_records` (the pure `:full_viewport` frontier walk). `now`
  is data — supplied by `{:tick, now}` on the live/fixture clock, `nil`
  otherwise (a reveal carries no clock). A no-op once `done?/1`.
  """
  @spec advance(t(), integer() | nil) :: t()
  def advance(model, now \\ nil) do
    if done?(model), do: model, else: run_advance(model, now)
  end

  @doc "Reveals every held event (fixture full-replay); a no-op once done."
  @spec reveal_all(t(), integer() | nil) :: t()
  def reveal_all(model, now \\ nil) do
    if done?(model), do: model, else: model |> advance(now) |> reveal_all(now)
  end

  defp run_advance(model, now) do
    revealed = min(model.revealed + 1, length(model.events))
    events_so_far = Enum.take(model.events, revealed)

    projection =
      Projection.project(events_so_far, fold_defaults: model.fold_defaults)

    %{model | revealed: revealed, projection: projection}
    |> bump_spinner()
    |> reconcile_unread()
    |> seal_pending()
    |> update_status(events_so_far, now)
  end

  defp bump_spinner(model),
    do: Map.update!(model, :spinner_frame, &(&1 + 1))

  # The pure paint_pending_blocks: run the ONE mutating frontier walk,
  # sealing each newly-committable block as a frozen record. In the
  # full-viewport model the emit is infallible (a list prepend), so the
  # walk always consumes the whole committable prefix.
  defp seal_pending(model) do
    entries = frontier_entries(model)
    turn_running? = turn_running?(model)
    scan = SealFrontier.scan_frontier(entries, turn_running?)
    model = detach_up_to(model, scan.tail_start)

    result =
      SealFrontier.commit_walk(
        entries,
        turn_running?,
        model,
        fn acc, index ->
          block =
            acc.projection.blocks
            |> Enum.at(index)
            |> apply_fold_override(index, acc.fold_overrides)

          seal_block(acc, block)
        end,
        cursor: model.painted_count
      )

    result.acc
  end

  # `:full_viewport` seal: freeze the block into a seal_record with its
  # seal-time prominence grade (logical immutability) and advance the
  # committed cursor. The write can never fail (a list prepend), so this
  # always returns `{:ok, _}`.
  defp seal_block(model, block) do
    record = {:block, block, block_prominence(block, model)}

    {:ok,
     %{
       model
       | transcript_records: [record | model.transcript_records],
         painted_count: model.painted_count + 1,
         sealed_any?: true,
         last_sealed_kind: block.kind
     }}
  end

  defp block_prominence(block, model),
    do: RecencyPolicy.grade_block(block, model.projection.source_events)

  # Deep-copy binaries in the already-sealed prefix so a later fresh
  # projection cannot hand back a sub-binary reference to a stream buffer
  # (surface.ex's detach footgun fix — kept: it is pure model state).
  defp detach_up_to(model, target) do
    blocks =
      model.projection.blocks
      |> Enum.with_index()
      |> Enum.map(fn {block, index} ->
        if index < target, do: detach_content(block), else: block
      end)

    %{model | projection: %{model.projection | blocks: blocks}}
  end

  defp detach_content(%{content: content} = block),
    do: %{block | content: detach_binaries(content)}

  defp detach_binaries(bin) when is_binary(bin), do: :binary.copy(bin)

  defp detach_binaries(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {k, v} -> {k, detach_binaries(v)} end)

  defp detach_binaries(list) when is_list(list),
    do: Enum.map(list, &detach_binaries/1)

  defp detach_binaries(other), do: other

  # Public (`@doc false`) for HarnessApp.View: the footer preview renders
  # the pending block with the SAME override the seal walk would apply, so
  # a fold toggle shows in the preview before the block seals (the old
  # surface's pending_preview_lines/1 parity).
  @doc false
  def apply_fold_override(block, index, overrides) do
    case Map.get(overrides, index) do
      nil -> block
      :folded -> Block.fold(block, fold_after_seal: :allow)
      :expanded -> Block.unfold(block, fold_after_seal: :allow)
    end
  end

  # ── frontier bookkeeping (surface.ex:2250-2316, pure) ────────────────────

  @doc false
  @spec frontier_entries(t()) :: [SealFrontier.entry()]
  def frontier_entries(model) do
    blocks = model.projection.blocks
    total = length(blocks)
    reveal_finished? = reveal_finished?(model)

    blocks
    |> Enum.with_index()
    |> Enum.map(fn {block, index} ->
      %{
        kind: block.kind,
        committed?: block_sealed?(model, index),
        running?: Block.live?(block),
        pending_input?:
          awaiting_input?(block) or
            (not reveal_finished? and index == total - 1)
      }
    end)
  end

  # Public (`@doc false`) for HarnessApp.View: the pending-block preview's
  # `pending?` context flag is `not reveal_finished?(model)` -- while the
  # reveal may still deliver a result, a resultless tool renders `running…`
  # (seal-on-result-only), and only afterwards the final `⊘ no result`.
  @doc false
  def reveal_finished?(model),
    do: not model.stream_open? and model.revealed >= length(model.events)

  defp block_sealed?(model, index) when is_integer(index),
    do: index < model.painted_count

  defp awaiting_input?(block),
    do: Block.live?(block) and block.kind == :approval

  defp turn_running?(model),
    do: not Map.get(model.status, :turn_completed, false)

  @doc "The live approval block awaiting an answer, or nil (THE needs-input referent)."
  @spec live_approval_block(t()) :: Block.t() | nil
  def live_approval_block(model),
    do: Enum.find(model.projection.blocks, &awaiting_input?/1)

  # ── status derivation (surface.ex:2769-2865, pure) ───────────────────────

  defp update_status(model, events_so_far, now) do
    loop_events =
      Enum.filter(events_so_far, &(event_field(&1, :family) == :loop))

    last_loop = List.last(loop_events)

    last_turn_completed =
      loop_events
      |> Enum.filter(&(event_field(&1, :type) == :turn_completed))
      |> List.last()

    turn_completed? = last_loop != nil and last_loop == last_turn_completed
    needs_input? = live_approval_block(model) != nil

    cost =
      last_turn_completed && payload_field(last_turn_completed, "cost", :cost)

    {running_tool, last_item_type} = item_phase_inputs(last_loop)

    status =
      model.status
      |> Map.put(:turn_stage, last_loop && event_field(last_loop, :type))
      |> Map.put(:running_tool, running_tool)
      |> Map.put(:last_item_type, last_item_type)
      |> Map.put(:turn_completed, turn_completed?)
      |> Map.put(:needs_input, needs_input?)
      |> Map.put(:cost, cost)
      |> maybe_put_now(now, last_loop)

    %{model | status: status}
  end

  defp item_phase_inputs(last_loop) do
    if last_loop != nil and event_field(last_loop, :type) == :item_completed do
      item_type =
        case payload_field(last_loop, "item_type", :item_type) do
          type when is_atom(type) and type != nil -> type
          type when is_binary(type) -> Map.get(@item_type_atoms, type, type)
          _other -> nil
        end

      running_tool =
        if item_type == :tool_use do
          case payload_field(last_loop, "name", :name) do
            name when is_binary(name) and name != "" -> name
            _other -> nil
          end
        end

      {running_tool, item_type}
    else
      {nil, nil}
    end
  end

  defp maybe_put_now(status, nil, _last_loop), do: status

  defp maybe_put_now(status, now, last_loop) when is_integer(now) do
    status
    |> Map.put(:now, now)
    |> Map.put(
      :last_event_at,
      if(last_loop, do: now, else: Map.get(status, :last_event_at))
    )
  end

  defp event_field(event, key), do: Map.get(event, key)

  defp payload_field(event, str_key, atom_key) do
    case Map.get(event, :payload) do
      %{} = payload -> Map.get(payload, str_key, Map.get(payload, atom_key))
      _ -> Map.get(event, atom_key)
    end
  end

  # ── unread divider (surface.ex:3701-3716, pure) ──────────────────────────

  defp reconcile_unread(model),
    do: %{
      model
      | unread: UnreadDivider.reconcile(model.unread, unread_offset(model))
    }

  defp unread_offset(model), do: length(model.projection.blocks)

  # ── tick (surface.ex:1574, minus paint/heal) ─────────────────────────────

  @doc "Advances the elapsed ticker and the running-tool spinner. `now` is data."
  @spec tick(t(), integer()) :: t()
  def tick(model, now) when is_integer(now) do
    model
    |> put_in([Access.key!(:status), :now], now)
    |> bump_spinner()
  end

  # ── batch fold (the {:batch, items} live path) ───────────────────────────

  @doc """
  Folds one `{:batch, items}` message: appends each event and advances the
  reveal frontier, then folds the lifecycle bracket; seals a LOUD honest
  marker for any loss / malformed / unrecognized element (`PumpContract`
  §5 — never silently drop).
  """
  @spec fold_batch(t(), [term()]) :: t()
  def fold_batch(model, items) when is_list(items),
    do: Enum.reduce(items, model, &fold_batch_item/2)

  defp fold_batch_item({:event, map}, model) when is_map(map) do
    model
    |> append_events([map])
    |> advance(nil)
    |> fold_lifecycle(map)
  end

  defp fold_batch_item({:cadence_dropped, n}, model) when is_integer(n),
    do:
      seal_marker(
        model,
        "» #{n} event(s) dropped under render load — transcript gap here"
      )

  defp fold_batch_item({:malformed_event}, model),
    do: seal_marker(model, "» malformed session event rejected at the boundary")

  defp fold_batch_item(other, model),
    do:
      seal_marker(
        model,
        "» unrecognized stream element dropped: #{inspect(other)}"
      )

  @doc "Appends live events to the held list (raises on a non-map, a caller bug)."
  @spec append_events(t(), [map()]) :: t()
  def append_events(model, events) when is_list(events) do
    Enum.each(events, fn
      event when is_map(event) ->
        :ok

      other ->
        raise ArgumentError,
              "append_events expects event maps, got: #{inspect(other)}"
    end)

    %{model | events: model.events ++ events}
  end

  # The turn-bracket / interrupt-ack / approval fold (surface driver
  # apply_lifecycle). Belief fields (current_turn_id/activity) update here.
  defp fold_lifecycle(model, %{type: :turn_started} = event) do
    model
    |> submit_accepted()
    |> put_lane_notice(nil)
    |> set_activity(:generating)
    |> Map.put(:current_turn_id, Map.get(event, :turn_id))
  end

  defp fold_lifecycle(model, %{type: :turn_completed} = event) do
    final? = final_turn_completed?(event)

    model
    |> flush_held()
    |> compact_sealed_turns()
    |> set_activity(if(final?, do: :idle, else: :generating))
    |> Map.put(
      :current_turn_id,
      if(final?, do: nil, else: model.current_turn_id)
    )
  end

  defp fold_lifecycle(model, %{type: :turn_canceled} = event) do
    model
    |> flush_held()
    |> compact_sealed_turns()
    |> put_lane_notice("» turn #{inspect(Map.get(event, :turn_id))} canceled")
    |> set_activity(:idle)
    |> Map.put(:current_turn_id, nil)
  end

  defp fold_lifecycle(model, %{type: :interrupt_signaled}),
    do:
      put_lane_notice(
        model,
        "» interrupt signaled — waiting for the tool to stop"
      )

  defp fold_lifecycle(model, %{type: :interrupt_kill_failed}),
    do:
      put_lane_notice(
        model,
        "» interrupt kill NOT confirmed — check the session journal"
      )

  defp fold_lifecycle(model, _event), do: model

  defp final_turn_completed?(event),
    do: payload_field(event, "final", :final) != false

  # Compaction is a live-session memory optimization (dropping already-
  # sealed retired-turn events + reprojecting survivors). It is a NO-OP
  # under fixture monotone growth (surface.ex:1709 comment) and is deferred
  # to U6 with the live pump wiring — the non-compacting path is correct
  # (indices stay monotone), only heavier for long live sessions.
  @doc false
  @spec compact_sealed_turns(t()) :: t()
  def compact_sealed_turns(model), do: model

  # ── stream lifecycle folds (surface.ex, minus paint) ─────────────────────

  @doc "Seals every still-held block (session/feed death): held tail lands in history."
  @spec close_stream(t()) :: t()
  def close_stream(model) do
    %{model | stream_open?: false, debug_highlight: nil}
    |> seal_pending()
  end

  @doc "Per-turn release of the fold-before-seal hold, leaving the stream open."
  @spec flush_held(t()) :: t()
  def flush_held(model) do
    open? = model.stream_open?

    model
    |> Map.put(:stream_open?, false)
    |> seal_pending()
    |> Map.put(:stream_open?, open?)
  end

  @doc "Sets/clears the persistent footer lane notice."
  @spec put_lane_notice(t(), String.t() | [String.t()] | nil) :: t()
  def put_lane_notice(model, text), do: %{model | lane_notice: text}

  @doc "Sets/clears the display-only footer-group debug highlight (unknown group clears)."
  @spec put_debug_highlight(t(), atom() | nil) :: t()
  def put_debug_highlight(model, group) when group in @debug_highlight_groups,
    do: %{model | debug_highlight: group}

  def put_debug_highlight(model, _nil_or_unknown),
    do: %{model | debug_highlight: nil}

  @doc "Sets/clears the status strip's stall verdict seam."
  @spec put_stall_verdict(t(), map() | nil) :: t()
  def put_stall_verdict(model, nil),
    do: %{model | status: Map.delete(model.status, :stall_verdict)}

  def put_stall_verdict(model, verdict),
    do: %{model | status: Map.put(model.status, :stall_verdict, verdict)}

  @doc "Raises/clears the turn-in-flight activity flag."
  @spec set_activity(t(), atom() | nil) :: t()
  def set_activity(model, activity)
      when activity in [:generating, :running_tool, :responding, :idle, nil],
      do: %{model | status: Map.put(model.status, :activity, activity)}

  @doc "Seals one honest plain marker line into history (loss/boot honesty)."
  @spec seal_marker(t(), String.t()) :: t()
  def seal_marker(model, text) when is_binary(text) do
    %{
      model
      | transcript_records: [{:marker, text} | model.transcript_records],
        sealed_any?: true,
        last_sealed_kind: nil
    }
  end

  @doc "Seals a list of boot-POST lines (non-binary entries seal as inspect/1)."
  @spec seal_lines(t(), [term()]) :: t()
  def seal_lines(model, lines) when is_list(lines) do
    Enum.reduce(lines, model, fn line, m ->
      seal_marker(m, if(is_binary(line), do: line, else: inspect(line)))
    end)
  end

  # ── submit accept/refuse (event-observed, surface.ex:2108/2196) ──────────

  @doc "The event-observed submit accept: seals the prompt echo and clears pending_submit."
  @spec submit_accepted(t()) :: t()
  def submit_accepted(%{pending_submit: %{text: text}} = model) do
    %{
      model
      | transcript_records: [{:echo, text} | model.transcript_records],
        sealed_any?: true,
        last_sealed_kind: nil,
        pending_submit: nil
    }
  end

  def submit_accepted(model), do: model

  @doc "The submit refuse: restores the draft into the composer, clears pending_submit."
  @spec submit_refused(t()) :: t()
  def submit_refused(%{pending_submit: %{text: text}} = model) do
    %{
      model
      | composer: Composer.set_value(model.composer, text),
        pending_submit: nil
    }
  end

  def submit_refused(model), do: model

  # ── resize (surface.ex:5451, minus authority) ────────────────────────────

  @doc "Adopts new geometry, re-widths the composer, force-closes an unhostable overlay."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(model, width, rows) when is_integer(width) and is_integer(rows) do
    model = %{model | width: width, rows: rows}

    model = %{
      model
      | composer: Composer.set_width(model.composer, content_width(model))
    }

    if overlay_fits?(model), do: model, else: %{model | overlay: nil}
  end

  # A minimal overlay needs a border + title + one row; below that we close.
  defp overlay_fits?(%{overlay: nil}), do: true
  defp overlay_fits?(%{rows: rows, width: width}), do: rows >= 6 and width >= 24

  # ── result-message folds (PumpContract §4/§5) ────────────────────────────

  @doc false
  def submit_result(model, :ok), do: model

  def submit_result(model, {:error, reason}) do
    model
    |> submit_refused()
    |> put_lane_notice("» submit refused: #{inspect(reason)}")
  end

  @doc false
  def steer_result(model, result) do
    model = %{model | steer_in_flight?: false}
    put_lane_notice(model, steer_notice(result))
  end

  defp steer_notice({:ok, {:accepted, _ref}}), do: "» steer accepted"

  defp steer_notice({:ok, {:duplicate, _ref}}),
    do: "» steer already queued (duplicate)"

  defp steer_notice({:error, :no_live_turn}),
    do: "» steer ignored — no live turn"

  defp steer_notice({:error, :steer_in_flight}), do: @steer_in_flight_notice

  defp steer_notice({:error, {:timeout, ms}}),
    do: "» steer timed out after #{ms}ms"

  defp steer_notice({:error, {:crashed, reason}}),
    do: "» steer crashed: #{inspect(reason)}"

  defp steer_notice({:error, reason}), do: "» steer failed: #{inspect(reason)}"

  @doc false
  def interrupt_result(model, :ok),
    do: put_lane_notice(model, @interrupt_sent_notice)

  def interrupt_result(model, {:error, reason}),
    do:
      put_lane_notice(model, "» interrupt dispatch failed: #{inspect(reason)}")

  @doc false
  def approval_answer_result(model, :ok),
    do: put_lane_notice(model, @approval_sent_notice)

  def approval_answer_result(model, {:error, reason}),
    do:
      put_lane_notice(
        model,
        "» approval answer dispatch failed: #{inspect(reason)}"
      )

  @doc false
  def editor_result(model, {:ok, %{text: text} = outcome}) do
    model
    |> Map.put(:composer, Composer.set_value(model.composer, text))
    |> maybe_degraded_notice(Map.get(outcome, :degraded, []))
  end

  def editor_result(model, {:kept, reason, outcome}) do
    model
    |> put_lane_notice("» editor draft kept (#{inspect(reason)})")
    |> maybe_degraded_notice(Map.get(outcome, :degraded, []))
  end

  def editor_result(model, {:error, reason}),
    do: put_lane_notice(model, "» editor suspend aborted: #{inspect(reason)}")

  defp maybe_degraded_notice(model, []), do: model

  defp maybe_degraded_notice(model, _degraded),
    do: put_lane_notice(model, @degraded_notice)

  @doc false
  def session_down(model, reason) do
    model
    |> close_stream()
    |> put_lane_notice(
      "» session process exited (#{inspect(reason)}) — transcript above is preserved; q quits"
    )
    |> Map.put(:session_over?, true)
  end

  @doc false
  def feed_down(model, :subscribe, reason),
    do:
      put_lane_notice(
        model,
        "» could not attach to the session stream: #{inspect(reason)}"
      )

  def feed_down(model, source, reason) when source in [:forwarder, :cadence] do
    model
    |> close_stream()
    |> put_lane_notice(
      "» live stream #{source} crashed (#{inspect(reason)}) — no further events will render"
    )
  end

  @doc false
  def stall_verdict(model, verdict) do
    cond do
      Map.get(model.status, :needs_input, false) ->
        put_stall_verdict(model, nil)

      verdict == nil ->
        put_stall_verdict(model, nil)

      Map.get(verdict, :class, nil) == :ok ->
        put_stall_verdict(model, nil)

      true ->
        put_stall_verdict(model, verdict)
    end
  end

  @doc false
  def isig_reasserted(model),
    do: put_lane_notice(model, "» terminal signal handling (-isig) re-asserted")

  # ── input (the {:key, ev} fold — returns {model, directives}) ────────────

  @doc """
  Folds one key event: the quit protocol wraps the Keymap dispatch. Returns
  `{model, directives}` where directives are `Directive.Lane`/`.Editor`
  structs addressed to `model.pump` (or `[]` in fixture mode, where a
  lane-crossing command folds an honest stub notice instead).
  """
  @spec handle_key(t(), term()) :: {t(), [struct()]}
  def handle_key(model, raw_event) do
    norm = InputEvent.normalize(raw_event)

    model = %{
      model
      | unread: UnreadDivider.input_activity(model.unread, unread_offset(model))
    }

    cond do
      quit_on_empty?(model, norm) -> quit(model)
      second_ctrl_c?(model, norm) -> preserve_and_quit(model)
      ctrl_c?(norm) -> {arm_quit(model), []}
      true -> model |> disarm_quit() |> route_key(norm, component_event(raw_event))
    end
  end

  # Components (Composer, Picker) pattern-match `%Event{}` structs, but
  # the live pump path delivers the contract's normalized MAP
  # (PumpContract §4) -- which preserves the original Event in `:raw`
  # (InputEvent.normalize/1 is idempotent, so the map arrives here with
  # `:raw` intact exactly once). Prefer the original struct so a live
  # keystroke drives the same component path a fixture/headless one does;
  # anything else passes through untouched and the components' own total
  # fallbacks degrade on it.
  defp component_event(%Raxol.Core.Events.Event{} = event), do: event
  defp component_event(%{raw: %Raxol.Core.Events.Event{} = original}), do: original
  defp component_event(other), do: other

  defp quit_on_empty?(model, norm),
    do: InputEvent.printable_char(norm) == "q" and composer_empty?(model)

  defp ctrl_c?(%{char: "c", mods: %{ctrl: true}}), do: true
  defp ctrl_c?(_norm), do: false

  defp second_ctrl_c?(model, norm), do: ctrl_c?(norm) and model.quit_armed?

  defp arm_quit(model) do
    notice =
      if composer_empty?(model),
        do: "» ctrl-c again to exit",
        else: "» ctrl-c again to exit — draft preserved in scrollback on quit"

    %{model | quit_armed?: true, lane_notice: notice}
  end

  defp disarm_quit(%{quit_armed?: true} = model),
    do: %{model | quit_armed?: false, lane_notice: nil}

  defp disarm_quit(model), do: model

  defp quit(model), do: {model, halt_directives(model)}

  defp preserve_and_quit(model) do
    draft = Composer.value(model.composer) || ""

    model =
      if String.trim(draft) == "",
        do: model,
        else:
          seal_marker(
            model,
            "» exited with an unsent draft — preserved:\n" <> draft
          )

    {model, halt_directives(model)}
  end

  defp halt_directives(%{pump: nil}), do: []
  defp halt_directives(%{pump: pump}), do: [Directive.halt(pump)]

  defp composer_empty?(model),
    do: (Composer.value(model.composer) || "") |> String.trim() == ""

  defp route_key(model, norm, raw_event) do
    case Keymap.resolve(norm, keymap_context(model)) do
      :passthrough -> route_passthrough(model, norm, raw_event)
      command -> dispatch_command(model, command)
    end
  end

  defp keymap_context(model) do
    %{
      composing?: model.composing?,
      streaming?: not Map.get(model.status, :turn_completed, false),
      focused_block_id: model.focused_index,
      overlay_open?: model.overlay != nil,
      approval_pending?: live_approval_block(model) != nil,
      composer_empty?: composer_empty?(model)
    }
  end

  # -- passthrough routing (overlay / expansion / composer) ----------------

  defp route_passthrough(%{overlay: {:picker, state}} = model, _norm, raw_event) do
    {new_state, messages} = Picker.handle_event(raw_event, state, %{})
    model = %{model | overlay: {:picker, new_state}}
    {Enum.reduce(messages, model, &apply_picker_message/2), []}
  end

  defp route_passthrough(%{overlay: {:panel, _kind}} = model, norm, _raw_event) do
    if InputEvent.key(norm) == :escape or InputEvent.printable_char(norm) == "q",
      do: {close_overlay(model), []},
      else: {model, []}
  end

  defp route_passthrough(
         %{overlay: {:expansion, exp}} = model,
         norm,
         _raw_event
       ) do
    model =
      cond do
        InputEvent.printable_char(norm) == "j" or InputEvent.key(norm) == :down ->
          %{model | overlay: {:expansion, scroll_expansion(exp, 1)}}

        InputEvent.printable_char(norm) == "k" or InputEvent.key(norm) == :up ->
          %{model | overlay: {:expansion, scroll_expansion(exp, -1)}}

        InputEvent.printable_char(norm) == "q" or
            InputEvent.key(norm) == :escape ->
          close_overlay(model)

        true ->
          model
      end

    {model, []}
  end

  defp route_passthrough(%{composing?: true} = model, _norm, raw_event) do
    {composer, commands} = Composer.handle_event(raw_event, model.composer, %{})

    Enum.reduce(
      commands,
      {%{model | composer: composer}, []},
      &apply_composer_command/2
    )
  end

  defp route_passthrough(model, _norm, _raw_event), do: {model, []}

  defp apply_picker_message({:component_event, _id, {:select, item}}, model),
    do: %{close_overlay(model) | lane_notice: "» picked: #{inspect(item)}"}

  defp apply_picker_message({:component_event, _id, :cancel}, model),
    do: close_overlay(model)

  defp apply_picker_message(_other, model), do: model

  defp scroll_expansion(exp, delta),
    do: %{exp | scroll_top: max((exp.scroll_top || 0) + delta, 0)}

  # The composer's Enter emits {:submit, text}: the busy-gate lives in the
  # model now (current_turn_id / needs-input). Blocked -> refuse; idle ->
  # a submit directive (or a stub notice in fixture mode).
  defp apply_composer_command(
         {:component_event, _id, {:submit, text}},
         {model, cmds}
       ) do
    cond do
      String.trim(to_string(text)) == "" ->
        {model, cmds}

      submit_blocked?(model) ->
        {model |> submit_refused() |> put_lane_notice(@busy_notice), cmds}

      model.pump ->
        {%{model | pending_submit: %{text: text}},
         cmds ++ [Directive.submit(model.pump, text)]}

      true ->
        {%{model | stub_notice: "» (stub) would send prompt: #{text}"}, cmds}
    end
  end

  defp apply_composer_command(_other, acc), do: acc

  defp submit_blocked?(model),
    do:
      model.current_turn_id != nil or Map.get(model.status, :needs_input, false)

  # ── command dispatch (surface.ex:3180-3399) ──────────────────────────────

  # Lane-crossing commands -> Directives (or stub notices in fixture mode).
  defp dispatch_command(model, %{type: :interrupt}),
    do:
      lane_or_stub(
        model,
        &Directive.interrupt(&1, model.current_turn_id),
        "» (stub) would interrupt the turn"
      )

  defp dispatch_command(model, %{type: :steer}) do
    if model.steer_in_flight? do
      {put_lane_notice(model, @steer_in_flight_notice), []}
    else
      text = Composer.value(model.composer) || ""

      composer =
        Composer.update(
          {:set_queued_steer, %{text: text, queued_at: model.revealed}},
          model.composer
        )
        |> elem(0)

      model = %{model | composer: composer, steer_in_flight?: true}

      if model.pump,
        do: {model, [Directive.steer(model.pump, text, model.current_turn_id)]},
        else:
          {%{
             model
             | steer_in_flight?: false,
               stub_notice: "» (stub) would steer: #{text}"
           }, []}
    end
  end

  defp dispatch_command(model, %{type: :approval_answer, payload: payload}) do
    case resolve_approval_answer(model, Map.get(payload, :answer)) do
      {:ok, answer} ->
        lane_or_stub(
          model,
          &Directive.approval_answer(&1, answer),
          "» (stub) would answer the approval"
        )

      {:error, reason} ->
        {put_lane_notice(model, approval_refusal_notice(reason)), []}
    end
  end

  defp dispatch_command(model, %{type: :edit_draft}) do
    if model.pump and model.overlay == nil,
      do:
        {model,
         [
           Directive.edit_draft(
             model.pump,
             Composer.value(model.composer) || ""
           )
         ]},
      else: {model, []}
  end

  # Pure model changes (no directive).
  defp dispatch_command(model, %{type: :overlay_dismiss}),
    do: {close_overlay(model), []}

  defp dispatch_command(model, %{type: :expand_diff, payload: payload}),
    do: {open_expansion(model, Map.get(payload, :block_id)), []}

  defp dispatch_command(model, %{type: :fold_toggle, payload: payload}),
    do: {apply_fold_toggle(model, Map.get(payload, :block_id)), []}

  defp dispatch_command(model, %{type: :jump_next}),
    do: {move_focus(model, 1), []}

  defp dispatch_command(model, %{type: :jump_prev}),
    do: {move_focus(model, -1), []}

  defp dispatch_command(model, %{type: :open_palette}),
    do: {open_picker(model), []}

  defp dispatch_command(model, %{type: :open_jump_picker}),
    do: {open_picker(model), []}

  defp dispatch_command(model, %{type: :open_session_picker}),
    do: {open_picker(model), []}

  defp dispatch_command(model, %{type: :open_search_picker}),
    do: {open_picker(model), []}

  defp dispatch_command(model, %{type: :open_panel, payload: %{panel: kind}}),
    do: {open_panel(model, kind), []}

  defp dispatch_command(model, %{type: :focus_transcript}),
    do: {%{model | composing?: false}, []}

  defp dispatch_command(model, %{type: :focus_composer}),
    do: {focus_composer(model), []}

  defp dispatch_command(model, %{type: :scroll_up}),
    do: {scroll_page(model, :up), []}

  defp dispatch_command(model, %{type: :scroll_down}),
    do: {scroll_page(model, :down), []}

  defp dispatch_command(model, %{type: :scroll_to_tail}),
    do: {%{model | scroll_anchor: :tail}, []}

  defp dispatch_command(model, _other), do: {model, []}

  defp lane_or_stub(%{pump: nil} = model, _fun, stub_notice),
    do: {%{model | stub_notice: stub_notice}, []}

  defp lane_or_stub(%{pump: pump} = model, fun, _stub_notice),
    do: {model, [fun.(pump)]}

  # -- approval answer resolution (surface.ex:2986, pure) ------------------

  @doc false
  def resolve_approval_answer(model, hint) do
    case live_approval_block(model) do
      nil ->
        {:error, :no_live_approval}

      block ->
        options = Map.get(block.content, :options, [])

        case answer_option(options, hint) do
          {:ok, option_id, decision} ->
            {:ok,
             %{
               request_id: Map.get(block.content, :request_id),
               option_id: option_id,
               decision: decision
             }}

          {:error, _reason} = err ->
            err
        end
    end
  end

  defp answer_option(options, {:option, index})
       when is_list(options) and is_integer(index) do
    case Enum.at(options, index) do
      nil -> {:error, :no_such_option}
      option -> {:ok, option_id_of(option), decision_of(option)}
    end
  end

  defp answer_option(options, decision)
       when is_list(options) and decision in [:allow, :deny] do
    case Enum.find(options, &(decision_of(&1) == decision)) do
      nil -> {:error, :no_matching_option}
      option -> {:ok, option_id_of(option), decision}
    end
  end

  defp answer_option(_options, _hint), do: {:error, :unanswerable}

  defp option_id_of(%{option_id: id}), do: id
  defp option_id_of(%{"option_id" => id}), do: id
  defp option_id_of(option) when is_binary(option), do: option
  defp option_id_of(_option), do: nil

  defp decision_of(%{kind: kind}), do: decision_from_kind(kind)
  defp decision_of(%{"kind" => kind}), do: decision_from_kind(kind)
  defp decision_of(_option), do: :deny

  defp decision_from_kind(kind)
       when kind in [:allow_once, :allow_always, "allow_once", "allow_always"],
       do: :allow

  defp decision_from_kind(kind)
       when kind in [
              :reject_once,
              :reject_always,
              "reject_once",
              "reject_always"
            ],
       do: :deny

  defp decision_from_kind(_kind), do: :deny

  defp approval_refusal_notice(:no_live_approval),
    do: "» no approval is awaiting an answer"

  defp approval_refusal_notice(:no_such_option), do: "» no such approval option"

  defp approval_refusal_notice(:no_matching_option),
    do: "» this approval offers no such choice"

  defp approval_refusal_notice(_reason), do: "» cannot answer that approval"

  # -- overlays (the U3 tagged-tuple model, hosted as layout children) -----

  @commands [
    "Approve the pending tool call",
    "Reject the pending tool call",
    "Steer the current turn",
    "Interrupt the running turn",
    "Compact the transcript"
  ]

  defp open_picker(model) do
    {:ok, state} =
      Picker.init(
        id: "overlay-picker",
        items: @commands,
        key_fn: & &1,
        placeholder: "type to filter commands",
        visible_height: max(model.rows - 8, 1)
      )

    %{model | overlay: {:picker, state}}
  end

  defp open_panel(model, kind), do: %{model | overlay: {:panel, kind}}

  defp open_expansion(model, block_id) do
    case focused_diff_block(model, block_id) do
      nil ->
        %{model | stub_notice: "» no diff to expand — focus a diff block first"}

      index ->
        %{model | overlay: {:expansion, %{block_index: index, scroll_top: 0}}}
    end
  end

  defp focused_diff_block(model, block_id) do
    index = block_id || model.focused_index

    with true <- is_integer(index),
         %{kind: :diff} <- Enum.at(model.projection.blocks, index) do
      index
    else
      _ -> nil
    end
  end

  defp close_overlay(model), do: %{model | overlay: nil}

  # -- fold toggle / focus / scroll (surface.ex:3604-3674, 3405) -----------

  defp apply_fold_toggle(model, nil),
    do: %{model | stub_notice: "» no block focused — jump to a block first (g)"}

  defp apply_fold_toggle(model, index) when is_integer(index) do
    if block_sealed?(model, index) do
      %{model | stub_notice: "» block #{index} sealed — fold unavailable"}
    else
      store_fold_override(model, index)
    end
  end

  defp store_fold_override(model, index) do
    case Enum.at(model.projection.blocks, index) do
      nil ->
        model

      block ->
        current = Map.get(model.fold_overrides, index, block.fold)

        %{
          model
          | fold_overrides:
              Map.put(model.fold_overrides, index, toggle_fold(current))
        }
    end
  end

  defp toggle_fold(:folded), do: :expanded
  defp toggle_fold(:expanded), do: :folded

  defp move_focus(model, delta) do
    total = length(model.projection.blocks)

    if total == 0 do
      model
    else
      current = model.focused_index || if delta > 0, do: -1, else: total
      next = (current + delta) |> max(0) |> min(total - 1)

      %{
        model
        | focused_index: next,
          unread: UnreadDivider.viewed(model.unread, next)
      }
    end
  end

  defp focus_composer(model),
    do: %{
      model
      | composing?: true,
        composer: Composer.update(%{focused: true}, model.composer) |> elem(0)
    }

  # Page the record-anchored scroll window one page up/down. `scroll_anchor`
  # is `:tail | pos_integer` (1-based record index at the window bottom);
  # the view's row-aware windowing fills upward from it. A record-granular
  # page (the exact row height lives in the view, which re-clamps every
  # render — law 7 follow/preserve holds there).
  defp scroll_page(model, dir) do
    total = length(model.transcript_records)
    page = max(div(model.rows, 2), 1)

    if total == 0 do
      %{model | scroll_anchor: :tail}
    else
      current =
        case model.scroll_anchor do
          :tail -> total
          n when is_integer(n) -> n |> max(1) |> min(total)
        end

      new_bottom =
        case dir do
          :up -> max(current - page, 1)
          :down -> min(current + page, total)
        end

      anchor = if new_bottom >= total, do: :tail, else: new_bottom
      %{model | scroll_anchor: anchor}
    end
  end

  # ── accessors (for the view) ─────────────────────────────────────────────

  @doc "Everything revealed AND everything sealed."
  @spec done?(t()) :: boolean()
  def done?(model),
    do:
      model.revealed >= length(model.events) and
        model.painted_count >= length(model.projection.blocks)

  @doc "Whether a block index is sealed into history (below the painted cursor)."
  @spec sealed?(t(), integer()) :: boolean()
  def sealed?(model, index), do: block_sealed?(model, index)
end
