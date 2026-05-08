defmodule Raxol.Agent.Stream.Event do
  @moduledoc """
  Typed structs for `Raxol.Agent.Stream` events plus conversion helpers.

  `Stream.run/2` and `Stream.react/2` emit events as bare tuples for
  pattern-match ergonomics and backward compatibility:

      {:text_delta, "hello"}
      {:tool_use, %{name: "linear_graphql", arguments: %{}, id: "call_1"}}
      {:tool_result, %{name: "linear_graphql", result: %{...}}}
      {:turn_complete, %{content: "...", usage: %{}, iteration: 1}}
      {:done, %{content: "...", tool_results: [...], usage: %{}}}
      {:error, reason}

  Consumers that want stronger typing -- e.g., orchestrators forwarding
  events to surfaces -- can use `from_tuple/1` to lift each tuple into
  a typed struct, and `to_payload/1` to project it down to a generic
  map suitable for telemetry or pubsub.

  Both helpers are pure; they do not subscribe to or transform the
  underlying stream.

  ## Example

      stream = Raxol.Agent.Stream.run(prompt, opts)

      Enum.each(stream, fn event ->
        typed = Raxol.Agent.Stream.Event.from_tuple(event)
        send(parent, {:run_event, key, Raxol.Agent.Stream.Event.to_payload(typed)})
      end)

  See `Raxol.Agent.EventForwarder` for the common "send to parent" pattern
  packaged as a single call.
  """

  defmodule TextDelta do
    @moduledoc "Streaming text chunk from the LLM."
    @enforce_keys [:text]
    defstruct [:text]
    @type t :: %__MODULE__{text: String.t()}
  end

  defmodule ToolUse do
    @moduledoc "LLM is requesting a tool call."
    @enforce_keys [:name]
    defstruct [:name, :arguments, :id]

    @type t :: %__MODULE__{
            name: String.t(),
            arguments: map(),
            id: String.t() | nil
          }
  end

  defmodule ToolResult do
    @moduledoc "Result of executing a tool."
    @enforce_keys [:name, :result]
    defstruct [:name, :result]
    @type t :: %__MODULE__{name: String.t(), result: term()}
  end

  defmodule TurnComplete do
    @moduledoc "End of one ReAct turn."
    @enforce_keys [:content]
    defstruct [:content, :usage, :iteration]

    @type t :: %__MODULE__{
            content: String.t(),
            usage: map(),
            iteration: non_neg_integer()
          }
  end

  defmodule Done do
    @moduledoc "Final answer from the agent."
    @enforce_keys [:content]
    defstruct [:content, :tool_results, :usage]

    @type t :: %__MODULE__{
            content: String.t(),
            tool_results: list(),
            usage: map()
          }
  end

  defmodule Error do
    @moduledoc "Error during stream execution."
    @enforce_keys [:reason]
    defstruct [:reason]
    @type t :: %__MODULE__{reason: term()}
  end

  @type t ::
          TextDelta.t()
          | ToolUse.t()
          | ToolResult.t()
          | TurnComplete.t()
          | Done.t()
          | Error.t()

  @type tuple_event :: Raxol.Agent.Stream.event()

  @doc """
  Lifts a stream tuple into the corresponding typed struct.

  Unknown shapes return an `Error` struct rather than raising, so a single
  bad event never aborts a forwarding pipeline.
  """
  @spec from_tuple(tuple_event() | term()) :: t()
  def from_tuple({:text_delta, text}) when is_binary(text),
    do: %TextDelta{text: text}

  def from_tuple({:tool_use, %{name: name} = info}) when is_binary(name) do
    %ToolUse{
      name: name,
      arguments: Map.get(info, :arguments, %{}),
      id: Map.get(info, :id)
    }
  end

  def from_tuple({:tool_result, %{name: name, result: result}})
      when is_binary(name),
      do: %ToolResult{name: name, result: result}

  def from_tuple({:turn_complete, %{} = info}) do
    %TurnComplete{
      content: Map.get(info, :content, ""),
      usage: Map.get(info, :usage, %{}),
      iteration: Map.get(info, :iteration, 0)
    }
  end

  def from_tuple({:done, %{} = info}) do
    %Done{
      content: Map.get(info, :content, ""),
      tool_results: Map.get(info, :tool_results, []),
      usage: Map.get(info, :usage, %{})
    }
  end

  def from_tuple({:error, reason}), do: %Error{reason: reason}
  def from_tuple(other), do: %Error{reason: {:unknown_event, other}}

  @doc """
  Projects an event (tuple or struct) onto a generic map suitable for
  telemetry, pubsub, or surface forwarding.

  All payloads carry `:event` (atom name), `:timestamp`, and a `:message`
  string. Specific events add `:usage` (TurnComplete, Done) or `:payload`
  (ToolUse, ToolResult) when present. The shape mirrors what
  `Raxol.Symphony.Orchestrator` already integrates so existing surface
  consumers don't need to change.
  """
  @spec to_payload(t() | tuple_event()) :: map()
  def to_payload(%TextDelta{text: text}),
    do: base(:text_delta, text)

  def to_payload(%ToolUse{name: name} = ev) do
    base(:tool_use, "tool: #{name}")
    |> Map.put(:payload, %{name: ev.name, arguments: ev.arguments, id: ev.id})
  end

  def to_payload(%ToolResult{name: name} = ev) do
    base(:tool_result, "result: #{name}")
    |> Map.put(:payload, %{name: ev.name, result: ev.result})
  end

  def to_payload(%TurnComplete{} = ev) do
    base(:turn_completed, "turn complete")
    |> Map.put(:usage, ev.usage)
  end

  def to_payload(%Done{} = ev) do
    base(:turn_completed, ev.content || "done")
    |> Map.put(:usage, ev.usage)
  end

  def to_payload(%Error{reason: reason}),
    do: base(:turn_failed, inspect(reason))

  def to_payload(tuple) when is_tuple(tuple),
    do: tuple |> from_tuple() |> to_payload()

  defp base(event, message) do
    %{
      event: event,
      message: message,
      timestamp: DateTime.utc_now()
    }
  end
end
