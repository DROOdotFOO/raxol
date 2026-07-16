defmodule Raxol.AgentClientProtocol.Schema.SessionUpdate do
  @moduledoc """
  The `session/update` notification's `sessionUpdate`-discriminated union:
  real-time feedback the agent streams back to the client during a prompt
  turn (message/thought chunks, tool call lifecycle, the execution plan,
  available-command changes, mode changes, and the unstable config-option/
  session-info updates).

  Every variant's payload is a plain wire object carrying its own fields
  alongside a `"sessionUpdate"` discriminator key set to the variant's tag
  (snake_case, matching the tag atom exactly) -- there is no separate
  nesting level for the payload, mirroring how `McpServer` tags its `http`/
  `sse` variants with a sibling `"type"` key. Discriminator dispatch on
  decode uses explicit, whitelisted `"sessionUpdate"` string clauses (never
  `String.to_atom/1`); an unrecognized or missing discriminator is a
  `{:error, _}`, not a raise or a silent default.

  `from_json/1` is total: it never raises, always returning `{:ok, t}` or
  `{:error, reason}`. `to_json/1` delegates to each variant payload
  module's own `to_json/1` and adds the `"sessionUpdate"` tag; per package
  convention, tagged-tuple unions like this one (see also `ContentBlock`,
  `McpServer`, `ToolCallContent`) do not get a `Jason.Encoder` impl of
  their own -- only genuine structs do.

  ## Variants ported (all ten f1729 defines)

    * `:user_message_chunk` / `:agent_message_chunk` / `:agent_thought_chunk`
      -- `ContentChunk` payload
    * `:tool_call` -- `Raxol.AgentClientProtocol.Schema.ToolCall`
    * `:tool_call_update` -- `Raxol.AgentClientProtocol.Schema.ToolCallUpdate`
    * `:plan` -- `Raxol.AgentClientProtocol.Schema.Plan`
    * `:available_commands_update` -- `AvailableCommandsUpdate`
    * `:current_mode_update` -- `CurrentModeUpdate`
    * `:config_option_update` (unstable) --
      `Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate`
    * `:session_info_update` (unstable) --
      `Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate`

  ## Gaps versus the pinned v1.19.0 oracle schema (`priv/schema-oracle/v1/schema.json`)

  Ported strictly to what f1729 has; the oracle documents two things f1729
  lacks that are deliberately **not** invented here (no decode logic exists
  for either):

    * An eleventh variant, `usage_update`, carrying a `UsageUpdate` payload
      (`used`/`size`/optional `cost` token-budget fields). `UsageUpdate` is
      not ported anywhere in this package; `from_json/1` returns
      `{:error, {:invalid_session_update_variant, "usage_update"}}` for it,
      same as any other unrecognized discriminator.
    * `ContentChunk` in the oracle carries an additional optional
      `messageId` wire field (groups chunks belonging to the same
      streamed message); f1729's `ACP.ContentChunk` has no such field and
      this port's `ContentChunk` matches f1729, not the oracle.

  Also not ported here: the `ACP.SessionNotification` envelope
  (`{"sessionId", "update", "_meta"}`) that wraps a `SessionUpdate` for the
  wire, and the `AgentNotification` routing union that carries it as
  `"session/update"` -- both live in upstream's `client_types.ex` and
  belong to whichever coder ports that file (see the note on
  `Raxol.AgentClientProtocol.Schema.AgentTypes`'s moduledoc).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AvailableCommandsUpdate
  alias Raxol.AgentClientProtocol.Schema.ContentChunk
  alias Raxol.AgentClientProtocol.Schema.CurrentModeUpdate
  alias Raxol.AgentClientProtocol.Schema.Plan
  alias Raxol.AgentClientProtocol.Schema.ToolCall
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.Unstable.{ConfigOptionUpdate, SessionInfoUpdate}

  @type t ::
          {:user_message_chunk, ContentChunk.t()}
          | {:agent_message_chunk, ContentChunk.t()}
          | {:agent_thought_chunk, ContentChunk.t()}
          | {:tool_call, ToolCall.t()}
          | {:tool_call_update, ToolCallUpdate.t()}
          | {:plan, Plan.t()}
          | {:available_commands_update, AvailableCommandsUpdate.t()}
          | {:current_mode_update, CurrentModeUpdate.t()}
          | {:config_option_update, ConfigOptionUpdate.t()}
          | {:session_info_update, SessionInfoUpdate.t()}

  @spec to_json(t()) :: map()
  def to_json({:user_message_chunk, chunk}),
    do: tag(ContentChunk.to_json(chunk), "user_message_chunk")

  def to_json({:agent_message_chunk, chunk}),
    do: tag(ContentChunk.to_json(chunk), "agent_message_chunk")

  def to_json({:agent_thought_chunk, chunk}),
    do: tag(ContentChunk.to_json(chunk), "agent_thought_chunk")

  def to_json({:tool_call, tc}), do: tag(ToolCall.to_json(tc), "tool_call")
  def to_json({:tool_call_update, tcu}), do: tag(ToolCallUpdate.to_json(tcu), "tool_call_update")
  def to_json({:plan, plan}), do: tag(Plan.to_json(plan), "plan")

  def to_json({:available_commands_update, acu}),
    do: tag(AvailableCommandsUpdate.to_json(acu), "available_commands_update")

  def to_json({:current_mode_update, cmu}),
    do: tag(CurrentModeUpdate.to_json(cmu), "current_mode_update")

  def to_json({:config_option_update, cou}),
    do: tag(ConfigOptionUpdate.to_json(cou), "config_option_update")

  def to_json({:session_info_update, siu}),
    do: tag(SessionInfoUpdate.to_json(siu), "session_info_update")

  defp tag(json, session_update), do: Map.put(json, "sessionUpdate", session_update)

  @doc """
  Total: never raises. Dispatches on the `"sessionUpdate"` discriminator via
  explicit whitelisted string clauses (no `String.to_atom/1`); an
  unrecognized discriminator value, a map with none at all, or a non-map
  argument all return a descriptive `{:error, _}`. `"sessionUpdate"` is
  stripped before delegating to the variant payload's own `from_json/1` so
  it never leaks into that payload's `_meta`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"sessionUpdate" => "user_message_chunk"} = map),
    do: decode(:user_message_chunk, &ContentChunk.from_json/1, map)

  def from_json(%{"sessionUpdate" => "agent_message_chunk"} = map),
    do: decode(:agent_message_chunk, &ContentChunk.from_json/1, map)

  def from_json(%{"sessionUpdate" => "agent_thought_chunk"} = map),
    do: decode(:agent_thought_chunk, &ContentChunk.from_json/1, map)

  def from_json(%{"sessionUpdate" => "tool_call"} = map),
    do: decode(:tool_call, &ToolCall.from_json/1, map)

  def from_json(%{"sessionUpdate" => "tool_call_update"} = map),
    do: decode(:tool_call_update, &ToolCallUpdate.from_json/1, map)

  def from_json(%{"sessionUpdate" => "plan"} = map),
    do: decode(:plan, &Plan.from_json/1, map)

  def from_json(%{"sessionUpdate" => "available_commands_update"} = map),
    do: decode(:available_commands_update, &AvailableCommandsUpdate.from_json/1, map)

  def from_json(%{"sessionUpdate" => "current_mode_update"} = map),
    do: decode(:current_mode_update, &CurrentModeUpdate.from_json/1, map)

  def from_json(%{"sessionUpdate" => "config_option_update"} = map),
    do: decode(:config_option_update, &ConfigOptionUpdate.from_json/1, map)

  def from_json(%{"sessionUpdate" => "session_info_update"} = map),
    do: decode(:session_info_update, &SessionInfoUpdate.from_json/1, map)

  def from_json(%{"sessionUpdate" => other}),
    do: {:error, {:invalid_session_update_variant, other}}

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "sessionUpdate"}}
  def from_json(other), do: {:error, {:invalid_session_update, other}}

  defp decode(tag, decoder, map) do
    case decoder.(Map.delete(map, "sessionUpdate")) do
      {:ok, value} -> {:ok, {tag, value}}
      {:error, _reason} = error -> error
    end
  end
end

# -- ContentChunk --------------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.ContentChunk do
  @moduledoc """
  A single streamed content block, used as the payload for the
  `SessionUpdate` `user_message_chunk`/`agent_message_chunk`/
  `agent_thought_chunk` variants.

  Note: the pinned v1.19.0 oracle schema documents an additional optional
  `messageId` wire field on this type (groups chunks belonging to the same
  streamed message) that f1729's `ACP.ContentChunk` does not have; not
  ported here per `SessionUpdate`'s f1729-first scope (see its moduledoc).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{content: ContentBlock.t(), _meta: map()}

  @enforce_keys [:content]
  defstruct [:content, _meta: %{}]

  @known_wire_keys ~w(content)

  @spec new(ContentBlock.t()) :: t()
  def new(content), do: %__MODULE__{content: content}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"content" => ContentBlock.to_json(c.content)}
    |> WireFields.emit_meta(c._meta)
  end

  @doc "Total: never raises. A missing/unparseable `content` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"content" => content_map} = map) do
    with {:ok, content} <- ContentBlock.from_json(content_map) do
      {:ok, %__MODULE__{content: content, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "content"}}
  def from_json(other), do: {:error, {:invalid_content_chunk, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ContentChunk do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ContentChunk.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# -- CurrentModeUpdate ----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.CurrentModeUpdate do
  @moduledoc """
  Payload for the `SessionUpdate` `current_mode_update` variant: the
  session's active mode has changed.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{current_mode_id: String.t(), _meta: map()}

  @enforce_keys [:current_mode_id]
  defstruct [:current_mode_id, _meta: %{}]

  @known_wire_keys ~w(currentModeId)

  @spec new(String.t()) :: t()
  def new(current_mode_id), do: %__MODULE__{current_mode_id: current_mode_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"currentModeId" => c.current_mode_id}
    |> WireFields.emit_meta(c._meta)
  end

  @doc "Total: never raises. A missing/non-string `currentModeId` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_mode_id} <- WireFields.require(map, "currentModeId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         current_mode_id: current_mode_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_current_mode_update, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.CurrentModeUpdate do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.CurrentModeUpdate.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# -- AvailableCommandsUpdate / AvailableCommand / AvailableCommandInput --------

defmodule Raxol.AgentClientProtocol.Schema.AvailableCommandsUpdate do
  @moduledoc """
  Payload for the `SessionUpdate` `available_commands_update` variant: the
  set of commands the agent can execute has changed. `available_commands`
  is decode-lenient, matching the oracle schema's
  `x-deserialize-default-on-error` + `x-deserialize-skip-invalid-items`: a
  missing/wrong-typed list defaults to `[]`, and items that individually
  fail to decode are skipped rather than aborting the whole update.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AvailableCommand
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{available_commands: [AvailableCommand.t()], _meta: map()}

  @enforce_keys [:available_commands]
  defstruct [:available_commands, _meta: %{}]

  @known_wire_keys ~w(availableCommands)

  @spec new([AvailableCommand.t()]) :: t()
  def new(commands) when is_list(commands), do: %__MODULE__{available_commands: commands}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = a) do
    %{"availableCommands" => Enum.map(a.available_commands, &AvailableCommand.to_json/1)}
    |> WireFields.emit_meta(a._meta)
  end

  @doc "Total: never raises, even for a non-map argument -- matches `Plan.from_json/1`'s leniency."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       available_commands:
         WireFields.list_lenient(
           Map.get(map, "availableCommands"),
           &AvailableCommand.from_json/1,
           []
         ),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(_other), do: {:ok, %__MODULE__{available_commands: []}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AvailableCommandsUpdate do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.AvailableCommandsUpdate.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AvailableCommand do
  @moduledoc """
  A single command the agent can execute, as advertised via
  `AvailableCommandsUpdate`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AvailableCommandInput
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          input: AvailableCommandInput.t() | nil,
          _meta: map()
        }

  @enforce_keys [:name, :description]
  defstruct [:name, :description, input: nil, _meta: %{}]

  @known_wire_keys ~w(name description input)

  @spec new(String.t(), String.t()) :: t()
  def new(name, description), do: %__MODULE__{name: name, description: description}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"name" => c.name, "description" => c.description}
    |> WireFields.put("input", encode_input(c.input))
    |> WireFields.emit_meta(c._meta)
  end

  defp encode_input(nil), do: nil
  defp encode_input(input), do: AvailableCommandInput.to_json(input)

  @doc "Total: never raises. Missing/non-string `name`/`description` is the only failure mode (required fields)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- WireFields.require(map, "name", &is_binary/1),
         {:ok, description} <- WireFields.require(map, "description", &is_binary/1) do
      {:ok,
       %__MODULE__{
         name: name,
         description: description,
         input: WireFields.optional_nested(map, "input", &AvailableCommandInput.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_available_command, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AvailableCommand do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.AvailableCommand.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AvailableCommandInput do
  @moduledoc """
  Input specification for an `AvailableCommand`: an untagged union with a
  single documented variant, `unstructured` (free text typed after the
  command name). Per package convention, tagged-tuple unions don't get a
  `Jason.Encoder` impl of their own.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.UnstructuredCommandInput

  @type t :: {:unstructured, UnstructuredCommandInput.t()}

  @spec to_json(t()) :: map()
  def to_json({:unstructured, input}), do: UnstructuredCommandInput.to_json(input)

  @doc """
  Total: never raises. A map carrying `"hint"` delegates to
  `UnstructuredCommandInput.from_json/1`; any other map still decodes as
  `:unstructured` with an empty hint (matching upstream's fallback), so
  only a non-map argument fails.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"hint" => _} = map) do
    with {:ok, input} <- UnstructuredCommandInput.from_json(map) do
      {:ok, {:unstructured, input}}
    end
  end

  def from_json(map) when is_map(map) do
    {:ok, {:unstructured, UnstructuredCommandInput.new(Map.get(map, "hint", ""))}}
  end

  def from_json(other), do: {:error, {:invalid_available_command_input, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.UnstructuredCommandInput do
  @moduledoc """
  Unstructured command input: raw free text typed after the command name,
  as a `hint` for what's expected.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{hint: String.t(), _meta: map()}

  @enforce_keys [:hint]
  defstruct [:hint, _meta: %{}]

  @known_wire_keys ~w(hint)

  @spec new(String.t()) :: t()
  def new(hint), do: %__MODULE__{hint: hint}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = u) do
    %{"hint" => u.hint}
    |> WireFields.emit_meta(u._meta)
  end

  @doc "Total: never raises. A missing/non-string `hint` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, hint} <- WireFields.require(map, "hint", &is_binary/1) do
      {:ok, %__MODULE__{hint: hint, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_unstructured_command_input, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.UnstructuredCommandInput do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.UnstructuredCommandInput.to_json()
    |> Jason.Encoder.encode(opts)
  end
end
