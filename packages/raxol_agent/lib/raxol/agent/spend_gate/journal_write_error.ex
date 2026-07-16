defmodule Raxol.Agent.SpendGate.JournalWriteError do
  @moduledoc """
  A cost-journal write failed for REAL (not a dead test bus) while the
  SpendGate held irreversible spend state — a charged reserve, or a settle
  whose once-guard already flipped.

  The journal fold IS the accounting (AD-6a): a silently dropped record is
  silent divergence between the charged budget and the recorded truth — the
  exact loss the gate exists to prevent. So a real write failure is never
  swallowed into `:ok`; it propagates as this exception, carrying the exact
  `record` that failed to write. The caller that OWNS the budget seam
  (`context.try_reserve`) can then reconcile — refund a charged `estimate`,
  halt the run, or re-emit the record — instead of proceeding on accounting
  that quietly disagrees with the fold.

  The ONLY tolerated emit failure is an ephemeral `:noproc` exit (a dead
  in-memory test bus): there was no durable journal to diverge from. This is
  the same narrowing U12 applies in its `safe_emit`.
  """

  defexception [:record, :original]

  @type t :: %__MODULE__{
          record: map(),
          original: Exception.t() | {atom(), term()}
        }

  @impl Exception
  def message(%__MODULE__{record: record, original: original}) do
    "SpendGate cost-journal write failed for #{inspect(record)}: #{inspect(original)}"
  end
end
