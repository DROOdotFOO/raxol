defmodule Raxol.Agent.Red.U10CompactCommitSurfacingTest do
  @moduledoc """
  Regression for the U10-I adversarial-review MEDIUM finding (compact/2 double
  read): the checkpoint is durably committed inside `Checkpoint.write/3`, then
  `compact/2` re-reads the journal to recover snapshot_ref/hash/tip_offset. If
  that second read fails, the OLD code returned a bare error while the
  checkpoint was already persisted — a caller retrying on error would append a
  DUPLICATE checkpoint. The fix surfaces the committed offset:
  `{:error, {:checkpoint_committed_unreadable, offset, reason}}`.

  `async: false` — the test swaps the global checkpoint backend seam
  (`Checkpoint.put_backend/1`, a `:persistent_term`), which must not race other
  tests that go through the default `FileBackend`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Compaction
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.Records.Checkpoint
  alias Raxol.Agent.Red.Support.U10Compaction, as: S

  defmodule GhostCommitBackend do
    @moduledoc """
    Models the double-read failure window: `write/3` reports a COMMITTED offset
    that the follow-up journal read cannot resolve (in production: the re-read
    returning `:damaged`/`:checkpoint_not_found` after a successful commit).
    Everything else delegates to the real backend.
    """
    @behaviour Raxol.Agent.Journal.Records.Checkpoint

    alias Raxol.Agent.Journal.Records.Checkpoint.FileBackend

    # An offset the enrichment re-read can never find.
    @ghost_offset 1_000_000

    def ghost_offset, do: @ghost_offset

    @impl true
    def write(_journal, _model, _opts), do: {:ok, @ghost_offset}

    @impl true
    defdelegate restore(journal, opts), to: FileBackend

    @impl true
    defdelegate restore_checkpoint(journal, records, checkpoint), to: FileBackend

    @impl true
    defdelegate protected_floor(journal, records), to: FileBackend
  end

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u10_commit_surf_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)

    on_exit(fn ->
      # Restore the default backend whatever happens.
      Checkpoint.put_backend(Raxol.Agent.Journal.Records.Checkpoint.FileBackend)
      File.rm_rf(base)
    end)

    {:ok, base: base}
  end

  test "commit succeeds but the enrichment re-read fails → the COMMITTED offset is surfaced in the error",
       %{base: base} do
    {journal, _session, _dir} = S.fresh_session(base)
    S.seed_events!(journal, [%{"op" => "incr", "amount" => 1}])

    Checkpoint.put_backend(GhostCommitBackend)

    ghost = GhostCommitBackend.ghost_offset()

    assert {:error, {:checkpoint_committed_unreadable, ^ghost, :checkpoint_not_found}} =
             Compaction.compact(journal, model: S.fold(S.records_of(journal))),
           "the error must carry the committed offset so a retrying caller " <>
             "cannot double-append (pre-fix: a bare :checkpoint_not_found)"

    FileStore.close(journal)
  end
end
