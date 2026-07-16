defmodule Raxol.Harness.EditorSuspendTest do
  @moduledoc """
  Pure-function suite for `Raxol.Harness.EditorSuspend`: editor
  resolution policy, the draft round-trip (encode/decode), the tmp-file
  naming policy, and -- the load-bearing part -- the suspend/resume state
  machine with per-step compensation.

  Everything here is data-in/data-out: no processes, no IO, no tty. The
  impure runner (`Raxol.Harness.EditorSession`) interprets this machine;
  its own suite (`editor_session_test.exs`) covers the interpretation.

  The compensation invariant is checked exhaustively (every failure
  point) with a plain ledger fold -- the failure-point set is finite, so
  a comprehension covers it completely with no property framework.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.EditorSuspend

  # The canonical ordered step list this machine must emit on the happy
  # path. `:requery_size` sits BEFORE `:raw_tty` because the size query
  # must run while the tty is still cooked (the runner's own documented
  # ordering); everything else follows the suspend/resume bracket order.
  @expected_steps [
    :write_tmp,
    :disable_reader,
    :release_screen,
    :restore_tty,
    :spawn_editor,
    :await_editor,
    :requery_size,
    :raw_tty,
    :enable_reader,
    :reinit_modes,
    :reassert_region,
    :reload_draft,
    :cleanup_tmp
  ]

  # ---------------------------------------------------------------------
  # resolve_editor/1
  # ---------------------------------------------------------------------

  describe "resolve_editor/1" do
    test "VISUAL wins over EDITOR" do
      assert EditorSuspend.resolve_editor(%{
               "VISUAL" => "code -w",
               "EDITOR" => "vim"
             }) == {:ok, "code -w"}
    end

    test "empty-string VISUAL falls through to EDITOR" do
      assert EditorSuspend.resolve_editor(%{
               "VISUAL" => "",
               "EDITOR" => "vim"
             }) == {:ok, "vim"}
    end

    test "missing VISUAL falls through to EDITOR" do
      assert EditorSuspend.resolve_editor(%{"EDITOR" => "nano"}) ==
               {:ok, "nano"}
    end

    test "both empty/missing falls back to vi" do
      assert EditorSuspend.resolve_editor(%{}) == {:ok, "vi"}
      assert EditorSuspend.resolve_editor(%{"VISUAL" => "", "EDITOR" => ""}) ==
               {:ok, "vi"}
    end
  end

  # ---------------------------------------------------------------------
  # draft round-trip: encode/decode
  # ---------------------------------------------------------------------

  describe "draft round-trip" do
    test "decode(encode(d) <> \"\\n\") == d for representative drafts" do
      drafts = [
        "one line",
        "multi\nline\ndraft",
        "trailing backslash \\",
        "unicode 你好世界 🎉 école",
        ""
      ]

      for d <- drafts do
        assert EditorSuspend.decode_draft(EditorSuspend.encode_draft(d) <> "\n") ==
                 d
      end
    end

    test "decode strips exactly ONE trailing newline" do
      assert EditorSuspend.decode_draft("a\n\n") == "a\n"
      assert EditorSuspend.decode_draft("a\n") == "a"
      assert EditorSuspend.decode_draft("a") == "a"
    end

    test "decode handles a trailing \\r\\n as one terminator" do
      assert EditorSuspend.decode_draft("a\r\n") == "a"
      assert EditorSuspend.decode_draft("a\r\n\r\n") == "a\r\n"
    end

    test "encode is identity" do
      for d <- ["", "x", "a\nb", "tabs\tand \\ slashes"] do
        assert EditorSuspend.encode_draft(d) == d
      end
    end
  end

  # ---------------------------------------------------------------------
  # tmp_filename/1
  # ---------------------------------------------------------------------

  describe "tmp_filename/1" do
    test "pure name policy: raxol_draft_<unique>.md" do
      assert EditorSuspend.tmp_filename("abc123") == "raxol_draft_abc123.md"
    end
  end

  # ---------------------------------------------------------------------
  # the state machine: happy-path ordering
  # ---------------------------------------------------------------------

  # Drives the machine with `:ok` for every effect, collecting the
  # emitted step sequence until `{:done, _}`.
  defp drive_happy(machine, acc \\ []) do
    case EditorSuspend.advance(machine, :ok) do
      {:done, _machine} -> Enum.reverse(acc)
      {:effect, step, machine} -> drive_happy(machine, [step | acc])
    end
  end

  # Advances the machine `n` times with `:ok` (issuing `n` effects; the
  # first `n - 1` are completed, the n-th is pending), returning the
  # machine plus the pending step.
  defp drive_to_step(n) do
    Enum.reduce(1..n, {EditorSuspend.new(), nil}, fn _i, {machine, _prev} ->
      {:effect, step, machine} = EditorSuspend.advance(machine, :ok)
      {machine, step}
    end)
  end

  describe "machine: happy-path effect order (pinned)" do
    test "emits the full step list in the exact documented order" do
      assert drive_happy(EditorSuspend.new()) == @expected_steps
    end

    test "suspend bracket ordering: reader disable BEFORE screen release BEFORE tty restore BEFORE spawn" do
      steps = drive_happy(EditorSuspend.new())
      idx = fn step -> Enum.find_index(steps, &(&1 == step)) end

      assert idx.(:disable_reader) < idx.(:release_screen)
      assert idx.(:release_screen) < idx.(:restore_tty)
      assert idx.(:restore_tty) < idx.(:spawn_editor)
    end

    test "resume bracket ordering: raw BEFORE reader enable BEFORE reinit" do
      steps = drive_happy(EditorSuspend.new())
      idx = fn step -> Enum.find_index(steps, &(&1 == step)) end

      assert idx.(:raw_tty) < idx.(:enable_reader)
      assert idx.(:enable_reader) < idx.(:reinit_modes)
    end

    test "cleanup_tmp is the final step" do
      assert List.last(drive_happy(EditorSuspend.new())) == :cleanup_tmp
    end
  end

  # ---------------------------------------------------------------------
  # the state machine: compensation invariant, every failure point
  # ---------------------------------------------------------------------

  # A simple resource ledger interpreting each step (and each
  # compensation step -- same vocabulary, same transitions) as a
  # transition over the terminal's externally-observable resources. The
  # invariant: starting from {raw, enabled, asserted, absent}, any
  # completed prefix followed by its compensation must land back on
  # exactly that state.
  @initial_ledger %{
    tty: :raw,
    reader: :enabled,
    screen: :asserted,
    modes: :on,
    tmp: :absent
  }

  defp ledger_apply(ledger, :write_tmp), do: %{ledger | tmp: :present}
  defp ledger_apply(ledger, :disable_reader), do: %{ledger | reader: :disabled}

  defp ledger_apply(ledger, :release_screen),
    do: %{ledger | screen: :released, modes: :off}

  defp ledger_apply(ledger, :restore_tty), do: %{ledger | tty: :cooked}
  defp ledger_apply(ledger, :spawn_editor), do: ledger
  defp ledger_apply(ledger, :await_editor), do: ledger
  defp ledger_apply(ledger, :requery_size), do: ledger
  defp ledger_apply(ledger, :raw_tty), do: %{ledger | tty: :raw}
  defp ledger_apply(ledger, :enable_reader), do: %{ledger | reader: :enabled}
  defp ledger_apply(ledger, :reinit_modes), do: %{ledger | modes: :on}
  defp ledger_apply(ledger, :reassert_region), do: %{ledger | screen: :asserted}
  defp ledger_apply(ledger, :reload_draft), do: ledger
  defp ledger_apply(ledger, :cleanup_tmp), do: %{ledger | tmp: :absent}

  describe "machine: recovery property (exhaustive over every failure point)" do
    test "for EVERY failure point, completed-steps ++ compensation restores the resource-ledger invariant" do
      total = length(@expected_steps)

      for fail_at <- 1..total do
        {machine, pending} = drive_to_step(fail_at)
        assert pending == Enum.at(@expected_steps, fail_at - 1)

        {:abort, compensation, _machine} =
          EditorSuspend.advance(machine, {:error, :boom})

        completed = Enum.take(@expected_steps, fail_at - 1)

        final =
          Enum.reduce(completed ++ compensation, @initial_ledger, &ledger_apply(&2, &1))

        assert final == @initial_ledger,
               "failure at #{inspect(pending)} (step #{fail_at}): " <>
                 "completed #{inspect(completed)} ++ compensation " <>
                 "#{inspect(compensation)} leaves ledger #{inspect(final)}, " <>
                 "not the invariant #{inspect(@initial_ledger)}"
      end
    end

    test "compensation never includes a step whose work was not done: failing the very first step compensates nothing" do
      {machine, :write_tmp} = drive_to_step(1)

      assert {:abort, [], _machine} =
               EditorSuspend.advance(machine, {:error, :eacces})
    end

    test "failing disable_reader (first terminal-state step) compensates only the tmp file" do
      {machine, :disable_reader} = drive_to_step(2)

      assert {:abort, [:cleanup_tmp], _machine} =
               EditorSuspend.advance(machine, {:error, :timeout})
    end

    test "spawn_editor failure compensates like a restore_tty-complete failure" do
      {machine_spawn, :spawn_editor} = drive_to_step(5)

      {:abort, comp_spawn, _} =
        EditorSuspend.advance(machine_spawn, {:error, :boom})

      assert comp_spawn == [
               :raw_tty,
               :enable_reader,
               :reinit_modes,
               :reassert_region,
               :cleanup_tmp
             ]
    end

    test "a resume-phase failure (reload_draft) compensates only cleanup -- the terminal is already restored" do
      reload_index =
        Enum.find_index(@expected_steps, &(&1 == :reload_draft)) + 1

      {machine, :reload_draft} = drive_to_step(reload_index)

      assert {:abort, [:cleanup_tmp], _machine} =
               EditorSuspend.advance(machine, {:error, :enoent})
    end

    test "compensation order is the safe resume order: raw before enable before reinit/reassert, cleanup last" do
      # Fail at :await_editor -- the deepest all-suspend-steps-completed
      # point -- and pin the exact ordered compensation.
      {machine, :await_editor} = drive_to_step(6)

      {:abort, compensation, _machine} =
        EditorSuspend.advance(machine, {:error, :boom})

      assert compensation == [
               :raw_tty,
               :enable_reader,
               :reinit_modes,
               :reassert_region,
               :cleanup_tmp
             ]
    end

    test "recovery/1 reports the same compensation the abort path would take (the runner's rescue seam)" do
      for fail_at <- 1..length(@expected_steps) do
        {machine, _pending} = drive_to_step(fail_at)

        {:abort, compensation, _} =
          EditorSuspend.advance(machine, {:error, :boom})

        assert EditorSuspend.recovery(machine) == compensation
      end
    end
  end
end
