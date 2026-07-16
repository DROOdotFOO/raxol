defmodule Raxol.Agent.Red.CheckpointProtectedFloorTest do
  @moduledoc """
  Regression suite for the U10-I adversarial-review SECONDARY finding (PR #581):
  `Checkpoint.protected_floor/1` returned the newest-by-id checkpoint's tip, but
  the doc (and the frozen "GC never orphans checkpoints" law) demands the newest
  **healthy** checkpoint's tip — the one resume actually restores from.

  With U10's fall-back-to-an-older-healthy-checkpoint behaviour, a by-id floor
  would protect a CORRUPT newest's higher tip and let GC truncate the records the
  older healthy fall-back fold still needs — an orphaned fall-back tip. These
  CI-green regressions pin `protected_floor/2` == the older healthy tip when the
  newest is corrupt.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Compaction
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Red.Support.U10Compaction, as: S

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u10_floor_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp two_compactions(base) do
    {journal, _session, dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])
    {:ok, c1} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 2}])
    {:ok, c2} = Compaction.compact(journal, model: S.fold(S.records_of(journal)))
    _ = S.records_of(journal)
    {journal, dir, c1, c2}
  end

  test "healthy newest → protected_floor is the newest checkpoint's tip", %{base: base} do
    {journal, _dir, _c1, c2} = two_compactions(base)
    {:ok, records} = FileStore.read(journal)

    assert Checkpoint.protected_floor(journal, records) == {:offset, c2.tip_offset}

    FileStore.close(journal)
  end

  test "corrupt newest + healthy older → protected_floor is the OLDER healthy tip", %{base: base} do
    {journal, dir, c1, c2} = two_compactions(base)

    # Corrupt the newest snapshot so c2 no longer restores.
    S.corrupt_snapshot!(dir, c2.snapshot_ref)
    {:ok, records} = FileStore.read(journal)

    # A by-id floor would (wrongly) return c2.tip_offset (the higher tip), letting
    # GC truncate what the c1 fall-back fold needs. The healthy floor is c1's tip.
    assert Checkpoint.protected_floor(journal, records) == {:offset, c1.tip_offset},
           "the floor must be the newest HEALTHY checkpoint's tip, not the corrupt newest's"

    # And it matches exactly what resume falls back to.
    assert {:ok, _model, %{selected_offset: sel}} = Compaction.resume(journal, [])
    assert sel == c1.checkpoint_offset

    FileStore.close(journal)
  end

  test "no checkpoint at all → :none", %{base: base} do
    {journal, _session, _dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])
    {:ok, records} = FileStore.read(journal)

    assert Checkpoint.protected_floor(journal, records) == :none

    FileStore.close(journal)
  end

  test "all checkpoints corrupt → :none (nothing healthy to protect)", %{base: base} do
    {journal, dir, c1, c2} = two_compactions(base)
    S.corrupt_snapshot!(dir, c1.snapshot_ref)
    S.corrupt_snapshot!(dir, c2.snapshot_ref)
    {:ok, records} = FileStore.read(journal)

    assert Checkpoint.protected_floor(journal, records) == :none

    FileStore.close(journal)
  end
end
