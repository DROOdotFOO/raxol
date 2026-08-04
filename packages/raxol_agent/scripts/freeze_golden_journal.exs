# Freeze a golden journal fixture for the CURRENT `@default_schema_version`.
#
#   MIX_ENV=test mix run scripts/freeze_golden_journal.exs
#
# Run this ONCE per schema version, when the version is bumped, and never
# again: a frozen corpus is history. `scripts/check_journal_goldens.exs` (run
# in CI) refuses a `schema_version` bump that arrives without one, and pins
# every frozen fixture byte-for-byte through
# `test/invariants/fixtures/golden/MANIFEST.json`.
#
# What is real here, and what is normalized:
#
#   * REAL producer — `Raxol.Agent.Contract.pump/3` generates every payload
#     shape, including the `evidence` tri-state marker, from the same
#     `DoneGate.gate/3` verdict production uses. Nothing is hand-written.
#   * REAL writer — the captured durable events are replayed through
#     `EmitBus` -> `EmitBridge` -> `FileStore.Writer`, the production journal
#     path. The `id`s, framing, `HEAD`, and `meta.json` are writer output.
#   * NORMALIZED — only what is nondeterministic and would otherwise make the
#     corpus unhashable: `ts` (monotonic from a frozen base), `turn_id`
#     (pump mints `turn-<unique_integer>`), and `meta.json`'s `created_at`.
#     `cwd`/`git_branch`/`title` are passed in as writer opts, not rewritten.

alias Raxol.Agent.Contract
alias Raxol.Agent.Contract.Event
alias Raxol.Agent.EmitBridge
alias Raxol.Agent.SessionStreamer
alias Raxol.Core.Runtime.EmitBus

schema_version = Raxol.Agent.Journal.FileStore.Writer.default_schema_version()

session_id =
  "golden-v#{schema_version |> String.split(".") |> Enum.take(2) |> Enum.join()}"

fixtures = Path.expand("../test/invariants/fixtures/golden", __DIR__)
target = Path.join([fixtures, "v#{schema_version}", session_id])

# Frozen stamps. The base is the freeze date in microseconds; every record
# takes base + its own index, so `ts` is monotonic and reproducible.
ts_base = 1_785_800_000_000_000
created_at = "2026-08-04T00:00:00.000000Z"
cwd = "/workspace/raxol"
git_branch = "journal-golden-#{schema_version}"
title = "golden contract corpus v#{schema_version}"

# --- scenarios --------------------------------------------------------------
#
# One turn per shape the corpus must carry. Together they cover every journaled
# contract type, all three `item_type` variants, and all three `evidence`
# states -- the marker that 1.1.0 exists for.

scenarios = [
  {"turn-1",
   [
     {:tool_use,
      %{name: "fs_write", arguments: %{path: "/tmp/x"}, id: "call-1"}},
     {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
     {:done,
      %{
        content: "patched and verified",
        usage: %{input_tokens: 3, output_tokens: 5}
      }}
   ], "accepted: refs name a real tool_result postdating the last mutation"},
  {"turn-2",
   [
     {:tool_use,
      %{name: "fs_write", arguments: %{path: "/tmp/y"}, id: "call-2"}},
     {:tool_result, %{name: "fs_write", result: "wrote"}},
     {:done, %{content: "done", usage: %{output_tokens: 2}}}
   ], "rejected: the only ref is the last mutation's own result echo"},
  {"turn-3",
   [
     {:text_delta, "plain answer"},
     {:done, %{content: "plain answer", usage: %{output_tokens: 1}}}
   ], "absent: a zero-tool turn offers no refs at all"},
  {"turn-4", [{:error, :kaboom}], "error: a turn that never reaches done"}
]

# --- boot -------------------------------------------------------------------

# The test-env application already starts some of these; reuse whatever is up.
ensure_up = fn start ->
  case start.() do
    {:ok, pid} -> Process.unlink(pid)
    {:error, {:already_started, _}} -> :ok
  end
end

ensure_up.(fn ->
  Registry.start_link(keys: :duplicate, name: EmitBus.registry_name())
end)

ensure_up.(fn ->
  Raxol.Core.UserPreferences.start_link(name: Raxol.Core.UserPreferences)
end)

ensure_up.(fn -> SessionStreamer.start_link([]) end)

# --- capture: the REAL producer ---------------------------------------------

captured =
  Enum.flat_map(scenarios, fn {turn_label, stream, _why} ->
    pump_session = "freeze-#{turn_label}-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(pump_session)

    task =
      Task.async(fn ->
        Contract.pump(pump_session, stream, prompt: turn_label)
      end)

    _ = Task.await(task)

    drain = fn drain, acc ->
      receive do
        {:session_event, ^pump_session, %Event{} = ev} ->
          drain.(drain, [ev | acc])
      after
        300 -> Enum.reverse(acc)
      end
    end

    drain.(drain, [])
    # Ephemerals are never journaled; drop them here so the frozen `ts`
    # sequence matches the records that actually land on disk.
    |> Enum.filter(&(&1.tier == :durable))
    |> Enum.map(&{turn_label, &1})
  end)

# Each pump ran in its own session, so its `refs` are offsets into ITS OWN
# turn-local journal (1..n). Concatenated into one corpus those numbers name
# the wrong records -- turn-2's `refs: [5]` would point at turn-1's
# tool_result. Every turn's durable events land contiguously in capture order,
# so a turn's real journal offset is (records emitted before the turn) + the
# pump-local id. Rebase the two carriers that hold offsets so the frozen
# corpus is internally consistent: a ref names the record it means.
rebase = fn
  %Event{type: :turn_completed, payload: payload} = ev, base ->
    payload =
      payload
      |> then(fn p ->
        case p do
          %{refs: refs} when is_list(refs) ->
            %{p | refs: Enum.map(refs, &(&1 + base))}

          p ->
            p
        end
      end)
      |> then(fn p ->
        case p do
          %{evidence_rejected: %{"refs" => refs, "ref" => ref} = detail} ->
            %{
              p
              | evidence_rejected: %{
                  detail
                  | "refs" => Enum.map(refs, &(&1 + base)),
                    "ref" => ref + base
                }
            }

          p ->
            p
        end
      end)

    %{ev | payload: payload}

  ev, _base ->
    ev
end

{captured, _} =
  Enum.map_reduce(captured, {0, %{}}, fn {turn_label, ev}, {emitted, bases} ->
    bases = Map.put_new(bases, turn_label, emitted)

    {{turn_label, rebase.(ev, Map.fetch!(bases, turn_label))},
     {emitted + 1, bases}}
  end)

# --- replay through the REAL journal writer ---------------------------------

staging =
  Path.join(
    System.tmp_dir!(),
    "raxol_golden_freeze_#{System.unique_integer([:positive])}"
  )

File.rm_rf!(staging)
File.mkdir_p!(staging)

{:ok, bridge} =
  EmitBridge.start_link(
    session_id: session_id,
    journal_opts: [
      base_dir: staging,
      cwd: cwd,
      git_branch: git_branch,
      title: title
    ]
  )

:ok = SessionStreamer.subscribe(session_id)

captured
|> Enum.with_index(1)
|> Enum.each(fn {{turn_label, %Event{} = ev}, index} ->
  EmitBus.publish(%{
    session_id: session_id,
    family: ev.family,
    type: ev.type,
    tier: ev.tier,
    turn_id: turn_label,
    payload: ev.payload,
    ts: ts_base + index
  })

  # The bridge journals before it re-emits, so seeing the event on the
  # streamer means the append is already durable -- and keeps the append
  # order deterministic instead of racing the mailbox.
  receive do
    {:session_event, ^session_id, %Event{}} -> :ok
  after
    2_000 -> raise "bridge never re-emitted #{ev.type} (#{turn_label})"
  end
end)

GenServer.stop(bridge)

# --- normalize the one nondeterministic field, then install -----------------

meta_path = Path.join([staging, session_id, "meta.json"])

meta_path
|> File.read!()
|> Jason.decode!()
|> Map.put("created_at", created_at)
|> then(&File.write!(meta_path, Jason.encode!(&1)))

File.rm_rf!(target)
File.mkdir_p!(Path.dirname(target))
File.cp_r!(Path.join(staging, session_id), target)
File.rm_rf!(staging)

records =
  target
  |> Path.join("journal/000001.jsonl")
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.map(&Jason.decode!/1)

IO.puts(
  "froze #{length(records)} records at schema_version #{schema_version} -> #{target}"
)

for {label, _stream, why} <- scenarios do
  IO.puts("  #{label}: #{why}")
end

IO.puts(
  "\nnow refresh the manifest:\n  elixir scripts/check_journal_goldens.exs --bless"
)
