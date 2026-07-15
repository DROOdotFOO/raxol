defmodule Raxol.Agent.Interrupt.Injectors do
  @moduledoc """
  U5-R injectors — complete-but-deliberately-wrong `Raxol.Agent.Interrupt`
  implementations, plus one correct reference.

  A negative control is only trustworthy if the guarded property is **green on
  correct** and **red on mutant** (`harness-invariants.md` meta-inv 4). So each
  contour gets both:

    * `Reference` — a minimal CORRECT staged-kill: it emits the full ordered
      trace and, when handed a real tool Port, performs the OS **process-group**
      kill. It is scaffolding for the controls, NOT the U5 implementation
      (`Raxol.Agent.Interrupt` stays unimplemented); the positive reds never
      touch it.
    * `SkipWait` / `TrustExitStatus` / `LateResult` — one mutant per contour,
      each recording its fault site so a dead injector is caught.
  """
end

defmodule Raxol.Agent.Interrupt.Injectors.Reference do
  @moduledoc "Correct staged-kill baseline (control scaffolding, not the U5 impl)."
  @behaviour Raxol.Agent.Interrupt

  alias Raxol.Agent.Interrupt
  alias Raxol.Agent.KillLab

  @impl true
  def interrupt(%{turn_id: turn_id} = ref, sink, _opts) do
    sink.(Interrupt.signal_stage(), %{})
    sink.(Interrupt.wait_stage(), %{grace_ms: Map.get(ref, :grace_ms, Interrupt.default_grace_ms())})

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
