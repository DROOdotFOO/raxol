defmodule Raxol.Harness.PanelProjection do
  @moduledoc """
  Pure read-model fold over `extract` meta events, for the harness's
  worktracks/memory/plan overlay panels.

  ## Frozen contract vs. contract-shape assumption

  This module builds against the **frozen** meta-event contract shapes: the
  `extract` entry in `Raxol.Agent.Meta.Registry` (required payload keys
  `[:class, :op, :item, :refs]`, scope `:session`), and against contract-
  shape fixtures authored to that registry
  (`test/fixtures/harness/sessions/projection-panels.jsonl`). The registry
  entry is load-bearing and settled. The per-class `item` field shapes this
  module reads (worktracks: `id`/`lane`/`title`/`status`; memory:
  `key`/`value`; plan: `id`/`title`/`status`) are **contract-shape
  ASSUMPTIONS** — they must be verified against real agent-emitted `extract`
  events before this unit's PR merges. Nothing here should be read as ground
  truth for the wire shape until that verification happens.

  ## Tolerant reading

  An unknown `class`, unknown `op`, unrecognized `type`, or a missing/
  malformed field is **skipped, never an error** — a single unrecognized
  meta event must not take down the whole fold. This is deliberate: a
  malformed instance of a *known* shape found in a real journal (e.g. an
  `extract` whose `op` is `"add"` but whose `item` is a string) is a defect
  to report against the emitting codec, never something to silently work
  around inside this module. "Skip" here only ever means "this class/op/
  shape isn't one I know how to read," not "I read it and it was wrong."

  ## Recompute, not incrementally cached

  The read-model is recomputed on demand -- at panel summon and on each
  footer repaint while a panel is open -- not incrementally maintained as
  events arrive. `fold/2` and `render_lines/2` are both `O(events)` per
  paint, matching the surface's existing per-advance full re-projection
  (see `Raxol.Harness.Projection`). "Dismissed is not dead": the fold source
  is the projection's retained *durable* events
  (`Raxol.Harness.Projection.source_events/1`, itself already durable-only),
  so re-summoning a panel folds current state without touching the block
  projection at all.

  ## Clamps

  Two independent clamps guard against hostile or runaway meta-event
  content (meta payloads are agent-produced and untrusted):

    * `@max_field_bytes` -- every string entering a read-model is passed
      through `display_string/1` first: binaries longer than 512 bytes are
      clamped (byte-sliced when that stays valid UTF-8, grapheme-sliced via
      `String.slice/3` otherwise); non-binaries are rendered via
      `inspect/2` with bounded `:limit`/`:printable_limit`, never evaluated
      or atomized. Control bytes are **not** stripped here -- sanitizing
      control bytes for actual terminal rendering is
      `Raxol.Harness.Surface.ViewText`'s trust boundary, downstream of this
      module; stripping them here too would just duplicate that seam
      without adding safety.
    * `@max_entries` -- at most 500 *distinct identities* are retained per
      kind. A 501st distinct identity added evicts the oldest retained
      entry (first-seen order), bounding memory even against a runaway or
      adversarial extract stream.
  """

  @type kind :: :worktracks | :memory | :plan
  @type worktracks_item :: %{title: String.t(), status: String.t()}
  @type worktracks_lane :: %{name: String.t(), items: [worktracks_item()]}
  @type memory_entry :: %{key: String.t(), value: String.t()}
  @type plan_entry :: %{title: String.t(), status: String.t()}

  @max_field_bytes 512
  @max_entries 500

  @doc "The three panel kinds this module folds."
  @spec kinds() :: [kind()]
  def kinds, do: [:worktracks, :memory, :plan]

  @doc """
  Folds `events` (event-shaped maps or `Raxol.Harness.Fixture.Event`
  structs, top-level fields read via `Map.get/2` -- works for both) into
  the `kind` read-model. Only `family: :meta, type: :extract` events with a
  matching `class` contribute; everything else is silently skipped (see
  moduledoc, "Tolerant reading"). Pure and deterministic: identical input
  always yields an identical read-model.
  """
  @spec fold(kind(), [map()]) ::
          [worktracks_lane()] | [memory_entry()] | [plan_entry()]
  def fold(kind, events)
      when kind in [:worktracks, :memory, :plan] and is_list(events) do
    {order, index} =
      events
      |> Enum.filter(&extract_event?/1)
      |> Enum.reduce({[], %{}}, &apply_entry(kind, &1, &2))

    build_read_model(order, index, kind)
  end

  @doc """
  Folds then formats `kind`'s read-model into footer-row lines. Every line
  is newline-flattened (`\\r\\n`/`\\n`/`\\r` -> `" "`) so one read-model
  entry is always exactly one footer row -- the same discipline
  `Raxol.UI.Harness.OverlayPicker` applies to item labels, and load-bearing
  for the same reason: a raw embedded newline here would silently overflow
  a caller's fixed row budget. An empty read-model renders as `["(empty)"]`.
  No width truncation happens here -- `ViewText` owns that, same as
  `OverlayPicker`.
  """
  @spec render_lines(kind(), [map()]) :: [String.t()]
  def render_lines(kind, events) do
    case fold(kind, events) do
      [] ->
        ["(empty)"]

      read_model ->
        read_model |> format_lines(kind) |> Enum.map(&flatten_newlines/1)
    end
  end

  # -- event filtering / dispatch -----------------------------------------

  defp extract_event?(event) do
    Map.get(event, :family) == :meta and Map.get(event, :type) == :extract
  end

  defp apply_entry(kind, event, acc) do
    case Map.get(event, :payload) do
      payload when is_map(payload) -> apply_payload(kind, payload, acc)
      _other -> acc
    end
  end

  defp apply_payload(kind, payload, acc) do
    class = field(payload, "class", :class)

    if class_matches_kind?(class, kind) do
      apply_extract(kind, payload, acc)
    else
      acc
    end
  end

  defp apply_extract(kind, payload, acc) do
    op = normalize_op(field(payload, "op", :op))
    item = field(payload, "item", :item)

    case {op, is_map(item)} do
      {:skip, _} -> acc
      {_op, false} -> acc
      {op, true} -> apply_item(kind, op, item, acc)
    end
  end

  defp apply_item(kind, op, item, acc) do
    case identity_for(kind, item) do
      nil -> acc
      identity -> apply_op(op, identity, item, acc)
    end
  end

  # class comparison never atomizes untrusted input: `Atom.to_string/1` on
  # the KNOWN `kind` atom, `to_string/1` on the untrusted class value
  # (atom-to-string or binary passthrough, never string-to-atom).
  defp class_matches_kind?(class, kind)
       when is_binary(class) or is_atom(class) do
    to_string(class) == Atom.to_string(kind)
  end

  defp class_matches_kind?(_class, _kind), do: false

  defp normalize_op(op) when is_binary(op) or is_atom(op) do
    case to_string(op) do
      "add" -> :add
      "update" -> :update
      "remove" -> :remove
      "delete" -> :remove
      _other -> :skip
    end
  end

  defp normalize_op(_op), do: :skip

  defp identity_for(:worktracks, item),
    do: field(item, "id", :id) || field(item, "title", :title)

  defp identity_for(:memory, item), do: field(item, "key", :key)

  defp identity_for(:plan, item),
    do: field(item, "id", :id) || field(item, "title", :title)

  # -- ordered upsert/update/remove with flood clamp ----------------------

  defp apply_op(:add, identity, item, {order, index}) do
    if Map.has_key?(index, identity) do
      {order, Map.update!(index, identity, &Map.merge(&1, item))}
    else
      {order, index}
      |> put_new_entry(identity, item)
      |> clamp()
    end
  end

  defp apply_op(:update, identity, item, {order, index}) do
    if Map.has_key?(index, identity) do
      {order, Map.update!(index, identity, &Map.merge(&1, item))}
    else
      {order, index}
    end
  end

  defp apply_op(:remove, identity, _item, {order, index}) do
    {List.delete(order, identity), Map.delete(index, identity)}
  end

  defp put_new_entry({order, index}, identity, item) do
    {order ++ [identity], Map.put(index, identity, item)}
  end

  defp clamp({order, index}) when length(order) > @max_entries do
    [oldest | rest] = order
    {rest, Map.delete(index, oldest)}
  end

  defp clamp(acc), do: acc

  # -- field access: string-first, atom-fallback ---------------------------

  defp field(map, string_key, atom_key) when is_map(map) do
    Map.get(map, string_key, Map.get(map, atom_key))
  end

  # -- read-model shaping ---------------------------------------------------

  defp build_read_model(order, index, :worktracks) do
    {lanes_order, lanes_map} =
      Enum.reduce(order, {[], %{}}, fn identity, {lanes_order, lanes_map} ->
        item = Map.fetch!(index, identity)

        lane =
          display_string(
            field(item, "lane", :lane) || field(item, "status", :status) ||
              "todo"
          )

        entry = %{
          title: display_string(field(item, "title", :title) || identity),
          status: display_string(field(item, "status", :status) || "")
        }

        if Map.has_key?(lanes_map, lane) do
          {lanes_order, Map.update!(lanes_map, lane, &(&1 ++ [entry]))}
        else
          {lanes_order ++ [lane], Map.put(lanes_map, lane, [entry])}
        end
      end)

    Enum.map(lanes_order, fn lane ->
      %{name: lane, items: Map.fetch!(lanes_map, lane)}
    end)
  end

  defp build_read_model(order, index, :memory) do
    Enum.map(order, fn identity ->
      item = Map.fetch!(index, identity)

      %{
        key: display_string(identity),
        value: display_string(field(item, "value", :value))
      }
    end)
  end

  defp build_read_model(order, index, :plan) do
    Enum.map(order, fn identity ->
      item = Map.fetch!(index, identity)

      %{
        title: display_string(field(item, "title", :title) || identity),
        status: display_string(field(item, "status", :status) || "")
      }
    end)
  end

  defp format_lines(lanes, :worktracks) do
    Enum.flat_map(lanes, fn %{name: name, items: items} ->
      header = "#{name} (#{length(items)})"

      rows =
        Enum.map(items, fn %{title: title, status: status} ->
          "  #{title} — #{status}"
        end)

      [header | rows]
    end)
  end

  defp format_lines(entries, :memory) do
    Enum.map(entries, fn %{key: key, value: value} -> "#{key}: #{value}" end)
  end

  defp format_lines(entries, :plan) do
    entries
    |> Enum.with_index(1)
    |> Enum.map(fn {%{title: title, status: status}, index} ->
      "#{index}. #{title} [#{status}]"
    end)
  end

  defp flatten_newlines(line),
    do: String.replace(line, ["\r\n", "\n", "\r"], " ")

  # -- hostile-content clamp: length-bounded, never eval'd, never atomized -

  defp display_string(v)
       when is_binary(v) and byte_size(v) > @max_field_bytes do
    candidate = binary_part(v, 0, @max_field_bytes)

    if String.valid?(candidate) do
      candidate
    else
      String.slice(v, 0, @max_field_bytes)
    end
  end

  defp display_string(v) when is_binary(v), do: v

  defp display_string(v), do: inspect(v, limit: 10, printable_limit: 256)
end
