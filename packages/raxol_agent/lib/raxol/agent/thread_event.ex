defmodule Raxol.Agent.ThreadEvent do
  @moduledoc """
  One entry in a `Raxol.Agent.ThreadLog`.

  Append-only, keyed on `{thread_id, sequence}`. The adapter
  assigns `sequence` atomically on `append/4`; callers supply
  `thread_id`, `kind`, `payload`, and optional `metadata`.

  ## Kinds

  | Kind | Payload shape | Use |
  | --- | --- | --- |
  | `:directive` | the Directive struct emitted | record the agent's intent to fire an effect |
  | `:tool_call` | `%{name, arguments}` | record an LLM tool invocation request |
  | `:tool_result` | `%{name, result}` | record the result of a tool call |
  | `:message` | the message string or struct | a raw conversation message preserved before compaction |
  | `:state_snapshot` | the agent state map | a periodic snapshot for audit / replay |
  | `:summary` | the compactor's summary string | the marker left when `ContextCompactor` summarized older messages |
  | `:sandbox_deny` | `%{dimension, reason}` | record a sandbox denial |
  | `:policy_result` | `%{policy, decision, ...}` | record a policy outcome (cache hit, retry attempt, timeout, ...) |

  Adapters MAY round-trip arbitrary additional kinds; the canonical
  set above is what the framework emits.

  ## Metadata

  Arbitrary map. The framework attaches `:causation_id` when
  available (chained from the CloudEvents envelope). Callers
  may attach anything; adapters preserve it verbatim.
  """

  @type kind ::
          :directive
          | :tool_call
          | :tool_result
          | :message
          | :state_snapshot
          | :summary
          | :sandbox_deny
          | :policy_result
          | atom()

  @type t :: %__MODULE__{
          thread_id: binary(),
          sequence: non_neg_integer(),
          kind: kind(),
          payload: term(),
          metadata: map(),
          recorded_at: DateTime.t()
        }

  @enforce_keys [:thread_id, :sequence, :kind, :recorded_at]
  defstruct [
    :thread_id,
    :sequence,
    :kind,
    :recorded_at,
    payload: nil,
    metadata: %{}
  ]

  @doc """
  Construct a ThreadEvent. Used by adapters when materializing
  events from storage; callers use the `ThreadLog.append/4`
  dispatcher instead (which produces these via the adapter).
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      thread_id: Keyword.fetch!(opts, :thread_id),
      sequence: Keyword.fetch!(opts, :sequence),
      kind: Keyword.fetch!(opts, :kind),
      payload: Keyword.get(opts, :payload),
      metadata: Keyword.get(opts, :metadata, %{}),
      recorded_at: Keyword.get_lazy(opts, :recorded_at, &DateTime.utc_now/0)
    }
  end
end
