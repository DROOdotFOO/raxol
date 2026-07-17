defmodule Raxol.AgentClientProtocol.Schema.ToolKind do
  @moduledoc """
  Categories of tools that can be invoked. An open enum: the ACP schema
  documents `"other"` as its explicit default, so an unrecognized wire
  value decodes to `:other` rather than failing (no `String.to_atom/1` is
  ever used -- every value is an explicit, whitelisted clause).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t ::
          :read
          | :edit
          | :delete
          | :move
          | :search
          | :execute
          | :think
          | :fetch
          | :switch_mode
          | :other

  @spec encode(t()) :: String.t()
  def encode(:read), do: "read"
  def encode(:edit), do: "edit"
  def encode(:delete), do: "delete"
  def encode(:move), do: "move"
  def encode(:search), do: "search"
  def encode(:execute), do: "execute"
  def encode(:think), do: "think"
  def encode(:fetch), do: "fetch"
  def encode(:switch_mode), do: "switch_mode"
  def encode(:other), do: "other"

  @doc "Total and infallible: any unrecognized wire value decodes to the documented default, `:other`."
  @spec decode(term()) :: t()
  def decode("read"), do: :read
  def decode("edit"), do: :edit
  def decode("delete"), do: :delete
  def decode("move"), do: :move
  def decode("search"), do: :search
  def decode("execute"), do: :execute
  def decode("think"), do: :think
  def decode("fetch"), do: :fetch
  def decode("switch_mode"), do: :switch_mode
  def decode(_other), do: :other

  @spec default() :: t()
  def default, do: :other

  @spec default?(t()) :: boolean()
  def default?(:other), do: true
  def default?(_other), do: false
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallStatus do
  @moduledoc """
  Execution status of a tool call. Every place this enum is used in the ACP
  schema (`ToolCall.status`, `ToolCallUpdateFields.status`) carries
  `x-deserialize-default-on-error: true`, so -- like `ToolKind` -- decode is
  total and infallible: an unrecognized wire value falls back to the
  documented default, `:pending`, rather than failing the enclosing object.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: :pending | :in_progress | :completed | :failed

  @spec encode(t()) :: String.t()
  def encode(:pending), do: "pending"
  def encode(:in_progress), do: "in_progress"
  def encode(:completed), do: "completed"
  def encode(:failed), do: "failed"

  @doc "Total and infallible: any unrecognized wire value decodes to the documented default, `:pending`."
  @spec decode(term()) :: t()
  def decode("pending"), do: :pending
  def decode("in_progress"), do: :in_progress
  def decode("completed"), do: :completed
  def decode("failed"), do: :failed
  def decode(_other), do: :pending

  @spec default() :: t()
  def default, do: :pending

  @spec default?(t()) :: boolean()
  def default?(:pending), do: true
  def default?(_other), do: false
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallLocation do
  @moduledoc """
  A file location being accessed or modified by a tool.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          path: String.t(),
          line: non_neg_integer() | nil,
          _meta: map()
        }

  @enforce_keys [:path]
  defstruct [:path, line: nil, _meta: %{}]

  @known_wire_keys ~w(path line)

  @spec new(String.t()) :: t()
  def new(path) when is_binary(path), do: %__MODULE__{path: path}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = loc) do
    %{"path" => loc.path}
    |> WireFields.put("line", loc.line)
    |> WireFields.emit_meta(loc._meta)
  end

  @doc "Total: never raises. Missing/non-string `path` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, path} <- WireFields.require(map, "path", &is_binary/1) do
      {:ok,
       %__MODULE__{
         path: path,
         line: WireFields.optional(map, "line", &(is_integer(&1) and &1 >= 0)),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_tool_call_location, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ToolCallLocation do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ToolCallLocation.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Diff do
  @moduledoc """
  A diff representing file modifications.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.

  ## Fixed defect

  Upstream's `to_json/1` unconditionally emitted `"oldText" => nil` when
  `old_text` was absent (a new-file diff), instead of omitting the key. The
  ACP schema types `oldText` as optional (`string | null`); this port omits
  it like every other absent-optional field, rather than emitting an
  explicit wire `null`.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          path: String.t(),
          old_text: String.t() | nil,
          new_text: String.t(),
          _meta: map()
        }

  @enforce_keys [:path, :new_text]
  defstruct [:path, :new_text, old_text: nil, _meta: %{}]

  @known_wire_keys ~w(path oldText newText)

  @spec new(String.t(), String.t()) :: t()
  def new(path, new_text) when is_binary(path) and is_binary(new_text) do
    %__MODULE__{path: path, new_text: new_text}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = diff) do
    %{"path" => diff.path, "newText" => diff.new_text}
    |> WireFields.put("oldText", diff.old_text)
    |> WireFields.emit_meta(diff._meta)
  end

  @doc "Total: never raises. Missing/non-string `path` or `newText` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, path} <- WireFields.require(map, "path", &is_binary/1),
         {:ok, new_text} <- WireFields.require(map, "newText", &is_binary/1) do
      {:ok,
       %__MODULE__{
         path: path,
         new_text: new_text,
         old_text: WireFields.optional(map, "oldText", &is_binary/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_diff, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Diff do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Schema.Diff.to_json() |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallTerminal do
  @moduledoc """
  Embeds a terminal created with `terminal/create`, by its id.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          terminal_id: String.t(),
          _meta: map()
        }

  @enforce_keys [:terminal_id]
  defstruct [:terminal_id, _meta: %{}]

  @known_wire_keys ~w(terminalId)

  @spec new(String.t()) :: t()
  def new(terminal_id) when is_binary(terminal_id), do: %__MODULE__{terminal_id: terminal_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = t) do
    %{"terminalId" => t.terminal_id}
    |> WireFields.emit_meta(t._meta)
  end

  @doc "Total: never raises. Missing/non-string `terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_tool_call_terminal, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ToolCallTerminal do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ToolCallTerminal.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper do
  @moduledoc """
  Standard content block wrapper for tool call content (the `"content"`
  variant of `ToolCallContent`; named `Content` in the official schema, but
  kept as `ToolCallContentWrapper` here to avoid colliding with
  `Schema.ContentBlock`, the tagged-union content block type).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ContentBlock
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          content: ContentBlock.t(),
          _meta: map()
        }

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
    with {:ok, cb} <- ContentBlock.from_json(content_map) do
      {:ok, %__MODULE__{content: cb, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "content"}}
  def from_json(other), do: {:error, {:invalid_tool_call_content_wrapper, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallContent do
  @moduledoc """
  Content produced by a tool call: a tagged union discriminated by a
  `"type"` wire key (`content` | `diff` | `terminal`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Diff
  alias Raxol.AgentClientProtocol.Schema.ToolCallContentWrapper
  alias Raxol.AgentClientProtocol.Schema.ToolCallTerminal

  @type t ::
          {:content, ToolCallContentWrapper.t()}
          | {:diff, Diff.t()}
          | {:terminal, ToolCallTerminal.t()}

  @spec content(ToolCallContentWrapper.t()) :: t()
  def content(wrapper), do: {:content, wrapper}

  @spec diff(Diff.t()) :: t()
  def diff(diff), do: {:diff, diff}

  @spec terminal(ToolCallTerminal.t()) :: t()
  def terminal(terminal), do: {:terminal, terminal}

  @spec to_json(t()) :: map()
  def to_json({:content, c}), do: Map.put(ToolCallContentWrapper.to_json(c), "type", "content")
  def to_json({:diff, d}), do: Map.put(Diff.to_json(d), "type", "diff")
  def to_json({:terminal, t}), do: Map.put(ToolCallTerminal.to_json(t), "type", "terminal")

  @doc """
  Total: never raises. An unrecognized/missing `"type"`, or a variant body
  that fails to decode, returns `{:error, _}`. Callers decoding a
  `ToolCallContent` list (`ToolCall.content`, `ToolCallUpdateFields.content`)
  skip items that error rather than failing the whole list.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "content"} = map) do
    with {:ok, c} <- ToolCallContentWrapper.from_json(Map.delete(map, "type")) do
      {:ok, {:content, c}}
    end
  end

  def from_json(%{"type" => "diff"} = map) do
    with {:ok, d} <- Diff.from_json(Map.delete(map, "type")), do: {:ok, {:diff, d}}
  end

  def from_json(%{"type" => "terminal"} = map) do
    with {:ok, t} <- ToolCallTerminal.from_json(Map.delete(map, "type")) do
      {:ok, {:terminal, t}}
    end
  end

  def from_json(%{"type" => other_type}) do
    {:error, {:unknown_tool_call_content_type, other_type}}
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "type"}}
  def from_json(other), do: {:error, {:invalid_tool_call_content, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields do
  @moduledoc """
  Optional fields that can be updated in a tool call. Every field is
  optional and decode-lenient per the ACP schema
  (`x-deserialize-default-on-error`, plus `x-deserialize-skip-invalid-items`
  on the two list fields) -- decode of this struct never fails for a map
  input. Flattened directly into `ToolCallUpdate`'s wire object (no nested
  `"_meta"` of its own; unrecognized fields fold into the parent's `_meta`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ToolCallContent
  alias Raxol.AgentClientProtocol.Schema.ToolCallLocation
  alias Raxol.AgentClientProtocol.Schema.ToolCallStatus
  alias Raxol.AgentClientProtocol.Schema.ToolKind
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          kind: ToolKind.t() | nil,
          status: ToolCallStatus.t() | nil,
          title: String.t() | nil,
          content: [ToolCallContent.t()] | nil,
          locations: [ToolCallLocation.t()] | nil,
          raw_input: term() | nil,
          raw_output: term() | nil
        }

  defstruct kind: nil,
            status: nil,
            title: nil,
            content: nil,
            locations: nil,
            raw_input: nil,
            raw_output: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = f) do
    %{}
    |> WireFields.put("kind", encode_kind(f.kind))
    |> WireFields.put("status", encode_status(f.status))
    |> WireFields.put("title", f.title)
    |> WireFields.put("content", encode_content(f.content))
    |> WireFields.put("locations", encode_locations(f.locations))
    |> WireFields.put("rawInput", f.raw_input)
    |> WireFields.put("rawOutput", f.raw_output)
  end

  defp encode_kind(nil), do: nil
  defp encode_kind(kind), do: ToolKind.encode(kind)

  defp encode_status(nil), do: nil
  defp encode_status(status), do: ToolCallStatus.encode(status)

  defp encode_content(nil), do: nil
  defp encode_content(content), do: Enum.map(content, &ToolCallContent.to_json/1)

  defp encode_locations(nil), do: nil
  defp encode_locations(locations), do: Enum.map(locations, &ToolCallLocation.to_json/1)

  @doc "Total and infallible for map input: every field independently defaults to absent on error."
  @spec from_json(term()) :: {:ok, t()} | {:error, {:invalid_tool_call_update_fields, term()}}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       kind: decode_kind(Map.get(map, "kind")),
       status: decode_status(Map.get(map, "status")),
       title: WireFields.optional(map, "title", &is_binary/1),
       content:
         WireFields.list_lenient(Map.get(map, "content"), &ToolCallContent.from_json/1, nil),
       locations:
         WireFields.list_lenient(Map.get(map, "locations"), &ToolCallLocation.from_json/1, nil),
       raw_input: Map.get(map, "rawInput"),
       raw_output: Map.get(map, "rawOutput")
     }}
  end

  def from_json(other), do: {:error, {:invalid_tool_call_update_fields, other}}

  defp decode_kind(nil), do: nil
  defp decode_kind(value), do: ToolKind.decode(value)

  defp decode_status(nil), do: nil
  defp decode_status(value), do: ToolCallStatus.decode(value)
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCallUpdate do
  @moduledoc """
  An update to an existing tool call. `ToolCallUpdateFields` is flattened
  into the same wire object as `toolCallId` and `_meta` (a "serde flatten"),
  not nested under its own key.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          fields: ToolCallUpdateFields.t(),
          _meta: map()
        }

  @enforce_keys [:tool_call_id, :fields]
  defstruct [:tool_call_id, :fields, _meta: %{}]

  @known_wire_keys ~w(toolCallId kind status title content locations rawInput rawOutput)

  @spec new(String.t(), ToolCallUpdateFields.t()) :: t()
  def new(tool_call_id, fields) when is_binary(tool_call_id) do
    %__MODULE__{tool_call_id: tool_call_id, fields: fields}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = u) do
    u.fields
    |> ToolCallUpdateFields.to_json()
    |> Map.put("toolCallId", u.tool_call_id)
    |> WireFields.emit_meta(u._meta)
  end

  @doc "Total: never raises. Missing/non-string `toolCallId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, tool_call_id} <- WireFields.require(map, "toolCallId", &is_binary/1),
         {:ok, fields} <- ToolCallUpdateFields.from_json(map) do
      {:ok,
       %__MODULE__{
         tool_call_id: tool_call_id,
         fields: fields,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_tool_call_update, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ToolCallUpdate do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ToolCallUpdate.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ToolCall do
  @moduledoc """
  Represents a tool call that the language model has requested. Every other
  type ported from `tool_call.ex` (`ToolKind`, `ToolCallStatus`,
  `ToolCallLocation`, `Diff`, `ToolCallTerminal`, `ToolCallContentWrapper`,
  `ToolCallContent`, `ToolCallUpdateFields`, `ToolCallUpdate`) is a separate,
  bare `Schema.*` module, not nested under this one.

  `kind` and `status` default (`:other` / `:pending`) rather than erroring
  on an unrecognized wire value; `content` and `locations` default to `[]`
  and skip items that individually fail to decode.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ToolCallContent
  alias Raxol.AgentClientProtocol.Schema.ToolCallLocation
  alias Raxol.AgentClientProtocol.Schema.ToolCallStatus
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  alias Raxol.AgentClientProtocol.Schema.ToolKind
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          title: String.t(),
          kind: ToolKind.t(),
          status: ToolCallStatus.t(),
          content: [ToolCallContent.t()],
          locations: [ToolCallLocation.t()],
          raw_input: term() | nil,
          raw_output: term() | nil,
          _meta: map()
        }

  @enforce_keys [:tool_call_id, :title]
  defstruct [
    :tool_call_id,
    :title,
    kind: :other,
    status: :pending,
    content: [],
    locations: [],
    raw_input: nil,
    raw_output: nil,
    _meta: %{}
  ]

  @known_wire_keys ~w(toolCallId title kind status content locations rawInput rawOutput)

  @spec new(String.t(), String.t()) :: t()
  def new(tool_call_id, title) when is_binary(tool_call_id) and is_binary(title) do
    %__MODULE__{tool_call_id: tool_call_id, title: title}
  end

  @doc "Apply a partial update, overwriting only the fields present (non-nil) in `fields`."
  @spec update(t(), ToolCallUpdateFields.t()) :: t()
  def update(%__MODULE__{} = tc, %ToolCallUpdateFields{} = fields) do
    tc
    |> update_field(:title, fields.title)
    |> update_field(:kind, fields.kind)
    |> update_field(:status, fields.status)
    |> update_field(:content, fields.content)
    |> update_field(:locations, fields.locations)
    |> update_field(:raw_input, fields.raw_input)
    |> update_field(:raw_output, fields.raw_output)
  end

  defp update_field(tc, _key, nil), do: tc
  defp update_field(tc, key, value), do: Map.put(tc, key, value)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = tc) do
    %{"toolCallId" => tc.tool_call_id, "title" => tc.title}
    |> put_unless_default("kind", tc.kind, &ToolKind.default?/1, &ToolKind.encode/1)
    |> put_unless_default(
      "status",
      tc.status,
      &ToolCallStatus.default?/1,
      &ToolCallStatus.encode/1
    )
    |> put_unless_empty("content", tc.content, &ToolCallContent.to_json/1)
    |> put_unless_empty("locations", tc.locations, &ToolCallLocation.to_json/1)
    |> WireFields.put("rawInput", tc.raw_input)
    |> WireFields.put("rawOutput", tc.raw_output)
    |> WireFields.emit_meta(tc._meta)
  end

  defp put_unless_default(json, key, value, default?, encode) do
    if default?.(value), do: json, else: Map.put(json, key, encode.(value))
  end

  defp put_unless_empty(json, _key, [], _encode), do: json
  defp put_unless_empty(json, key, list, encode), do: Map.put(json, key, Enum.map(list, encode))

  @doc """
  Total: never raises. Missing/non-string `toolCallId` or `title` is the
  only failure mode (the two required fields); everything else defaults
  leniently per the schema.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, tool_call_id} <- WireFields.require(map, "toolCallId", &is_binary/1),
         {:ok, title} <- WireFields.require(map, "title", &is_binary/1) do
      {:ok,
       %__MODULE__{
         tool_call_id: tool_call_id,
         title: title,
         kind: decode_kind(Map.get(map, "kind")),
         status: decode_status(Map.get(map, "status")),
         content:
           WireFields.list_lenient(Map.get(map, "content"), &ToolCallContent.from_json/1, []),
         locations:
           WireFields.list_lenient(Map.get(map, "locations"), &ToolCallLocation.from_json/1, []),
         raw_input: Map.get(map, "rawInput"),
         raw_output: Map.get(map, "rawOutput"),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_tool_call, other}}

  defp decode_kind(nil), do: ToolKind.default()
  defp decode_kind(value), do: ToolKind.decode(value)

  defp decode_status(nil), do: ToolCallStatus.default()
  defp decode_status(value), do: ToolCallStatus.decode(value)

  @doc "Project this `ToolCall` down to a `ToolCallUpdate` carrying its full current state."
  @spec to_update(t()) :: ToolCallUpdate.t()
  def to_update(%__MODULE__{} = tc) do
    %ToolCallUpdate{
      tool_call_id: tc.tool_call_id,
      fields: %ToolCallUpdateFields{
        kind: tc.kind,
        status: tc.status,
        title: tc.title,
        content: tc.content,
        locations: tc.locations,
        raw_input: tc.raw_input,
        raw_output: tc.raw_output
      },
      _meta: tc._meta
    }
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ToolCall do
  def encode(val, opts) do
    val |> Raxol.AgentClientProtocol.Schema.ToolCall.to_json() |> Jason.Encoder.encode(opts)
  end
end
