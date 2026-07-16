defmodule Raxol.Agent.Interrupt.Contours do
  @moduledoc """
  The U5-R contour assertions, **parameterized over the staged trace** so one
  set of checks serves both seams:

    * the **positive** reds run them against the trace the real
      `Raxol.Agent.Interrupt` produces (red until U5-I lands), and
    * the **negative** controls run the SAME checks against a dead injector's
      trace and assert they raise — proving the checks have teeth (the
      negative-control pattern, `harness-invariants.md` meta-inv 4).

  Journal truth comes from an **independent raw reader** (`records/1`): a plain
  `File.read!` over the session's segment files plus a local JSON decoder. It
  never consults `FileStore.read/2` or the Writer's in-memory offset (oracle
  independence, meta-inv 6). A staged-kill trace is durable, so folding the
  bytes on disk is the honest oracle.
  """

  import ExUnit.Assertions

  alias Raxol.Agent.Interrupt

  # Output-class event types forbidden AFTER kill-complete (the no-zombie law).
  @output_types ~w(item_delta item_completed tool_result)

  @doc """
  Independent raw fold of a session directory's durable records, in offset
  order. Decodes each newline-framed JSON object itself — no production reader.
  """
  @spec records(Path.t()) :: [map()]
  def records(dir) do
    dir
    |> Path.join("journal")
    |> segment_files()
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, %{} = record} -> [record]
          _ -> []
        end
      end)
    end)
  end

  defp segment_files(journal_dir) do
    case File.ls(journal_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(~r/^\d{6}\.jsonl$/, &1))
        |> Enum.sort()
        |> Enum.map(&Path.join(journal_dir, &1))

      {:error, _} ->
        []
    end
  end

  @doc """
  **Staging contour.** The interrupt-staging subsequence for `turn_id`, in
  offset order, must be exactly
  `[:interrupt_signaled, :interrupt_waited, :interrupt_killed, :turn_canceled]`
  — each stage journaled, in order, under one turn id.
  """
  @spec assert_staging!([map()], String.t()) :: :ok
  def assert_staging!(records, turn_id) do
    seq = staged_sequence(records, turn_id)
    expected = Interrupt.sequence()

    assert seq == expected,
           "staged-kill sequence for turn #{turn_id} was #{inspect(seq)}, " <>
             "expected #{inspect(expected)} (signal → wait → kill → turn_canceled, " <>
             "each an event, in order, same turn_id)"

    :ok
  end

  @doc """
  **Turn-canceled contour.** The turn's terminal record is `:turn_canceled`, and
  the outcome reports a cancel reason.
  """
  @spec assert_turn_canceled!([map()], String.t(), Interrupt.outcome()) :: :ok
  def assert_turn_canceled!(records, turn_id, outcome) do
    turn_recs = for r <- records, r["turn_id"] == turn_id, do: r
    last = List.last(turn_recs)

    assert last && last["type"] == "turn_canceled",
           "turn #{turn_id} did not terminate with turn_canceled " <>
             "(terminal record: #{inspect(last && last["type"])})"

    assert Map.has_key?(outcome, :reason),
           "interrupt outcome carries no cancel reason: #{inspect(outcome)}"

    :ok
  end

  @doc """
  **Effectiveness contour** (the spike verdict). OS ground truth, never
  `:exit_status`: the tool's top process AND its `sleep` grandchild are both
  gone after the interrupt, and the outcome reports OS-confirmed death. A
  top-pid kill leaves the orphaned grandchild alive → this raises.
  """
  @spec assert_effective!(map(), Interrupt.outcome()) :: :ok
  def assert_effective!(lab, outcome) do
    alias Raxol.Agent.KillLab

    assert KillLab.await_dead(lab.os_pid),
           "tool process #{lab.os_pid} survived the interrupt"

    # Polled, symmetric with the top-pid check above (a single non-polling
    # `ps` on the grandchild was a CI flake vector: reaping can lag the top
    # pid's death by a beat).
    assert KillLab.await_dead(lab.child_pid),
           "orphaned grandchild #{lab.child_pid} survived the interrupt — the " <>
             "kill trusted :exit_status / killed only the top pid instead of the " <>
             "process group"

    assert outcome.confirmed_dead?,
           "interrupt did not OS-confirm death out-of-band (outcome: #{inspect(outcome)})"

    :ok
  end

  @doc """
  **Post-kill quiescence contour** (the no-zombie-emission law). After the
  `:interrupt_killed` (kill-complete) record for `turn_id`, no `item_delta` /
  `item_completed` / tool-result record for that turn may appear. Folds the
  journal to check.
  """
  @spec assert_quiescent!([map()], String.t()) :: :ok
  def assert_quiescent!(records, turn_id) do
    turn_recs = for r <- records, r["turn_id"] == turn_id, do: r
    kill_idx = Enum.find_index(turn_recs, &(&1["type"] == "interrupt_killed"))

    assert kill_idx,
           "no interrupt_killed (kill-complete) record for turn #{turn_id} — " <>
             "quiescence is undefined without a kill fence"

    offenders =
      turn_recs
      |> Enum.drop(kill_idx + 1)
      |> Enum.filter(&(&1["type"] in @output_types))
      |> Enum.map(& &1["type"])

    assert offenders == [],
           "post-kill quiescence violated for turn #{turn_id}: " <>
             "#{inspect(offenders)} emitted AFTER kill-complete (the no-zombie law)"

    :ok
  end

  @doc """
  **No-trailing-output contour** for a mid-provider-stream interrupt (no tool
  Port): after `:turn_canceled` there is no output event, and the turn produced
  no `item_delta`/`item_completed` after the cancel signal landed.
  """
  @spec assert_no_trailing_output!([map()], String.t()) :: :ok
  def assert_no_trailing_output!(records, turn_id) do
    turn_recs = for r <- records, r["turn_id"] == turn_id, do: r
    cancel_idx = Enum.find_index(turn_recs, &(&1["type"] == "turn_canceled"))

    assert cancel_idx,
           "no turn_canceled record for mid-stream turn #{turn_id}"

    offenders =
      turn_recs
      |> Enum.drop(cancel_idx + 1)
      |> Enum.filter(&(&1["type"] in @output_types))
      |> Enum.map(& &1["type"])

    assert offenders == [],
           "mid-stream interrupt left trailing output for turn #{turn_id}: " <>
             "#{inspect(offenders)} after turn_canceled"

    :ok
  end

  @doc """
  **Escalation-conditionality contour** (the substantive half of "staged" —
  the spike's gotcha #4 in reverse: a well-behaved tool must NOT still be
  hard-killed). When the tool exits cooperatively during the grace window
  after the signal, the kill must short-circuit: `:interrupt_signaled` then
  straight to `:turn_canceled` — no `:interrupt_waited` (the frozen doc: the
  wait stage is "the bounded grace window elapsed WITHOUT the tool exiting"),
  no `:interrupt_killed`. An implementation that escalates unconditionally —
  hard-killing a tool that already exited on its own — raises here.
  """
  @spec assert_short_circuit!([map()], String.t()) :: :ok
  def assert_short_circuit!(records, turn_id) do
    seq = staged_sequence(records, turn_id)

    assert Interrupt.signal_stage() in seq,
           "no :interrupt_signaled record for turn #{turn_id} (#{inspect(seq)})"

    assert Interrupt.kill_stage() not in seq,
           "cooperative tool for turn #{turn_id} was still hard-killed " <>
             "(#{inspect(seq)}) — escalation must be conditional on the tool " <>
             "surviving the grace window, not unconditional"

    assert Interrupt.wait_stage() not in seq,
           "cooperative tool for turn #{turn_id} still recorded the wait stage " <>
             "(#{inspect(seq)}) — the wait stage means the grace window elapsed " <>
             "WITHOUT the tool exiting, which did not happen here"

    :ok
  end

  @doc """
  **Kill-failure arm** (the kill-claim-integrity contour). When the OS kill
  signal did NOT land, the trace must not forge a completed kill: the distinct
  `:interrupt_kill_failed` fence is journaled, `:interrupt_killed` is **not**,
  and the terminal `:turn_canceled` still lands (cancellation intent recorded).
  A trace that emits `:interrupt_killed` after a failed signal — the pre-fix
  behaviour, which discarded the `kill` exit status — raises here.
  """
  @spec assert_kill_failed!([map()], String.t()) :: :ok
  def assert_kill_failed!(records, turn_id) do
    types = for r <- records, r["turn_id"] == turn_id, do: r["type"]

    assert "interrupt_kill_failed" in types,
           "turn #{turn_id} did not journal the :interrupt_kill_failed fence after a " <>
             "failed OS kill (types: #{inspect(types)})"

    refute "interrupt_killed" in types,
           "turn #{turn_id} journaled :interrupt_killed although the OS kill signal " <>
             "failed — a kill that did not happen was claimed complete (types: " <>
             "#{inspect(types)})"

    assert "turn_canceled" in types,
           "turn #{turn_id} did not still record :turn_canceled after a failed kill " <>
             "(the cancellation intent must survive; types: #{inspect(types)})"

    :ok
  end

  @doc "Build a `FileStore`-backed durable sink for `turn_id` (the U5-R emit seam)."
  @spec journal_sink(term(), String.t(), term()) :: Interrupt.sink()
  def journal_sink(journal, session_id, turn_id) do
    fn type, payload ->
      {:ok, _offset} =
        Raxol.Agent.Journal.FileStore.append(journal, %{
          "v" => 0,
          "session_id" => to_string(session_id),
          "turn_id" => turn_id,
          "family" => "loop",
          "tier" => "durable",
          "type" => Atom.to_string(type),
          "payload" => stringify(payload)
        })

      :ok
    end
  end

  # The staging vocabulary as a fixed string→atom map. Never String.to_atom on
  # decoded input (unbounded atom growth); only the four frozen types map.
  @staging %{
    "interrupt_signaled" => :interrupt_signaled,
    "interrupt_waited" => :interrupt_waited,
    "interrupt_killed" => :interrupt_killed,
    "turn_canceled" => :turn_canceled
  }

  defp staged_sequence(records, turn_id) do
    for r <- records,
        r["turn_id"] == turn_id,
        atom = Map.get(@staging, r["type"]),
        not is_nil(atom),
        do: atom
  end

  defp stringify(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string(k), stringify(v)} end)
  end

  defp stringify(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: inspect(value)
end
