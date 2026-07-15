defmodule Raxol.Agent.Interrupt do
  @moduledoc """
  U5 — Interrupt is a **staged supervised kill** of a running turn/tool (AD-12).

  This module is the **enabler skeleton** for U5-I: it freezes the observable
  contract the U5-R red suite is authored against, but carries **no
  implementation**. `interrupt/3` raises until U5-I lands. Everything the reds
  assert is expressed here as a stable vocabulary + a behaviour so the red suite
  and the eventual implementation reference one source of truth.

  ## What interrupt IS (from the dispositions + the U5 spike)

  Interrupt is not a flag the loop polls. It is a bounded escalation, each stage
  a **durable event** (the staging is observable in the journal):

      cooperative signal  →  bounded wait  →  OS process-group SIGKILL

  mapped to the vocabulary below:

    * `:interrupt_signaled` — the cooperative cancel request (group SIGTERM);
      a well-behaved tool stops here.
    * `:interrupt_waited`   — the bounded grace window elapsed without the tool
      exiting cooperatively (the empirical regime gap is orders of magnitude:
      a nice tool exits in ~2–11 ms, a rogue one never; the exact grace value
      is a per-tool policy knob, not a contract, see `default_grace_ms/0`).
    * `:interrupt_killed`   — the hard **process-group** SIGKILL landed and OS
      death was confirmed **out-of-band** (`ps`), never by trusting
      `:exit_status`. This is the **kill-complete** fence.
    * `:turn_canceled`      — the terminal turn bracket carrying `%{reason}`
      (new loop vocabulary; already frozen into the journal's CONVERSATIONAL
      tip set by `harness-freeze-contracts.md` §1.1).

  ## The two laws U5-R pins

  1. **Effectiveness (the spike verdict).** Killing the BEAM process that owns
     the Port buys nothing against a hostile tool — `Port.close` /
     `Process.exit(owner, :kill)` leave the OS process alive and orphan its
     grandchild, and a surviving grandchild forges "`:exit_status` never
     arrived". The ONLY thing that works is the OS **process-group** SIGKILL
     (`kill -9 -<os_pid>`; BEAM already makes each port program its own pgroup
     leader, so `pgid == os_pid`), confirmed dead at the OS level. **Never trust
     `:exit_status` (or its absence) as the death signal.**

  2. **Post-kill quiescence (the no-zombie-emission law).** After the
     `:interrupt_killed` (kill-complete) event, NO `item_delta` / `item_completed`
     / tool-result event for that turn may **ever** appear. A late result folded
     out of the journal after kill-complete is a contract violation.

  ## The behaviour seam

  `interrupt/3` takes:

    * a `t:tool_ref/0` — the turn id plus (when a shell tool is running) the
      `Port` and its captured `os_pid`. `port`/`os_pid` are `nil` when the
      interrupt lands mid-provider-stream (nothing to group-kill; the loop is
      simply canceled and `:turn_canceled` emitted with no trailing output).
    * a `t:sink/0` — the durable-emit callback. In production this reaches the
      journal via `EmitBridge`/`SessionStreamer`; the U5-R red suite passes a
      `Raxol.Agent.Journal.FileStore`-backed sink so the staged trace is
      fold-checkable without the full session tree. Either way, **each stage
      emits a durable event through this seam** — that IS the "staging is
      observable" contract.

  U5-I implements this behaviour (replacing the `interrupt/3` body); the reds
  flip from red to green the moment it does.
  """

  @signal :interrupt_signaled
  @wait :interrupt_waited
  @kill :interrupt_killed
  @terminal :turn_canceled
  @default_grace_ms 300

  @typedoc "The three staged-kill event types, in escalation order."
  @type stage :: :interrupt_signaled | :interrupt_waited | :interrupt_killed

  @typedoc "The terminal turn bracket emitted once the kill is complete."
  @type terminal :: :turn_canceled

  @typedoc "Why the turn was canceled (carried in the `:turn_canceled` payload)."
  @type reason :: atom() | {atom(), term()}

  @typedoc """
  A handle on the turn (and its running tool, if any) to interrupt.

    * `:turn_id` — the turn whose staged events all share this id.
    * `:port` / `:os_pid` — the running shell tool's Port and captured OS pid;
      both `nil` when no tool is running (mid-provider-stream interrupt).
    * `:grace_ms` — optional per-tool override of `default_grace_ms/0`.
  """
  @type tool_ref :: %{
          required(:turn_id) => String.t(),
          optional(:port) => port() | nil,
          optional(:os_pid) => non_neg_integer() | nil,
          optional(:grace_ms) => pos_integer()
        }

  @typedoc """
  The durable-emit callback. Called once per staged event and once for the
  terminal `:turn_canceled`; returns `:ok`. This is the boundary at which "each
  stage emits a durable event" is satisfied.
  """
  @type sink :: (stage() | terminal(), map() -> :ok)

  @typedoc """
  The result of a staged kill.

    * `:stages` — the staged event types actually emitted, in order.
    * `:reason` — the `:turn_canceled` reason.
    * `:killed?` — a group SIGKILL was issued (false when there was no tool).
    * `:confirmed_dead?` — OS-level death was confirmed **out-of-band**, never
      inferred from `:exit_status`.
  """
  @type outcome :: %{
          turn_id: String.t(),
          stages: [stage()],
          reason: reason(),
          os_pid: non_neg_integer() | nil,
          killed?: boolean(),
          confirmed_dead?: boolean()
        }

  @doc """
  Run the staged supervised kill for `tool_ref`, emitting each stage through
  `sink`. Implemented by U5-I; raises until then.
  """
  @callback interrupt(tool_ref(), sink(), keyword()) ::
              {:ok, outcome()} | {:error, term()}

  @doc """
  Staged supervised kill entry point — the U5-I seam.

  **Not implemented.** Raises until U5-I (AD-12) lands; the U5-R red suite is
  red-by-design against this until the implementation replaces this body.
  """
  @spec interrupt(tool_ref(), sink(), keyword()) ::
          {:ok, outcome()} | {:error, term()}
  def interrupt(_tool_ref, _sink, _opts \\ []) do
    raise "Raxol.Agent.Interrupt.interrupt/3 not implemented — U5-I (AD-12, " <>
            "staged supervised kill) fills this in. The U5-R red suite is " <>
            "red-by-design (@moduletag :harness_red, excluded from CI) until then."
  end

  @doc "The stage-1 event type — cooperative cancel (group SIGTERM)."
  @spec signal_stage() :: :interrupt_signaled
  def signal_stage, do: @signal

  @doc "The stage-2 event type — the bounded grace window elapsed."
  @spec wait_stage() :: :interrupt_waited
  def wait_stage, do: @wait

  @doc "The stage-3 event type — group SIGKILL landed, OS death confirmed (kill-complete)."
  @spec kill_stage() :: :interrupt_killed
  def kill_stage, do: @kill

  @doc "The three staged-kill event types, in escalation order."
  @spec stages() :: [stage()]
  def stages, do: [@signal, @wait, @kill]

  @doc "The terminal turn-bracket event type (`:turn_canceled`)."
  @spec terminal() :: :turn_canceled
  def terminal, do: @terminal

  @doc """
  The full observable sequence a staged kill emits into the journal, in order:
  `[:interrupt_signaled, :interrupt_waited, :interrupt_killed, :turn_canceled]`.
  """
  @spec sequence() :: [stage() | terminal()]
  def sequence, do: stages() ++ [@terminal]

  @doc """
  Default grace window (ms) between the cooperative signal and the hard kill.

  Policy, not contract: the spike found the nice/rogue regime gap is orders of
  magnitude, so the exact value is not delicate. The reds assert the wait
  **stage** happens, never a specific latency.
  """
  @spec default_grace_ms() :: pos_integer()
  def default_grace_ms, do: @default_grace_ms
end
