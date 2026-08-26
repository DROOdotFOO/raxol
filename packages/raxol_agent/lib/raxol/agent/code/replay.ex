defmodule Raxol.Agent.Code.Replay do
  @moduledoc """
  Headless replay of a saved coding-agent session: fold its durable
  journal through `Raxol.Harness.Projection` and render the resulting
  transcript as plain text.

  The offset-addressed journal (`~/.raxol/sessions/<id>/journal/`) is the
  primary source, so `:to_offset` replays a prefix by journal offset.
  Sessions recorded before the TUI journaled (or whose journal is gone)
  fall back to the JSON session store; store events are renumbered
  densely, so an offset bound there selects the first N events.

  Read-side only: the journal is read through the tolerant Reader
  (writerless-safe), never opened for writing, so replaying cannot
  disturb a live session.
  """

  alias Raxol.Agent.Code.EventCodec
  alias Raxol.Agent.Code.Store
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Harness.Projection
  alias Raxol.UI.Components.Harness.Block

  # Mirrors the journal's session-id charset: an id is also an on-disk
  # directory name and must not traverse out of the base dir.
  @session_id_re ~r/\A[A-Za-z0-9._-]+\z/

  @doc """
  Replay `session_id` to a plain-text transcript.

  Options: `:to_offset` (replay only events with id at or below the
  bound), `:base_dir` (journal base, tests), `:store_dir` (session store
  dir, tests).
  """
  @spec run(String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def run(session_id, opts \\ []) when is_binary(session_id) do
    with :ok <- validate_id(session_id),
         {:ok, source, events} <- load_events(session_id, opts) do
      projection = Projection.project(events)
      {:ok, render(session_id, source, events, projection)}
    end
  end

  defp validate_id(id) do
    if id not in [".", ".."] and Regex.match?(@session_id_re, id) do
      :ok
    else
      {:error, "invalid session id: #{inspect(id)}"}
    end
  end

  defp load_events(session_id, opts) do
    case FileStore.read_records(session_id, Keyword.take(opts, [:base_dir])) do
      {:ok, []} ->
        store_events(session_id, opts)

      {:ok, records} ->
        {:ok, :journal, decode_records(records, to_offset: Keyword.get(opts, :to_offset))}

      {:error, :damaged} ->
        {:error, "session #{session_id}: journal damaged — nothing safely replayable"}
    end
  end

  # `:to_offset` means "the journal as of offset N", so it applies before
  # rewind markers: a bound below a marker's offset replays the state the
  # marker had not yet rewound.
  defp bound_records(records, nil), do: records

  defp bound_records(records, to_offset) when is_integer(to_offset),
    do: Enum.filter(records, &(&1["id"] <= to_offset))

  # Only event-kind records replay; a missing kind grandfathers to
  # "event" (the same rule `Journal.Tip` applies). Checkpoint pointers and
  # other non-event kinds carry no foldable payload.
  defp event_record?(record),
    do: Map.get(record, "kind", "event") == "event"

  # A meta `:rewind` marker (written by the TUI's /rewind) drops the
  # CONTIGUOUS trailing run of records carrying the turn it names — the
  # same rule the live rewind applies. Turn ids are only unique within
  # one VM run, so a global turn_id match could destroy an unrelated
  # older turn that happens to share the id; the trailing-run rule stops
  # at the first non-matching record. The marker itself never renders.
  defp apply_rewinds(records) do
    records
    |> Enum.reduce([], fn
      %{"family" => "meta", "type" => "rewind"} = marker, acc ->
        # acc is reversed (latest first), so the trailing run is its head.
        dropped_turn = get_in(marker, ["payload", "dropped_turn"])
        Enum.drop_while(acc, &(&1["turn_id"] == dropped_turn))

      record, acc ->
        [record | acc]
    end)
    |> Enum.reverse()
  end

  defp store_events(session_id, opts) do
    dir = Keyword.get(opts, :store_dir) || Store.default_dir()

    case Store.load(dir, session_id) do
      {:ok, %{events: events}} ->
        events = events |> renumber() |> bound(Keyword.get(opts, :to_offset))
        {:ok, :store, events}

      {:error, :not_found} ->
        {:error, "session #{session_id} not found (no journal, no saved session)"}
    end
  end

  # Store ids are whatever the producer stamped at save time; renumbering
  # into the dense position space keeps the projection's id recovery quiet
  # and gives `:to_offset` a stable meaning (first N events).
  defp renumber(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, index} -> %{event | id: index} end)
  end

  defp bound(events, nil), do: events

  defp bound(events, to_offset) when is_integer(to_offset),
    do: Enum.filter(events, &(&1.id <= to_offset))

  @doc """
  Fold raw journal records (string-keyed, as `FileStore.read_records/2`
  returns them) into decoded, replay-ready projection events: offset
  bound applied first, then rewind markers, non-event kinds dropped,
  and dense renumbering (rewind gaps are history, not damage). Shared
  by `run/2` and any live consumer of the same journal (the share
  LiveView).
  """
  @spec decode_records([map()], keyword()) :: [map()]
  def decode_records(records, opts \\ []) do
    records
    |> bound_records(Keyword.get(opts, :to_offset))
    |> apply_rewinds()
    |> Enum.filter(&event_record?/1)
    |> EventCodec.decode_all()
    |> renumber()
  end

  @doc """
  Render already-decoded projection events as the plain-text transcript
  body (no header) — shared by `run/2`, the TUI's `/export`, and
  `/transcript`.
  """
  @spec transcript_text([map()]) :: String.t()
  def transcript_text(events) do
    projection = Projection.project(events)

    case transcript(events, projection) do
      [] -> "(no replayable events)"
      lines -> lines |> Enum.join("\n") |> String.trim_leading()
    end
  end

  # -- rendering --------------------------------------------------------------

  defp render(session_id, source, events, projection) do
    header =
      "session #{session_id} · #{source} · #{length(events)} events" <>
        damaged_note(projection)

    case transcript(events, projection) do
      [] -> Enum.join([header, "", "(no replayable events)"], "\n")
      lines -> Enum.join([header | lines], "\n")
    end
  end

  defp damaged_note(%Projection{damaged: true}),
    do: " · damaged (forward id gap — partial transcript)"

  defp damaged_note(_projection), do: ""

  # Blocks carry no turn marker, but their event refs resolve to events
  # that do — group them per turn so each user prompt (from the turn's
  # `turn_started`, which is structural and never a block) heads its
  # turn's activity.
  defp transcript(events, projection) do
    turn_of = Map.new(events, fn event -> {event.id, event.turn_id} end)

    blocks_by_turn =
      Enum.group_by(projection.blocks, fn block ->
        block.event_refs
        |> List.wrap()
        |> Enum.find_value(&Map.get(turn_of, &1))
      end)

    prompts =
      for %{type: :turn_started} = event <- events,
          into: %{},
          do: {event.turn_id, prompt_of(event)}

    turn_order =
      events |> Enum.map(& &1.turn_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    turn_lines =
      Enum.flat_map(turn_order, fn turn_id ->
        prompt_lines(Map.get(prompts, turn_id)) ++
          block_lines(Map.get(blocks_by_turn, turn_id, []))
      end)

    turn_lines ++ block_lines(Map.get(blocks_by_turn, nil, []))
  end

  defp prompt_of(%{payload: payload}) when is_map(payload),
    do: to_string(Map.get(payload, "prompt") || Map.get(payload, :prompt) || "")

  defp prompt_of(_event), do: ""

  defp prompt_lines(nil), do: []
  defp prompt_lines(""), do: []
  defp prompt_lines(prompt), do: ["", "> " <> prompt]

  defp block_lines(blocks) when is_list(blocks),
    do: Enum.flat_map(blocks, &block_lines/1)

  defp block_lines(%Block{kind: :message} = block), do: [text_of(block)]

  defp block_lines(%Block{kind: :reasoning} = block),
    do: ["[reasoning] " <> text_of(block)]

  defp block_lines(%Block{kind: :tool_call} = block) do
    name = to_string(block.content[:name] || "tool")
    ["[tool] #{name}#{outcome_note(block.outcome)}"]
  end

  defp block_lines(%Block{kind: :approval} = block),
    do: ["[approval] #{to_string(block.content[:name] || "")}"]

  defp block_lines(%Block{kind: :diff} = block),
    do: ["[diff] " <> text_of(block)]

  defp block_lines(%Block{kind: :opaque} = block),
    do: ["[#{inspect(block.raw_kind)}] " <> text_of(block)]

  defp text_of(%Block{content: content}),
    do: to_string(content[:text] || "")

  defp outcome_note(%{exit_code: nil, duration_ms: nil}), do: ""

  defp outcome_note(%{exit_code: exit_code, duration_ms: duration_ms}) do
    parts =
      Enum.reject(
        [
          exit_code && "exit #{exit_code}",
          duration_ms && "#{duration_ms}ms"
        ],
        &(&1 in [nil, false])
      )

    case parts do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end
end
