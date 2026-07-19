defmodule Raxol.Harness.Directive.Editor do
  @moduledoc """
  The frozen external-editor directive — the Ctrl+E `$EDITOR` bracket of
  the SessionPump ↔ HarnessApp contract (`Raxol.Harness.PumpContract`
  §7, unit A0). `update/2` returns it carrying the CURRENT composer
  draft; the Executor sends `{:harness_directive, directive}` to the
  pump, and the pump — the sole tty writer — runs the bracket
  synchronously:

    1. gate Engine painting via the named seam
       (`GenServer.call(engine, :suspend_painting)` /
       `:resume_painting` — a stub today, landed by the pump reshape,
       spec §9 risk 7);
    2. run the `Raxol.Harness.EditorSession` mechanics against its OWN
       `editor_session`/`editor_opts` (those never live in the model);
    3. re-probe geometry and follow with a resize dispatch if it
       changed;
    4. answer with exactly one `{:editor_result, outcome}` —
       `Raxol.Harness.PumpContract.editor_result/1`'s union.

  Messages arriving mid-bracket queue in the pump's mailbox and fold
  after resume — never painted while the editor owns the terminal.

  The model's fold on the result: `:ok` replaces the composer draft;
  `:kept`/`:error` render honest notices; a non-empty `degraded` list
  MUST surface a footer warning. Note this directive is what UN-GATES
  the editor for `:full_viewport` (today's Surface refuses it there):
  the pump owns the alt-screen bracket, so it can leave/re-enter around
  the editor instead of corrupting the alternate screen.

  Every execution emits `[:raxol, :harness, :directive, :dispatched]`
  telemetry (measurements `%{system_time: integer()}`, metadata
  `%{kind: :editor, action: :editor_bracket, pump: pid()}`).

  **Status: LIVE.** `HarnessApp.Model` returns this on the editor key
  (Ctrl-E) and `SessionPump` runs the bracket (suspend paint, hand the
  tty to $VISUAL/$EDITOR, resume with the edited draft — send +
  telemetry, deliberately thin).
  """

  @enforce_keys [:pump]
  defstruct [:pump, draft: ""]

  @type t :: %__MODULE__{pump: pid(), draft: String.t()}

  @doc "The envelope the Executor sends: `{:harness_directive, directive}`."
  @spec envelope(t()) :: {:harness_directive, t()}
  def envelope(%__MODULE__{} = directive), do: {:harness_directive, directive}

  @doc """
  Open `$EDITOR` on `draft` (the model's current composer value).
  Answered by exactly one `{:editor_result, outcome}`.
  """
  @spec open(pid(), String.t()) :: t()
  def open(pump, draft) when is_pid(pump) and is_binary(draft) do
    %__MODULE__{pump: pump, draft: draft}
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.Harness.Directive.Editor do
  alias Raxol.Harness.Directive.Editor

  # Thin by contract (A0): send + telemetry. The bracket mechanics land
  # with the pump reshape; frozen here are the envelope, the draft
  # payload, and the §7 bracket semantics in Editor's moduledoc.
  def execute(%Editor{pump: pump} = directive, _context) do
    :telemetry.execute(
      [:raxol, :harness, :directive, :dispatched],
      %{system_time: System.system_time()},
      %{kind: :editor, action: :editor_bracket, pump: pump}
    )

    send(pump, Editor.envelope(directive))
    :ok
  end
end
