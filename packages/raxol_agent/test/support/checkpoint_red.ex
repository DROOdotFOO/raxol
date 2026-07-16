defmodule Raxol.Agent.Red.CheckpointRed do
  @moduledoc """
  Support for the U9-R red suite (checkpoint pointer records, AD-10/AD-3a).

  Two jobs:

    1. **Independent oracles (meta-inv 6).** Journal truth here comes from a raw
       `File.read!` + this module's OWN framed-line decoder (`raw_records/1`),
       never `FileStore.read/2` and never the Writer's in-memory offset. The
       frozen tip predicate (`conversational?/1`, `tip/1`), the record-layer
       density check (`dense_ids?/1`), tip validity (`valid_tip?/2`), the
       turn-boundary rule (`at_turn_boundary?/1`), `sha256_hex/1`, snapshot
       presence, and a toy deterministic fold (`fold/1`) are all reimplemented
       here so the red assertions cross-check the production seam against an
       oracle that shares no code with it.

    2. **Dead-injectors (meta-inv 1/2).** Fabricators that forge the exact broken
       on-disk / return shapes each negative contour must catch, plus mutant
       predicate/restore functions. The controls suite runs each injector and
       asserts the matching oracle flags it — proving the red is not vacuous. A
       `Counters` fired-counter harness (generic over atoms) records that every
       armed injector fired.

  NOTE (blocked dependency): the freeze wires P-JS4's round-trip against the
  **real MS `Snapshot` codec** (`dump/load/persistent_slice`). That codec is not
  merged on `master`, so `fold/1`/`dump/1`/`load/1` here are a local surrogate
  standing in for it — the round-trip *equation* is exact, but the concrete fold
  must be re-bound to the real MS fold when U9/MS land. Flagged in the suite.
  """

  alias Raxol.Agent.Journal.FileStore

  # The frozen CONVERSATIONAL whitelist (JS-FREEZE §1.1 — the closure rule: this
  # whitelist is the ONLY door into the tip).
  @conversational ~w(
    turn_started item_started item_completed
    turn_completed turn_canceled error approval_requested
  )

  @schema_version "1.0.0"

  @doc "The frozen CONVERSATIONAL type whitelist (string forms)."
  def conversational_types, do: @conversational

  # ---------------------------------------------------------------------------
  # Session / seeding — the REAL Writer/FileStore path
  # ---------------------------------------------------------------------------

  @doc "Open a fresh real FileStore journal under `base`. Returns `{handle, session, dir}`."
  def open!(base, opts \\ []) do
    session = "u9r-#{System.unique_integer([:positive])}"
    {:ok, j} = FileStore.open(session, Keyword.put(opts, :base_dir, base))
    {j, session, Path.join(base, session)}
  end

  @doc """
  A durable loop event map in the on-disk shape the Writer will stamp `id`/
  `schema_version` onto (matching `EmitBridge.durable_record/1`). `type` is a
  CONVERSATIONAL member unless overridden.
  """
  def loop_event(type, payload \\ %{}) do
    %{
      "v" => 0,
      "session_id" => nil,
      "turn_id" => nil,
      "ts" => System.system_time(:microsecond),
      "family" => "loop",
      "type" => to_string(type),
      "tier" => "durable",
      "payload" => payload
    }
  end

  @doc "A `family: meta` event (never a tip — excluded by the closure rule)."
  def meta_event(type, payload \\ %{}) do
    %{loop_event(type, payload) | "family" => "meta"}
  end

  @doc "Append one event through the REAL Writer, asserting the expected dense offset."
  def append!(journal, event), do: FileStore.append(journal, event)

  @doc "Append a list of events through the REAL Writer in order; returns the offsets."
  def append_all!(journal, events) do
    Enum.map(events, fn e ->
      {:ok, off} = FileStore.append(journal, e)
      off
    end)
  end

  # ---------------------------------------------------------------------------
  # Independent raw decoder (m6) — never FileStore.read
  # ---------------------------------------------------------------------------

  @segment_re ~r/^\d{6}\.jsonl$/

  @doc "Raw-decode every complete framed line under `dir/journal`, in offset order."
  def raw_records(dir) do
    dir
    |> Path.join("journal")
    |> segment_paths()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&Jason.decode!/1)
    end)
  end

  @doc "Ids of the raw journal, in file order."
  def raw_ids(dir), do: dir |> raw_records() |> Enum.map(& &1["id"])

  defp segment_paths(journal_dir) do
    case File.ls(journal_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@segment_re, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal_dir, &1))

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Oracles
  # ---------------------------------------------------------------------------

  @doc "Record-layer density (P-JS1 / N-JS6): ids are dense `1..n`, in order."
  def dense_ids?(dir) do
    ids = raw_ids(dir)
    ids == Enum.to_list(1..length(ids)//1)
  end

  @doc "The frozen tip predicate (JS-FREEZE §1.1) over a single raw record map."
  def conversational?(record) do
    kind = Map.get(record, "kind", "event")
    family = Map.get(record, "family")
    type = Map.get(record, "type")
    kind == "event" and family == "loop" and type in @conversational
  end

  @doc "The conversational tip offset (highest-offset CONVERSATIONAL record), or `:no_tip`."
  def tip(records) when is_list(records) do
    records
    |> Enum.filter(&conversational?/1)
    |> case do
      [] -> :no_tip
      convs -> convs |> Enum.map(& &1["id"]) |> Enum.max()
    end
  end

  def tip_of(dir), do: dir |> raw_records() |> tip()

  @doc "Tip validity (N-JS1): the record named by `tip_offset` exists and is CONVERSATIONAL."
  def valid_tip?(records, tip_offset) when is_list(records) do
    case Enum.find(records, &(&1["id"] == tip_offset)) do
      nil -> false
      record -> conversational?(record)
    end
  end

  @doc """
  Turn-boundary rule (N-JS2): `true` iff no turn is open (every `turn_started`
  is matched by a later close) and no spend-gate reserve is open.

  NOTE: the spend-gate reserve/terminal vocabulary is not yet frozen in the
  landed contract; `reserve`/`settle`/`release` here are provisional markers so
  the mid-reserve contour is authorable. Re-bind to the real vocabulary when the
  spend gate lands.
  """
  def at_turn_boundary?(records) when is_list(records) do
    balance =
      Enum.reduce(records, %{turn: 0, reserve: 0}, fn r, acc ->
        case r["type"] do
          "turn_started" ->
            %{acc | turn: acc.turn + 1}

          t when t in ["turn_completed", "turn_canceled", "error"] ->
            %{acc | turn: max(acc.turn - 1, 0)}

          "reserve" ->
            %{acc | reserve: acc.reserve + 1}

          t when t in ["settle", "release"] ->
            %{acc | reserve: max(acc.reserve - 1, 0)}

          _ ->
            acc
        end
      end)

    balance.turn == 0 and balance.reserve == 0
  end

  @doc "Lowercase-hex sha256 of `bytes` (the frozen `snapshot_hash` recipe)."
  def sha256_hex(bytes),
    do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  @doc "Does the content-addressed snapshot `ref` (relative CAS path) exist under `dir`?"
  def snapshot_present?(_dir, nil), do: false

  def snapshot_present?(dir, ref) when is_binary(ref),
    do: File.exists?(Path.join(dir, ref))

  # --- toy deterministic fold (surrogate for the real MS codec) --------------

  @doc "Fold the event records (offset order) into a toy model. Surrogate for MS fold."
  def fold(records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, "kind", "event") == "event"))
    |> Enum.reduce(%{"applied" => []}, fn r, model -> fold_step(model, r) end)
  end

  @doc "Fold `records` forward starting from an existing `model` (the `⊕` operator)."
  def fold_forward(model, records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, "kind", "event") == "event"))
    |> Enum.reduce(model, fn r, m -> fold_step(m, r) end)
  end

  defp fold_step(model, record) do
    Map.update(model, "applied", [record["id"]], &(&1 ++ [record["id"]]))
  end

  @doc "Snapshot dump (surrogate for MS `dump/1`): canonical JSON bytes of the folded model."
  def dump(model), do: Jason.encode!(model)

  @doc "Snapshot load (surrogate for MS `load/1`)."
  def load(bytes), do: Jason.decode!(bytes)

  @doc """
  Write a content-addressed snapshot file for `model` under `dir/snapshots`,
  file-BEFORE-record (FI-8 spirit). Returns `{ref, hash}` for a checkpoint
  record to point at. Used to stage restore contours; NOT the production writer.
  """
  def stage_snapshot!(dir, model) do
    bytes = dump(model)
    hash = sha256_hex(bytes)
    ref = "snapshots/#{hash}.json"
    File.mkdir_p!(Path.join(dir, "snapshots"))
    File.write!(Path.join(dir, ref), bytes)
    {ref, hash}
  end

  # ---------------------------------------------------------------------------
  # Dead-injectors (fabricate the broken shapes; controls assert the oracle catches)
  # ---------------------------------------------------------------------------

  @doc """
  Raw-append `record` (already carrying an `"id"`) to the newest segment,
  bypassing the Writer — the fabrication primitive shared by the injectors.
  """
  def raw_append!(dir, record) do
    seg = dir |> Path.join("journal") |> segment_paths() |> List.last()
    File.write!(seg, [Jason.encode_to_iodata!(record), ?\n], [:append])
    :ok
  end

  @doc """
  N-JS6 injector: append a checkpoint whose `id` came from a SECOND counter
  (here: reuse the previous offset, breaking `prev+1`). The single-counter law
  says every kind consumes the same counter, so this leaves the record layer
  non-dense — `dense_ids?/1` must return `false`.
  """
  def inject_second_counter_checkpoint!(dir, cp \\ %{}) do
    ids = raw_ids(dir)
    bad_id = List.last(ids) || 1

    record =
      Map.merge(
        %{
          "id" => bad_id,
          "kind" => "checkpoint",
          "schema_version" => @schema_version
        },
        cp
      )

    raw_append!(dir, record)
  end

  @doc """
  N-JS6 control's positive arm: append a checkpoint stamped from the SINGLE
  counter (id = last + 1). `dense_ids?/1` must stay `true`.
  """
  def inject_single_counter_checkpoint!(dir, cp \\ %{}) do
    ids = raw_ids(dir)
    next = (List.last(ids) || 0) + 1

    record =
      Map.merge(
        %{
          "id" => next,
          "kind" => "checkpoint",
          "schema_version" => @schema_version
        },
        cp
      )

    raw_append!(dir, record)
  end

  @doc """
  Record-before-file ordering injector (N-JS3 / crash-window control): append a
  checkpoint record naming a snapshot that was NEVER written — the illegal
  order. `snapshot_present?/2` must be `false` for the referenced ref.
  """
  def inject_record_before_file!(dir, tip_offset) do
    ref = "snapshots/#{sha256_hex("phantom-#{System.unique_integer()}")}.json"
    ids = raw_ids(dir)
    next = (List.last(ids) || 0) + 1

    record = %{
      "id" => next,
      "kind" => "checkpoint",
      "schema_version" => @schema_version,
      "tip_offset" => tip_offset,
      "snapshot_ref" => ref,
      "snapshot_hash" => sha256_hex("phantom"),
      "reason" => "manual"
    }

    raw_append!(dir, record)
    ref
  end

  @doc "Mutant tip validator (N-JS1 dead injector): accepts ANY positive integer as a tip."
  def mutant_accept_any_tip?(_records, tip_offset),
    do: is_integer(tip_offset) and tip_offset > 0

  @doc """
  Mutant restorer (N-JS3 dead injector): on a missing snapshot, silently folds
  the whole journal instead of surfacing the typed error. Returns `{:ok, model}`.
  """
  def mutant_restore_silent_fallback(dir, _ref),
    do: {:ok, fold(raw_records(dir))}

  # ---------------------------------------------------------------------------
  # Fired-counter harness (meta-inv 1/2) — generic over atoms
  # ---------------------------------------------------------------------------

  defmodule Counters do
    @moduledoc "Generic armed-site fire counter for the U9-R controls (meta-inv 1)."

    @doc "Start a fresh counter harness."
    def new do
      {:ok, pid} =
        Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)

      pid
    end

    @doc "Arm a site: it MUST fire before `assert_all_fired!/2`."
    def arm(harness, site) do
      Agent.update(harness, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
      harness
    end

    @doc "Record that `site` fired."
    def fire(harness, site) do
      Agent.update(harness, fn s ->
        %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
      end)

      :ok
    end

    @doc "Per-site fire counts."
    def fired(harness), do: Agent.get(harness, & &1.fired)

    @doc "Fail if any armed site never fired (dead injector). `schedule` dumped on failure (m2)."
    def assert_all_fired!(harness, schedule \\ nil) do
      %{armed: armed, fired: fired} = Agent.get(harness, & &1)
      dead = Enum.filter(armed, fn site -> Map.get(fired, site, 0) == 0 end)

      if dead != [] do
        raise ExUnit.AssertionError,
          message:
            "dead injector(s): armed site(s) never fired: #{inspect(dead)}\n" <>
              "fired: #{inspect(fired)}\nschedule/seed: #{inspect(schedule)}"
      end

      fired
    end
  end
end
