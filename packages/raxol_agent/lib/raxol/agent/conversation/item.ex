defmodule Raxol.Agent.Conversation.Item do
  @moduledoc """
  One immutable entry in a `Raxol.Agent.Conversation.Log`.

  Every event in a conversation -- assistant messages, tool calls and their
  results, reasoning, errors, compaction markers, terminal I/O, slash commands --
  is a typed `Item`. A single append-only log of these unifies what every surface
  (terminal, browser, phone, MCP) renders, and lets a reconnecting client
  reconcile by stable `id`.

  Items are append-only and never mutated. The store assigns `seq` (monotonic per
  conversation, 0-based) and derives a stable `id` of `"<conversation_id>:<seq>"`,
  so snapshot + live tail can be deduped by `id` with no coordination.

  ## Types

  | type | typical `data` | meaning |
  | --- | --- | --- |
  | `:message` | `%{role, content, usage}` | an assistant/user message |
  | `:tool_call` | `%{name, arguments, id}` | the model requested a tool |
  | `:tool_result` | `%{name, result}` | the result of a tool call |
  | `:reasoning` | `%{text}` | chain-of-thought / thinking |
  | `:error` | `%{reason}` | an error in the turn |
  | `:compaction` | `%{summary, last_seq}` | a summarization marker |
  | `:resource_event` | `%{kind, ...}` | session/sub-agent lifecycle |
  | `:slash_command` | `%{command, args}` | a user slash command |
  | `:terminal` | `%{stream, text}` | terminal input/output observation |

  The set is open; adapters round-trip arbitrary atoms.
  """

  @type type ::
          :message
          | :tool_call
          | :tool_result
          | :reasoning
          | :error
          | :compaction
          | :resource_event
          | :slash_command
          | :terminal
          | atom()

  @type status :: :completed | :in_progress | :action_required | atom() | nil

  @type t :: %__MODULE__{
          id: binary(),
          conversation_id: binary(),
          seq: non_neg_integer(),
          type: type(),
          status: status(),
          response_id: binary() | nil,
          created_at: DateTime.t(),
          created_by: term() | nil,
          data: map()
        }

  @enforce_keys [:id, :conversation_id, :seq, :type, :created_at]
  defstruct [
    :id,
    :conversation_id,
    :seq,
    :type,
    :status,
    :response_id,
    :created_at,
    :created_by,
    data: %{}
  ]

  @doc "The stable item id derived from a conversation id and sequence."
  @spec id(binary(), non_neg_integer()) :: binary()
  def id(conversation_id, seq), do: "#{conversation_id}:#{seq}"

  @doc """
  Construct an Item. Used by stores when materializing items on `append`;
  callers go through `Raxol.Agent.Conversation.Log.append/3` instead.

  Requires `:conversation_id`, `:seq`, and `:type`. `:id` defaults to
  `id/2`, `:status` to `:completed`, and `:created_at` to now.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    seq = Keyword.fetch!(opts, :seq)

    %__MODULE__{
      id: Keyword.get_lazy(opts, :id, fn -> id(conversation_id, seq) end),
      conversation_id: conversation_id,
      seq: seq,
      type: Keyword.fetch!(opts, :type),
      status: Keyword.get(opts, :status, :completed),
      response_id: Keyword.get(opts, :response_id),
      created_at: Keyword.get_lazy(opts, :created_at, &DateTime.utc_now/0),
      created_by: Keyword.get(opts, :created_by),
      data: Keyword.get(opts, :data, %{})
    }
  end
end
