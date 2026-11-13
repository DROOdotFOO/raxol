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

  import Raxol.Journal.Test.MutationAnchor

  @moduletag :mutation

  @journal_lib Path.expand("../../lib/raxol/agent/journal", __DIR__)

  test "m4/I5 — silently truncate interior corruption" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/reader.ex"),
      "{:damaged, Enum.reverse(acc)}",
      "return {:ok, Enum.reverse(acc)} from handle_bad_line's interior arm (silent prefix surface)",
      "storage_invariants_test.exs — I5 corrupt-interior test ({:error, :damaged} expected) and journal_test.exs"
    )
  end

  test "m4/I6 — skip the id-continuity check" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/reader.ex"),
      "if continuous?(acc, record) do",
      "replace the continuity branch with an unconditional replay(rest, [record | acc], dir)",
      "storage_invariants_test.exs — I6 missing-middle-segment test and the I5 interior-cut property"
    )
  end

  test "m4/I7 — allow a second writer per journal dir" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/writer.ex"),
      "GenServer.start_link(__MODULE__, opts, name: global_name(dir))",
      "drop the name: option (anonymous writers, one per open)",
      "storage_invariants_test.exs — I7 concurrent-opens test (N writers, interleaved non-dense ids)"
    )
  end

  test "m4/I8 — resume from HEAD alone" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/writer.ex"),
      "max(head_offset(dir), Reader.resume_last_offset(dir))",
      "return head_offset(dir) alone from resume_offset/1",
      "storage_invariants_test.exs — I8 stale-HEAD resume test (duplicate id 2) and journal_test.exs"
    )
  end

  test "m4/I8 — write HEAD in place (non-atomic)" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/writer.ex"),
      "atomic_write!(Path.join(state.dir, \"HEAD\"),",
      "replace atomic_write! with a plain File.write!",
      "storage_invariants_test.exs — I8 concurrent-raw-reads test (torn/partial HEAD observed under the append storm)"
    )
  end

  test "m4/I10 — drop the immediate-sync branch" do
    assert_anchor!(
      Path.join(@journal_lib, "file_store/writer.ex"),
      "defp sync_after_append(state, true), do: flush_now(state)",
      "make the immediate arm behave like the batched arm (timer only)",
      "storage_invariants_test.exs — I10 busy-mailbox test (tool_result not on disk at reply time)"
    )
  end
end
