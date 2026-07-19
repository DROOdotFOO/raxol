defmodule Raxol.Harness.Directive.Lane do
  @moduledoc """
  The frozen lane-command directive — the OUT half of the SessionPump ↔
  HarnessApp contract (`Raxol.Harness.PumpContract`, unit A0).
  `HarnessApp.update/2` returns these in its command list; the
  Dispatcher's Directive protocol (`Raxol.Core.Runtime.Directive.Executor`,
  the sanctioned extension point) executes them by sending
  `{:harness_directive, directive}` to the pump. The pump performs the
  lane mechanics and answers with the matching `PumpContract` result
  message — the full request/response pairing:

  | `action` | payload (frozen shape) | pump mechanics | result message |
  |---|---|---|---|
  | `:submit` | `%{text: binary}` | `lane.submit/2` | `{:submit_result, _}` — exactly one |
  | `:interrupt` | `%{}` or `%{turn_id: id}` (advisory attribution, today's lane wire shape — the running turn is decided at the session) | `lane.interrupt/2`, fire-and-forget | `{:interrupt_result, _}` — dispatch outcome; real acks arrive as batch events |
  | `:steer` | `%{text: binary, expected_turn_id: id_or_nil}` (the model's CAS belief travels IN the directive) | `Task.async` + timeout + kill; pump mints `client_msg_id` | `{:steer_result, _}` — exactly one TERMINAL result |
  | `:approval_answer` | `%{request_id: id, option_id: id, decision: :allow \\| :deny}` | `lane.answer_permission/2` | `{:approval_answer_result, _}` — dispatch outcome; receipt folds from the `approval_decided` event |
  | `:halt` | `%{}` | teardown sequence (PumpContract §8: paint gate → InlineDriver → alt-screen leave LAST → Lifecycle stop) | none — the session ends |

  ## Belief stays in the model (PumpContract §6)

  `update/2` gates BEFORE returning a directive: the submit busy-refusal
  (from `current_turn_id` + `needs_input`) and the steer
  single-in-flight refusal render honest notices INSTEAD of minting a
  directive. The directive carries the belief the mechanics need
  (`expected_turn_id`, advisory `turn_id`); the pump never invents
  either.

  ## Addressing

  The struct carries the pump `pid` explicitly (seeded into the model at
  `init/1` by the pump that booted the Lifecycle; a fixture pump seeds
  itself). No registry, no context plumbing: the same app code runs
  live, under a fixture pump, and in tests where the pump is the test
  process. Execution is a plain `send` — fire-and-forget by design; the
  pump owns the Lifecycle, so a dead pump means the session is already
  ending (supervision fact, not contract surface).

  Every execution emits `[:raxol, :harness, :directive, :dispatched]`
  telemetry (measurements `%{system_time: integer()}`, metadata
  `%{kind: :lane, action: action(), pump: pid()}`).

  **Status: LIVE.** `HarnessApp.Model.update/2` returns these from the
  submit/steer/interrupt folds and `SessionPump`'s executor sends them
  (send + telemetry, deliberately thin).
  """

  @enforce_keys [:pump, :action]
  defstruct [:pump, :action, payload: %{}]

  @type action :: :submit | :interrupt | :steer | :approval_answer | :halt

  @type t :: %__MODULE__{pump: pid(), action: action(), payload: map()}

  @doc "The envelope the Executor sends: `{:harness_directive, directive}`."
  @spec envelope(t()) :: {:harness_directive, t()}
  def envelope(%__MODULE__{} = directive), do: {:harness_directive, directive}

  @doc "Submit the composed prompt. Answered by exactly one `{:submit_result, _}`."
  @spec submit(pid(), String.t()) :: t()
  def submit(pump, text) when is_pid(pump) and is_binary(text) do
    %__MODULE__{pump: pump, action: :submit, payload: %{text: text}}
  end

  @doc """
  Interrupt the RUNNING turn (fire-and-forget staged kill). `turn_id` is
  advisory attribution only — `nil` produces the empty payload, exactly
  the retired driver's lane wire shape
  (`LiveSessionDriver.interrupt_payload/1`).
  """
  @spec interrupt(pid(), term()) :: t()
  def interrupt(pump, turn_id \\ nil) when is_pid(pump) do
    payload = if is_nil(turn_id), do: %{}, else: %{turn_id: turn_id}
    %__MODULE__{pump: pump, action: :interrupt, payload: payload}
  end

  @doc """
  Steer the turn the model believes is running. `expected_turn_id` is
  the model's CAS belief (may be `nil` — the lane answers
  `{:error, :no_live_turn}` honestly). The pump mints the idempotency
  `client_msg_id`; `update/2` stays deterministic.
  """
  @spec steer(pid(), String.t(), term()) :: t()
  def steer(pump, text, expected_turn_id)
      when is_pid(pump) and is_binary(text) do
    %__MODULE__{
      pump: pump,
      action: :steer,
      payload: %{text: text, expected_turn_id: expected_turn_id}
    }
  end

  @doc """
  Answer a parked approval. The model resolved the keystroke into the
  concrete referent (`request_id`, `option_id`) from the live block's
  own options; `decision` is the `:allow`/`:deny` class hint.
  """
  @spec approval_answer(pid(), %{
          request_id: term(),
          option_id: term(),
          decision: :allow | :deny
        }) :: t()
  def approval_answer(
        pump,
        %{request_id: _, option_id: _, decision: decision} = answer
      )
      when is_pid(pump) and decision in [:allow, :deny] do
    %__MODULE__{
      pump: pump,
      action: :approval_answer,
      payload: Map.take(answer, [:request_id, :option_id, :decision])
    }
  end

  @doc """
  End the session — the ONLY teardown trigger (PumpContract §8).
  `update/2` seals any unsent draft into history BEFORE returning this;
  the pump owns every teardown byte and the Lifecycle stop. No result
  message follows.
  """
  @spec halt(pid()) :: t()
  def halt(pump) when is_pid(pump) do
    %__MODULE__{pump: pump, action: :halt, payload: %{}}
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor,
  for: Raxol.Harness.Directive.Lane do
  alias Raxol.Harness.Directive.Lane

  # Thin by contract (A0): send + telemetry, nothing else. The pump side
  # of the pairing (mechanics + result messages) lands with the pump
  # reshape; what is frozen here is the envelope and the semantics in
  # Lane's moduledoc table.
  def execute(%Lane{pump: pump, action: action} = directive, _context) do
    :telemetry.execute(
      [:raxol, :harness, :directive, :dispatched],
      %{system_time: System.system_time()},
      %{kind: :lane, action: action, pump: pump}
    )

    send(pump, Lane.envelope(directive))
    :ok
  end
end
