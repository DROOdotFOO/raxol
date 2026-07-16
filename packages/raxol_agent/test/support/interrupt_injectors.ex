defmodule Raxol.Agent.Interrupt.Injectors do
  @moduledoc """
  U5-R injectors — complete-but-deliberately-wrong `Raxol.Agent.Interrupt`
  implementations, plus one correct reference.

  A negative control is only trustworthy if the guarded property is **green on
  correct** and **red on mutant** (`harness-invariants.md` meta-inv 4). So each
  contour gets both:

    * `Reference` — a minimal CORRECT staged-kill: it emits the full ordered
      trace and, when handed a real tool Port, performs the OS **process-group**
      kill — CONDITIONALLY: a tool that exits cooperatively during the grace
      window short-circuits (no wait/kill stage); only a tool that survives
      the window escalates. It is scaffolding for the controls, NOT the U5
      implementation (`Raxol.Agent.Interrupt` stays unimplemented); the
      positive reds never touch it.
    * `SkipWait` / `TrustExitStatus` / `LateResult` / `TrustReason` /
      `TrailingOutput` / `NaiveEscalate` / `WaitKillTransposed` — one mutant
      per contour, each recording its fault site so a dead injector is caught.
  """
end

defmodule Raxol.Agent.Interrupt.Injectors.Reference do
  @moduledoc """
  Correct staged-kill baseline (control scaffolding, not the U5 impl).

  Escalation is CONDITIONAL on tool behavior — the substantive half of
  "staged" (spike gotcha #4 in reverse). Right after the signal, a real tool
  gets its grace window to exit cooperatively:

    * exits within it → short-circuit. Per `Interrupt`'s own doc, the wait
      stage IS "the bounded grace window elapsed WITHOUT the tool exiting" —
      so if it exits, that stage never happened and is never journaled, and
      there is nothing to hard-kill.
    * survives it → escalate: journal the wait stage, then group-SIGKILL.

  A tool-less ref (mid-provider-stream, no `os_pid`) has nothing to wait for
  and always escalates straight through (the kill stage is a no-op bookkeeping
  event in that case, matching the frozen 4-stage sequence the P1 contour
  pins).
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.KillLab

  @impl true
  def interrupt(%{turn_id: turn_id} = ref, sink, _opts) do
    maybe_signal_group(ref)
    sink.(Interrupt.signal_stage(), %{})
    grace_ms = Map.get(ref, :grace_ms, Interrupt.default_grace_ms())

    case cooperative_exit(ref, grace_ms) do
      {:short_circuit, os_pid} ->
        sink.(Interrupt.terminal(), %{reason: :interrupted})

        {:ok,
         %{
           turn_id: turn_id,
           stages: [Interrupt.signal_stage()],
           reason: :interrupted,
           os_pid: os_pid,
           killed?: false,
           confirmed_dead?: true
         }}

      :escalate ->
        sink.(Interrupt.wait_stage(), %{grace_ms: grace_ms})

        {killed?, confirmed?, os_pid} = maybe_group_kill(ref)

        sink.(Interrupt.kill_stage(), %{os_pid: os_pid})
        sink.(Interrupt.terminal(), %{reason: :interrupted})

        {:ok,
         %{
           turn_id: turn_id,
           stages: Interrupt.stages(),
           reason: :interrupted,
           os_pid: os_pid,
           killed?: killed?,
           confirmed_dead?: confirmed?
         }}
    end
  end

  # Real tool present → actually send the cooperative signal (group SIGTERM;
  # spike gotcha #4: signaling just the top pid does not cascade to the
  # group). No tool (mid-provider-stream) → nothing to signal.
  defp maybe_signal_group(%{os_pid: os_pid}) when is_integer(os_pid),
    do: _ = KillLab.signal_group(os_pid)

  defp maybe_signal_group(_ref), do: :ok

  # Real tool present → give it the grace window to exit on its own. No tool
  # (mid-provider-stream) → nothing to wait for, always escalate.
  defp cooperative_exit(%{os_pid: os_pid}, grace_ms) when is_integer(os_pid) do
    if KillLab.await_dead(os_pid, grace_ms), do: {:short_circuit, os_pid}, else: :escalate
  end

  defp cooperative_exit(_ref, _grace_ms), do: :escalate

  # Real tool present → the correct OS answer: group SIGKILL, then confirm death
  # out-of-band (never :exit_status).
  defp maybe_group_kill(%{os_pid: os_pid}) when is_integer(os_pid) do
    _ = KillLab.group_kill(os_pid)
    {true, KillLab.await_dead(os_pid), os_pid}
  end

  defp maybe_group_kill(_ref), do: {false, false, nil}
end

defmodule Raxol.Agent.Interrupt.Injectors.SkipWait do
  @moduledoc "MUTANT: skips the bounded-wait stage (signal → kill). Fails the staging contour."
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults

  @impl true
  def interrupt(%{turn_id: turn_id}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :skip_wait)

    sink.(Interrupt.signal_stage(), %{})
    # BUG: no Interrupt.wait_stage() — escalates straight to the hard kill.
    sink.(Interrupt.kill_stage(), %{})
    sink.(Interrupt.terminal(), %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: [Interrupt.signal_stage(), Interrupt.kill_stage()],
       reason: :interrupted,
       os_pid: nil,
       killed?: true,
       confirmed_dead?: true
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.LateResult do
  @moduledoc "MUTANT: lets a tool_result through AFTER kill-complete. Fails the quiescence contour."
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults

  @impl true
  def interrupt(%{turn_id: turn_id}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :late_result)

    sink.(Interrupt.signal_stage(), %{})
    sink.(Interrupt.wait_stage(), %{})
    sink.(Interrupt.kill_stage(), %{})
    # BUG: a zombie tool_result escapes the kill fence (violates the no-zombie law).
    sink.(:item_completed, %{item_type: "tool_result", result: "late zombie output"})
    sink.(Interrupt.terminal(), %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: Interrupt.stages(),
       reason: :interrupted,
       os_pid: nil,
       killed?: true,
       confirmed_dead?: true
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.TrustExitStatus do
  @moduledoc """
  MUTANT: kills only the tool's TOP pid and trusts `:exit_status` (claims death)
  instead of confirming process-group death — orphans the `sleep` grandchild.
  Fails the effectiveness contour.
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults
  alias Raxol.Agent.KillLab

  @impl true
  def interrupt(%{turn_id: turn_id, os_pid: os_pid}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :trust_exit_status)

    sink.(Interrupt.signal_stage(), %{})
    sink.(Interrupt.wait_stage(), %{})
    # BUG: top-pid-only SIGKILL, then trust that the tool is gone. The grandchild
    # is reparented and lives on, forging "port closed / exit_status delivered".
    KillLab.top_pid_kill(os_pid)
    sink.(Interrupt.kill_stage(), %{os_pid: os_pid})
    sink.(Interrupt.terminal(), %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: Interrupt.stages(),
       reason: :interrupted,
       os_pid: os_pid,
       killed?: true,
       # THE LIE: trusted :exit_status, never OS-confirmed the whole group.
       confirmed_dead?: true
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.TrustReason do
  @moduledoc """
  MUTANT: emits the WRONG terminal event type — carries the right `:reason` in
  the outcome but never journals the frozen `:turn_canceled` terminal record.
  A reader that trusts the returned `outcome.reason` without checking the
  actual journal record type would miss this. Fails the turn-canceled contour
  (P2).
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults

  @impl true
  def interrupt(%{turn_id: turn_id}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :trust_reason)

    sink.(Interrupt.signal_stage(), %{})
    sink.(Interrupt.wait_stage(), %{})
    sink.(Interrupt.kill_stage(), %{})
    # BUG: a made-up terminal type instead of the frozen :turn_canceled.
    sink.(:turn_ended, %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: Interrupt.stages(),
       reason: :interrupted,
       os_pid: nil,
       killed?: true,
       confirmed_dead?: true
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.TrailingOutput do
  @moduledoc """
  MUTANT: mid-provider-stream (no tool Port) — lets a stream chunk through
  AFTER the terminal `:turn_canceled` record, as if the cancel raced the
  provider stream and lost. Fails the no-trailing-output contour (P3b).
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults

  @impl true
  def interrupt(%{turn_id: turn_id}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :trailing_output)

    sink.(Interrupt.signal_stage(), %{})
    sink.(Interrupt.wait_stage(), %{})
    sink.(Interrupt.kill_stage(), %{})
    sink.(Interrupt.terminal(), %{reason: :interrupted})
    # BUG: a provider-stream chunk lands after the turn already canceled.
    sink.(:item_delta, %{chunk: "trailing chunk"})

    {:ok,
     %{
       turn_id: turn_id,
       stages: Interrupt.stages(),
       reason: :interrupted,
       os_pid: nil,
       killed?: false,
       confirmed_dead?: false
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.NaiveEscalate do
  @moduledoc """
  MUTANT: the naive-signal-that-still-kills-a-cooperative-tool bug. It DOES
  send the cooperative group SIGTERM (so a well-behaved tool dies from the
  signal, same as the reference) but never checks whether that worked before
  escalating — signal → wait → kill unconditionally, hard-killing a group
  that (usually) already has nothing left alive in it. Fails the
  escalation-conditionality contour.
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults
  alias Raxol.Agent.KillLab

  @impl true
  def interrupt(%{turn_id: turn_id, os_pid: os_pid} = ref, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :naive_escalate)

    _ = KillLab.signal_group(os_pid)
    sink.(Interrupt.signal_stage(), %{})
    grace_ms = Map.get(ref, :grace_ms, Interrupt.default_grace_ms())
    # BUG: no cooperative-exit check at all — always waits out the full grace
    # window and always escalates, regardless of whether the signal already
    # finished the job.
    Process.sleep(grace_ms)
    sink.(Interrupt.wait_stage(), %{grace_ms: grace_ms})
    _ = KillLab.group_kill(os_pid)
    sink.(Interrupt.kill_stage(), %{os_pid: os_pid})
    sink.(Interrupt.terminal(), %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: Interrupt.stages(),
       reason: :interrupted,
       os_pid: os_pid,
       killed?: true,
       confirmed_dead?: true
     }}
  end
end

defmodule Raxol.Agent.Interrupt.Injectors.WaitKillTransposed do
  @moduledoc """
  MUTANT: kills BEFORE waiting — signal → kill → wait instead of signal →
  wait → kill. Fails the staging contour's ordering (a transposition mutant,
  distinct from `SkipWait`'s omission mutant).
  """
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.Interrupt.Faults

  @impl true
  def interrupt(%{turn_id: turn_id}, sink, opts) do
    if h = opts[:faults], do: Faults.record_fired(h, :wait_kill_transposed)

    sink.(Interrupt.signal_stage(), %{})
    # BUG: kill-then-wait instead of wait-then-kill.
    sink.(Interrupt.kill_stage(), %{})
    sink.(Interrupt.wait_stage(), %{})
    sink.(Interrupt.terminal(), %{reason: :interrupted})

    {:ok,
     %{
       turn_id: turn_id,
       stages: [Interrupt.signal_stage(), Interrupt.kill_stage(), Interrupt.wait_stage()],
       reason: :interrupted,
       os_pid: nil,
       killed?: true,
       confirmed_dead?: true
     }}
  end
end
