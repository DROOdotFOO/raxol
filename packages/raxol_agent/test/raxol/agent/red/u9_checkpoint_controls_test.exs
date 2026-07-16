defmodule Raxol.Agent.Red.U9CheckpointControlsTest do
  @moduledoc """
  Negative controls (dead-injectors) for the U9-R red suite — meta-inv 1/4.

  The RED suite (`u9_checkpoint_red_test.exs`) is `@moduletag :harness_red` and
  excluded from CI. THESE controls are NOT excluded: they run in every CI run and
  MUST stay green. Each control forges the exact broken shape a negative contour
  must catch, then asserts the SHARED oracle in `Raxol.Agent.Red.CheckpointRed`
  distinguishes it from the correct shape — proving the corresponding red is not
  vacuous (a dead injector that green-lies would be caught here).

  Every armed injector fires a counter (`CheckpointRed.Counters`); a schedule
  that never fires an armed site fails `assert_all_fired!/2` with the seed dumped
  (meta-inv 1/2).

  Covered: N-JS6 (second counter), N-JS1 (any-positive-int tip), N-JS2 (skip the
  turn-boundary check), N-JS3 (silent restore fallback), and the record-before-
  file ordering injector.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Red.CheckpointRed, as: CR
  alias Raxol.Agent.Red.CheckpointRed.Counters

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "u9r_ctl_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base}
  end

  defp seed!(base) do
    {j, session, dir} = CR.open!(base)

    CR.append_all!(j, [
      CR.loop_event("turn_started"),
      CR.loop_event("item_completed", %{"text" => "hi"}),
      CR.loop_event("turn_completed"),
      CR.meta_event("idle")
    ])

    {j, session, dir}
  end

  # ===========================================================================
  # N-JS6 — a checkpoint stamped from a SECOND counter must break the density red
  # ===========================================================================

  test "N-JS6 control: second-counter checkpoint breaks dense_ids?, single-counter keeps it",
       %{
         base: base
       } do
    h =
      Counters.new()
      |> Counters.arm(:second_counter)
      |> Counters.arm(:single_counter)

    # Correct shape (single counter): density holds.
    {j1, _s1, dir1} = seed!(base)
    :ok = FileStore.close(j1)
    CR.inject_single_counter_checkpoint!(dir1, %{"tip_offset" => 2})
    Counters.fire(h, :single_counter)

    assert CR.dense_ids?(dir1),
           "control positive arm: single-counter checkpoint stays dense"

    # Mutant (second counter): the density oracle the red uses MUST reject it.
    {j2, _s2, dir2} = seed!(base)
    :ok = FileStore.close(j2)
    CR.inject_second_counter_checkpoint!(dir2, %{"tip_offset" => 2})
    Counters.fire(h, :second_counter)

    refute CR.dense_ids?(dir2),
           "dead injector escaped: a side-counter checkpoint left the record layer dense"

    Counters.assert_all_fired!(h)
  end

  # ===========================================================================
  # N-JS1 — a constructor accepting any positive int as tip must break tip-validity
  # ===========================================================================

  test "N-JS1 control: mutant accepts a meta-id tip that the real oracle rejects",
       %{base: base} do
    h = Counters.new() |> Counters.arm(:any_tip)
    {j, _s, dir} = seed!(base)
    :ok = FileStore.close(j)

    records = CR.raw_records(dir)
    meta_id = Enum.find(records, &(&1["family"] == "meta")) |> Map.fetch!("id")

    # The mutant (dead injector) would accept it...
    assert CR.mutant_accept_any_tip?(records, meta_id)
    Counters.fire(h, :any_tip)

    # ...but the real tip-validity oracle the red uses rejects it.
    refute CR.valid_tip?(records, meta_id),
           "dead injector escaped: the tip oracle accepted a non-conversational offset"

    # And a genuine conversational tip is accepted by both (oracle not always-false).
    good = CR.tip_of(dir)
    assert CR.valid_tip?(records, good)
    Counters.assert_all_fired!(h)
  end

  # ===========================================================================
  # N-JS2 — a writer skipping the turn-boundary check must be caught
  # ===========================================================================

  test "N-JS2 control: the boundary oracle flags an open turn and an open reserve",
       %{base: base} do
    h =
      Counters.new()
      |> Counters.arm(:mid_turn)
      |> Counters.arm(:mid_reserve)
      |> Counters.arm(:boundary)

    # Clean boundary: accepted.
    {j0, _s0, dir0} = seed!(base)
    :ok = FileStore.close(j0)
    assert CR.at_turn_boundary?(CR.raw_records(dir0))
    Counters.fire(h, :boundary)

    # Open turn: a writer skipping the check would append here — the oracle says no.
    {j1, _s1, dir1} = CR.open!(base)

    CR.append_all!(j1, [
      CR.loop_event("turn_started"),
      CR.loop_event("item_started")
    ])

    :ok = FileStore.close(j1)

    refute CR.at_turn_boundary?(CR.raw_records(dir1)),
           "dead injector escaped: mid-turn read as a boundary"

    Counters.fire(h, :mid_turn)

    # Open reserve: same.
    {j2, _s2, dir2} = CR.open!(base)

    CR.append_all!(j2, [
      CR.loop_event("turn_started"),
      CR.loop_event("turn_completed"),
      CR.meta_event("reserve", %{"amount" => "1.00"})
    ])

    :ok = FileStore.close(j2)

    refute CR.at_turn_boundary?(CR.raw_records(dir2)),
           "dead injector escaped: mid-reserve read as a boundary"

    Counters.fire(h, :mid_reserve)

    Counters.assert_all_fired!(h)
  end

  # ===========================================================================
  # N-JS3 — a restorer silently falling back to full replay must be caught
  # ===========================================================================

  test "N-JS3 control: silent-fallback restore hides the error the red demands",
       %{base: base} do
    h =
      Counters.new()
      |> Counters.arm(:silent_fallback)
      |> Counters.arm(:record_before_file)

    {j, _s, dir} = seed!(base)
    :ok = FileStore.close(j)

    # Record-before-file ordering: a checkpoint naming a snapshot never written.
    ref = CR.inject_record_before_file!(dir, CR.tip_of(dir))
    Counters.fire(h, :record_before_file)

    refute CR.snapshot_present?(dir, ref),
           "the referenced snapshot must be absent for this control"

    # The mutant silently returns a success tuple on the missing snapshot —
    # NOT the typed error the N-JS3 red requires ({:error, :snapshot_missing}).
    # That divergence (success where the contract demands a typed error) is
    # exactly what the red catches: the fallback masks a missing snapshot.
    result = CR.mutant_restore_silent_fallback(dir, ref)
    Counters.fire(h, :silent_fallback)

    assert elem(result, 0) == :ok,
           "dead injector escaped: the silent fallback did not mask the error with a success tuple"

    Counters.assert_all_fired!(h)
  end
end
