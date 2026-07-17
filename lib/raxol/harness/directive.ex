defmodule Raxol.Harness.Directive do
  @moduledoc """
  Constructor facade for the harness directives — the OUT half of the
  frozen SessionPump ↔ HarnessApp contract (`Raxol.Harness.PumpContract`,
  unit A0). `HarnessApp.update/2` imports this one module and returns:

      import Raxol.Harness.Directive

      def update({:key, norm}, model) do
        ...
        {model, [submit(model.pump, text)]}
      end

  | Constructor | Directive | Answered by |
  |---|---|---|
  | `submit/2` | `Raxol.Harness.Directive.Lane` `:submit` | one `{:submit_result, _}` |
  | `interrupt/2` | `Lane` `:interrupt` | one `{:interrupt_result, _}` + event-observed acks in batches |
  | `steer/3` | `Lane` `:steer` | one terminal `{:steer_result, _}` |
  | `approval_answer/2` | `Lane` `:approval_answer` | one `{:approval_answer_result, _}` + `approval_decided` event |
  | `halt/1` | `Lane` `:halt` | nothing — teardown (PumpContract §8) |
  | `edit_draft/2` | `Raxol.Harness.Directive.Editor` | one `{:editor_result, _}` |

  Each struct implements `Raxol.Core.Runtime.Directive.Executor` (the
  Dispatcher's sanctioned extension point), so the Dispatcher's
  `directive?/1` gate accepts them like any framework directive. The
  shared runtime directives (`Raxol.Core.Runtime.Directive.stop/1` etc.)
  remain available but are NOT how the harness ends a session — teardown
  ordering belongs to the pump, so use `halt/1`.
  """

  alias Raxol.Harness.Directive.{Editor, Lane}

  @type t :: Lane.t() | Editor.t()

  @doc "See `Raxol.Harness.Directive.Lane.submit/2`."
  @spec submit(pid(), String.t()) :: Lane.t()
  defdelegate submit(pump, text), to: Lane

  @doc "See `Raxol.Harness.Directive.Lane.interrupt/2`."
  @spec interrupt(pid(), term()) :: Lane.t()
  defdelegate interrupt(pump, turn_id \\ nil), to: Lane

  @doc "See `Raxol.Harness.Directive.Lane.steer/3`."
  @spec steer(pid(), String.t(), term()) :: Lane.t()
  defdelegate steer(pump, text, expected_turn_id), to: Lane

  @doc "See `Raxol.Harness.Directive.Lane.approval_answer/2`."
  @spec approval_answer(pid(), map()) :: Lane.t()
  defdelegate approval_answer(pump, answer), to: Lane

  @doc "See `Raxol.Harness.Directive.Lane.halt/1`."
  @spec halt(pid()) :: Lane.t()
  defdelegate halt(pump), to: Lane

  @doc "See `Raxol.Harness.Directive.Editor.open/2`."
  @spec edit_draft(pid(), String.t()) :: Editor.t()
  defdelegate edit_draft(pump, draft), to: Editor, as: :open
end
