defmodule Raxol.Agent.Invariants.MutationControlsTest do
  @moduledoc """
  Meta-invariant m4 — negative controls: one production mutation per invariant
  must make its property fail within budget. This is a RUNNABLE-ON-DEMAND
  checklist, `@tag :mutation`, excluded from every regular run — a periodic CI
  job (or a human before trusting a refactor) runs:

      MIX_ENV=test mix test test/invariants/mutation_controls_test.exs --only mutation

  Each test does two things:

    1. documents the exact production line to mutate and which property must
       then fail (the checklist), and
    2. asserts that the load-bearing line STILL EXISTS verbatim in the source —
       so a refactor that moves/renames the guarded code fails THIS test and
       forces the checklist to be updated instead of silently rotting.

  The mutations themselves are applied by hand (or by a future mutation
  runner); running the controls on unmutated code verifies only the checklist's
  anchors.
  """
  use ExUnit.Case, async: true

  @moduletag :mutation

  @agent_lib Path.expand("../../lib/raxol/agent", __DIR__)
  @main_lib Path.expand("../../../../lib/raxol", __DIR__)

  defp assert_anchor!(path, fragment, mutation, must_fail) do
    source = File.read!(path)

    assert String.contains?(source, fragment),
           """
           mutation-control anchor rotted: #{Path.relative_to_cwd(path)} no longer contains

               #{fragment}

           The guarded line moved or was renamed. Update this control:
             MUTATION: #{mutation}
             MUST FAIL: #{must_fail}
           """
  end

  test "m4/I1 — invert append-before-publish in EmitBridge" do
    assert_anchor!(
      Path.join(@agent_lib, "emit_bridge.ex"),
      "case append_durable(state, safe) do",
      "swap the order: SessionStreamer.emit BEFORE append_durable (publish-ahead window)",
      "identity_invariants_test.exs — I3 raw-read-at-first-sight in await_durable!/1"
    )
  end

  test "m4/I1 — fabricate an id on append failure" do
    assert_anchor!(
      Path.join(@agent_lib, "emit_bridge.ex"),
      "{:error, state, failure_reason, detail} ->",
      "in the error arm, emit the durable event with id state.last_offset + 1 instead of dropping it",
      "identity_invariants_test.exs — I1 property (live id not in journal / journal not dense) and the :append_fail branch probe"
    )
  end

  test "m4/I2 — journal the ephemeral tier" do
    assert_anchor!(
      Path.join(@agent_lib, "emit_bridge.ex"),
      "{:emit_bus, session_id, %{tier: :durable} = neutral}",
      "change the clause head to match any tier (journal ephemerals too)",
      "identity_invariants_test.exs — I2 property: journal contains tier != durable / item_delta records"
    )
  end

  test "m4/I2 — stamp ephemeral ids from a fresh counter" do
    assert_anchor!(
      Path.join(@agent_lib, "emit_bridge.ex"),
      "event = map_event(neutral, state.last_offset, session_id)",
      "replace state.last_offset with System.unique_integer([:positive]) (fresh fake offsets)",
      "identity_invariants_test.exs — I2 property: ephemeral id != last durable offset"
    )
  end

  test "m4/I3 — advance the watermark on failed appends" do
    assert_anchor!(
      Path.join(@agent_lib, "emit_bridge.ex"),
      "journal_failure_event(state, safe, failure_reason, detail)",
      "in the failure arm, return {:noreply, %{state | last_offset: state.last_offset + 1}}",
      "identity_invariants_test.exs — the :append_fail branch probe (failure signal id != old watermark; next durable id gap)"
    )
  end

  test "m4/I4 — read turn_id at emit time instead of the dispatch snapshot" do
    assert_anchor!(
      Path.join(@main_lib, "core/runtime/events/dispatcher.ex"),
      "process_command_result(state, full_message, Map.get(meta, :turn_id))",
      "pass state.turn_id instead of Map.get(meta, :turn_id) (the pre-4c8cedfc bug)",
      "turn_invariants_test.exs — I4 property: delta stamped with a trailing turn's id or nil"
    )
  end

  test "m4/I5 — silently truncate interior corruption" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/reader.ex"),
      "{:damaged, Enum.reverse(acc)}",
      "return {:ok, Enum.reverse(acc)} from handle_bad_line's interior arm (silent prefix surface)",
      "storage_invariants_test.exs — I5 corrupt-interior test ({:error, :damaged} expected) and journal_test.exs"
    )
  end

  test "m4/I6 — skip the id-continuity check" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/reader.ex"),
      "if continuous?(acc, record) do",
      "replace the continuity branch with an unconditional replay(rest, [record | acc], dir)",
      "storage_invariants_test.exs — I6 missing-middle-segment test and the I5 interior-cut property"
    )
  end

  test "m4/I7 — allow a second writer per journal dir" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/writer.ex"),
      "GenServer.start_link(__MODULE__, opts, name: global_name(dir))",
      "drop the name: option (anonymous writers, one per open)",
      "storage_invariants_test.exs — I7 concurrent-opens test (N writers, interleaved non-dense ids)"
    )
  end

  test "m4/I8 — resume from HEAD alone" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/writer.ex"),
      "max(head_offset(dir), Reader.resume_last_offset(dir))",
      "return head_offset(dir) alone from resume_offset/1",
      "storage_invariants_test.exs — I8 stale-HEAD resume test (duplicate id 2) and journal_test.exs"
    )
  end

  test "m4/I8 — write HEAD in place (non-atomic)" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/writer.ex"),
      "atomic_write!(Path.join(state.dir, \"HEAD\"),",
      "replace atomic_write! with a plain File.write!",
      "storage_invariants_test.exs — I8 concurrent-raw-reads test (torn/partial HEAD observed under the append storm)"
    )
  end

  test "m4/I10 — drop the immediate-sync branch" do
    assert_anchor!(
      Path.join(@agent_lib, "journal/file_store/writer.ex"),
      "defp sync_after_append(state, true), do: flush_now(state)",
      "make the immediate arm behave like the batched arm (timer only)",
      "storage_invariants_test.exs — I10 busy-mailbox test (tool_result not on disk at reply time)"
    )
  end

  test "m4/I9 — narrow a payload shape" do
    assert_anchor!(
      Path.join(@agent_lib, "contract.ex"),
      "item_type: :tool_use,",
      "drop the call_id field from the tool_use item_completed payload",
      "contract_invariants_test.exs — pump producer test (required payload field call_id missing)"
    )
  end
end
