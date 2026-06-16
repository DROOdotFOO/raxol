defmodule Raxol.Agent.Conversation.Recorder do
  @moduledoc """
  Records `Raxol.Agent.Stream` events into a `Raxol.Agent.Conversation.Log`.

  Bridges the ephemeral agent event stream to the durable item log, mapping each
  event tuple to one (or zero) conversation items:

  | event | item |
  | --- | --- |
  | `{:tool_use, %{name, arguments, id}}` | `:tool_call` |
  | `{:tool_result, %{name, result}}` | `:tool_result` |
  | `{:done, %{content, usage}}` | `:message` (assistant) |
  | `{:error, reason}` | `:error` |
  | `{:text_delta, _}` / `{:turn_complete, _}` | (none -- content lands at `:done`) |

  Pass `:response_id` in `opts` to tag every recorded item with the turn it
  belongs to.

  ## Usage

      stream = Raxol.Agent.Stream.react(prompt, backend: ..., actions: [...])
      {:ok, items} = Recorder.record_stream(log, "conv-1", stream, response_id: "r1")
  """

  alias Raxol.Agent.Conversation.{Item, Log}

  @doc "Record a single agent event; returns the items appended (possibly none)."
  @spec record_event(Log.server(), binary(), keyword(), tuple()) :: {:ok, [Item.t()]}
  def record_event(log, conversation_id, opts, event) do
    case items_for(event, opts) do
      [] -> {:ok, []}
      new_items -> Log.append(log, conversation_id, new_items)
    end
  end

  @doc """
  Record an entire agent stream into the log.

  Drains the stream (recording each event) and returns every appended item in
  order. Side effect: the stream is consumed.
  """
  @spec record_stream(Log.server(), binary(), Enumerable.t(), keyword()) :: {:ok, [Item.t()]}
  def record_stream(log, conversation_id, stream, opts \\ []) do
    items =
      Enum.flat_map(stream, fn event ->
        {:ok, items} = record_event(log, conversation_id, opts, event)
        items
      end)

    {:ok, items}
  end

  # -- Event -> item mapping --------------------------------------------------

  defp items_for({:tool_use, %{name: name} = tu}, opts) do
    [
      %{
        type: :tool_call,
        status: :completed,
        created_by: :assistant,
        response_id: response_id(opts),
        data: %{name: name, arguments: Map.get(tu, :arguments, %{}), id: Map.get(tu, :id)}
      }
    ]
  end

  defp items_for({:tool_result, %{name: name} = tr}, opts) do
    [
      %{
        type: :tool_result,
        created_by: :tool,
        response_id: response_id(opts),
        data: %{name: name, result: Map.get(tr, :result)}
      }
    ]
  end

  defp items_for({:done, %{content: content} = done}, opts) do
    [
      %{
        type: :message,
        status: :completed,
        created_by: :assistant,
        response_id: response_id(opts),
        data: %{role: :assistant, content: content, usage: Map.get(done, :usage, %{})}
      }
    ]
  end

  defp items_for({:error, reason}, opts) do
    [%{type: :error, response_id: response_id(opts), data: %{reason: inspect(reason)}}]
  end

  defp items_for(_event, _opts), do: []

  defp response_id(opts), do: Keyword.get(opts, :response_id)
end
