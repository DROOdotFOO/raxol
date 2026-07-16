# Client-side request/response types for ACP: filesystem access
# (`fs/read_text_file`, `fs/write_text_file`), terminal control
# (`terminal/create`, `terminal/output`, `terminal/release`,
# `terminal/wait_for_exit`, `terminal/kill`), and permission requests
# (`session/request_permission`, including the `outcome` discriminator and
# the permission option kinds).
#
# ## Fixed defects vs. the schema-oracle (pinned ACP `schema-v1.19.0`,
# `priv/schema-oracle/v1/schema.json`)
#
# The upstream `f1729/agent_client_protocol` shapes for this slice of the
# wire protocol drifted from the pinned schema in several places. This port
# conforms to the schema-oracle, not to upstream's shape:
#
#   * `TerminalExitStatus` is missing a `signal` field upstream (only
#     `exitCode` was modeled). Added here, both nullable.
#   * `WaitForTerminalExitResponse` wraps the exit info in a nested
#     `exitStatus: TerminalExitStatus` object upstream. The oracle has
#     `exitCode`/`signal` flattened directly on the response (no nesting) --
#     fixed here.
#   * `TerminalOutputResponse` is missing the required `truncated: boolean`
#     field upstream. Added here.
#   * `CreateTerminalRequest` carries a `timeoutMs` field upstream that does
#     not exist in the oracle schema at all, and is missing the oracle's
#     `outputByteLimit` (nullable, `uint64`) field. `timeoutMs` was dropped;
#     `output_byte_limit` was added.
#   * `KillTerminalCommandRequest`/`KillTerminalCommandResponse` are named
#     `KillTerminalRequest`/`KillTerminalResponse` in the oracle (method
#     `terminal/kill`, not `terminal/kill_command`). Renamed here to match.
#
# These are wire-format corrections, not stylistic choices -- flagged
# explicitly per the port's own defect-fix mandate rather than resolved
# silently.
#
# `RequestPermissionRequest.tool_call` is a
# `Raxol.AgentClientProtocol.Schema.ToolCallUpdate` (ported separately,
# landed flat in `tool_call.ex`). `CreateTerminalRequest.env` is a list of
# `Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable` (ported
# separately, landed *nested* under `AgentTypes` in `agent_types.ex` --
# note the naming inconsistency across this fan-out: `content.ex`/
# `plan.ex`/`tool_call.ex` use flat `Schema.<Type>` names matching the
# official ACP schema's own top-level type names 1:1, while `ext.ex` and
# `agent_types.ex` wrap their types under a file-named namespace
# (`Schema.Ext.*`, `Schema.AgentTypes.*`). This file follows the latter
# convention (`Schema.ClientTypes.*`) per its own assignment text, which
# named the module `Schema.ClientTypes` explicitly and matches the
# `agent_types.ex` precedent most closely (both are ACP's own "bag of
# client/agent-side request-response types" files). Flagged, not silently
# resolved -- reconcile at integration time if the two conventions need to
# converge.

# --- fs/read_text_file, fs/write_text_file ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest do
  @moduledoc """
  Request to write content to a text file (`fs/write_text_file`). Only sent
  if the client declared the `fs.writeTextFile` capability.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          content: String.t(),
          _meta: map()
        }

  @enforce_keys [:session_id, :path, :content]
  defstruct [:session_id, :path, :content, _meta: %{}]

  @known_wire_keys ~w(sessionId path content)

  @spec new(String.t(), String.t(), String.t()) :: t()
  def new(session_id, path, content) when is_binary(session_id) and is_binary(path) do
    %__MODULE__{session_id: session_id, path: path, content: content}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "path" => r.path, "content" => r.content}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`, `path`, or `content` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, path} <- WireFields.require(map, "path", &is_binary/1),
         {:ok, content} <- WireFields.require(map, "content", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         path: path,
         content: content,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_write_text_file_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse do
  @moduledoc """
  Response to `fs/write_text_file`. Carries no data of its own.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: WireFields.emit_meta(%{}, r._meta)

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map),
    do: {:ok, %__MODULE__{_meta: WireFields.fold_meta(map, [])}}

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WriteTextFileResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest do
  @moduledoc """
  Request to read content from a text file (`fs/read_text_file`). Only sent
  if the client declared the `fs.readTextFile` capability.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          path: String.t(),
          line: non_neg_integer() | nil,
          limit: non_neg_integer() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :path]
  defstruct [:session_id, :path, line: nil, limit: nil, _meta: %{}]

  @known_wire_keys ~w(sessionId path line limit)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, path) when is_binary(session_id) and is_binary(path) do
    %__MODULE__{session_id: session_id, path: path}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "path" => r.path}
    |> WireFields.put("line", r.line)
    |> WireFields.put("limit", r.limit)
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`path` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, path} <- WireFields.require(map, "path", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         path: path,
         line: WireFields.optional(map, "line", &is_integer/1),
         limit: WireFields.optional(map, "limit", &is_integer/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_read_text_file_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse do
  @moduledoc """
  Response containing the contents of a text file.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{content: String.t(), _meta: map()}

  @enforce_keys [:content]
  defstruct [:content, _meta: %{}]

  @known_wire_keys ~w(content)

  @spec new(String.t()) :: t()
  def new(content) when is_binary(content), do: %__MODULE__{content: content}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"content" => r.content} |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `content` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, content} <- WireFields.require(map, "content", &is_binary/1) do
      {:ok, %__MODULE__{content: content, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_read_text_file_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReadTextFileResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# --- session/request_permission ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOptionKind do
  @moduledoc """
  Hint about the nature of a `PermissionOption`, so clients can choose
  appropriate icons/UI treatment.

  Unlike `ToolKind`/`ToolCallStatus` elsewhere in this schema layer, decode
  here is deliberately **not** infallible-with-a-default: the ACP schema
  documents no default for this enum (no `x-deserialize-default-on-error`),
  and silently coercing an unrecognized permission-option kind to some
  arbitrary member (e.g. `:reject_once`) would misrepresent a
  safety-relevant value rather than gracefully degrade one. An unrecognized
  wire value is a decode error instead.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: :allow_once | :allow_always | :reject_once | :reject_always

  @spec to_json(t()) :: String.t()
  def to_json(:allow_once), do: "allow_once"
  def to_json(:allow_always), do: "allow_always"
  def to_json(:reject_once), do: "reject_once"
  def to_json(:reject_always), do: "reject_always"

  @doc "Total: never raises. An unrecognized wire value is an error, not a silently-coerced default."
  @spec from_json(term()) :: {:ok, t()} | {:error, {:invalid_permission_option_kind, term()}}
  def from_json("allow_once"), do: {:ok, :allow_once}
  def from_json("allow_always"), do: {:ok, :allow_always}
  def from_json("reject_once"), do: {:ok, :reject_once}
  def from_json("reject_always"), do: {:ok, :reject_always}
  def from_json(other), do: {:error, {:invalid_permission_option_kind, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption do
  @moduledoc """
  An option presented to the user when the agent requests permission for a
  tool call.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOptionKind
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          option_id: String.t(),
          name: String.t(),
          kind: PermissionOptionKind.t(),
          _meta: map()
        }

  @enforce_keys [:option_id, :name, :kind]
  defstruct [:option_id, :name, :kind, _meta: %{}]

  @known_wire_keys ~w(optionId name kind)

  @spec new(String.t(), String.t(), PermissionOptionKind.t()) :: t()
  def new(option_id, name, kind) when is_binary(option_id) and is_binary(name) do
    %__MODULE__{option_id: option_id, name: name, kind: kind}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = p) do
    %{"optionId" => p.option_id, "name" => p.name, "kind" => PermissionOptionKind.to_json(p.kind)}
    |> WireFields.emit_meta(p._meta)
  end

  @doc "Total: never raises. Missing/invalid `optionId`, `name`, or `kind` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, option_id} <- WireFields.require(map, "optionId", &is_binary/1),
         {:ok, name} <- WireFields.require(map, "name", &is_binary/1),
         {:ok, kind_json} <- WireFields.require(map, "kind", &is_binary/1),
         {:ok, kind} <- PermissionOptionKind.from_json(kind_json) do
      {:ok,
       %__MODULE__{
         option_id: option_id,
         name: name,
         kind: kind,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_permission_option, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome do
  @moduledoc """
  A `RequestPermissionOutcome` variant: the user selected one of the
  offered options.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{option_id: String.t(), _meta: map()}

  @enforce_keys [:option_id]
  defstruct [:option_id, _meta: %{}]

  @known_wire_keys ~w(optionId outcome)

  @spec new(String.t()) :: t()
  def new(option_id) when is_binary(option_id), do: %__MODULE__{option_id: option_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{"optionId" => s.option_id} |> WireFields.emit_meta(s._meta)
  end

  @doc "Total: never raises. Missing/non-string `optionId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, option_id} <- WireFields.require(map, "optionId", &is_binary/1) do
      {:ok, %__MODULE__{option_id: option_id, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_selected_permission_outcome, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionOutcome do
  @moduledoc """
  The outcome of a permission request: either the prompt turn was cancelled
  before the user responded, or the user selected one of the offered
  options. Tagged by the `outcome` discriminator field on the wire (not a
  struct in its own right -- see `SelectedPermissionOutcome` for the
  `_meta`-carrying payload of the `:selected` variant).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.SelectedPermissionOutcome

  @type t :: :cancelled | {:selected, SelectedPermissionOutcome.t()}

  @spec to_json(t()) :: map()
  def to_json(:cancelled), do: %{"outcome" => "cancelled"}

  def to_json({:selected, %SelectedPermissionOutcome{} = selected}) do
    selected |> SelectedPermissionOutcome.to_json() |> Map.put("outcome", "selected")
  end

  @doc "Total: never raises. Missing/unrecognized `outcome` discriminator is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"outcome" => "cancelled"}), do: {:ok, :cancelled}

  def from_json(%{"outcome" => "selected"} = map) do
    with {:ok, selected} <- SelectedPermissionOutcome.from_json(map) do
      {:ok, {:selected, selected}}
    end
  end

  def from_json(%{"outcome" => other}), do: {:error, {:invalid_outcome, other}}
  def from_json(map) when is_map(map), do: {:error, {:missing_field, "outcome"}}
  def from_json(other), do: {:error, {:invalid_request_permission_outcome, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse do
  @moduledoc """
  Response to a `session/request_permission` request, carrying the user's
  decision.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionOutcome
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{outcome: RequestPermissionOutcome.t(), _meta: map()}

  @enforce_keys [:outcome]
  defstruct [:outcome, _meta: %{}]

  @known_wire_keys ~w(outcome)

  @spec new(RequestPermissionOutcome.t()) :: t()
  def new(outcome), do: %__MODULE__{outcome: outcome}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"outcome" => RequestPermissionOutcome.to_json(r.outcome)}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. A missing/unparseable `outcome` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"outcome" => outcome_json} = map) do
    with {:ok, outcome} <- RequestPermissionOutcome.from_json(outcome_json) do
      {:ok, %__MODULE__{outcome: outcome, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "outcome"}}
  def from_json(other), do: {:error, {:invalid_request_permission_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest do
  @moduledoc """
  Request from the agent asking the client for permission to perform a tool
  call, sent before a sensitive operation.

  `tool_call` is a `Raxol.AgentClientProtocol.Schema.ToolCallUpdate`. Per
  the established convention in this schema layer (see `Plan.entries`),
  `options` decodes leniently -- a missing/non-list value defaults to `[]`
  and individual options that fail to decode are skipped, even though the
  oracle schema marks `options` as required; only `sessionId` and
  `toolCall` can fail this request's decode.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.PermissionOption
  alias Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          tool_call: ToolCallUpdate.t(),
          options: [PermissionOption.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :tool_call]
  defstruct [:session_id, :tool_call, options: [], _meta: %{}]

  @known_wire_keys ~w(sessionId toolCall options)

  @spec new(String.t(), ToolCallUpdate.t(), [PermissionOption.t()]) :: t()
  def new(session_id, tool_call, options \\ []) when is_binary(session_id) do
    %__MODULE__{session_id: session_id, tool_call: tool_call, options: options}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "toolCall" => ToolCallUpdate.to_json(r.tool_call),
      "options" => Enum.map(r.options, &PermissionOption.to_json/1)
    }
    |> WireFields.emit_meta(r._meta)
  end

  @doc """
  Total: never raises. A missing/non-string `sessionId`, or a missing/
  unparseable `toolCall`, is the only failure mode -- `options` decodes
  leniently (see moduledoc).
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"toolCall" => tool_call_json} = map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, tool_call} <- ToolCallUpdate.from_json(tool_call_json) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         tool_call: tool_call,
         options:
           WireFields.list_lenient(Map.get(map, "options"), &PermissionOption.from_json/1, []),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "toolCall"}}
  def from_json(other), do: {:error, {:invalid_request_permission_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.RequestPermissionRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# --- terminal/* ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest do
  @moduledoc """
  Request to create a new terminal and execute a command (`terminal/create`).

  `env` is a list of `Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable`
  (ported separately, landed nested under `AgentTypes` in `agent_types.ex`;
  see this file's header comment for the cross-module naming note).

  ## Fixed defect (wire-shape, vs. schema-oracle)

  Upstream modeled a `timeoutMs` field that does not exist in the pinned
  `schema-v1.19.0` schema, and omitted the oracle's `outputByteLimit`
  (nullable `uint64`) field entirely. `timeout_ms` was dropped;
  `output_byte_limit` was added.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          session_id: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [EnvVariable.t()],
          cwd: String.t() | nil,
          output_byte_limit: non_neg_integer() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :command]
  defstruct [
    :session_id,
    :command,
    args: [],
    env: [],
    cwd: nil,
    output_byte_limit: nil,
    _meta: %{}
  ]

  @known_wire_keys ~w(sessionId command args env cwd outputByteLimit)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, command) when is_binary(session_id) and is_binary(command) do
    %__MODULE__{session_id: session_id, command: command}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "command" => r.command,
      "args" => r.args || [],
      "env" => Enum.map(r.env || [], &EnvVariable.to_json/1)
    }
    |> WireFields.put("cwd", r.cwd)
    |> WireFields.put("outputByteLimit", r.output_byte_limit)
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`command` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, command} <- WireFields.require(map, "command", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         command: command,
         args: WireFields.list_lenient(Map.get(map, "args"), &decode_arg/1, []),
         env: WireFields.list_lenient(Map.get(map, "env"), &EnvVariable.from_json/1, []),
         cwd: WireFields.optional(map, "cwd", &is_binary/1),
         output_byte_limit: WireFields.optional(map, "outputByteLimit", &is_integer/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_create_terminal_request, other}}

  defp decode_arg(arg) when is_binary(arg), do: {:ok, arg}
  defp decode_arg(other), do: {:error, {:invalid_arg, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse do
  @moduledoc """
  Response containing the ID of the newly created terminal.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{terminal_id: String.t(), _meta: map()}

  @enforce_keys [:terminal_id]
  defstruct [:terminal_id, _meta: %{}]

  @known_wire_keys ~w(terminalId)

  @spec new(String.t()) :: t()
  def new(terminal_id) when is_binary(terminal_id), do: %__MODULE__{terminal_id: terminal_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"terminalId" => r.terminal_id} |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{terminal_id: terminal_id, _meta: WireFields.fold_meta(map, @known_wire_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_create_terminal_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.CreateTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest do
  @moduledoc """
  Request to get the current output and status of a terminal
  (`terminal/output`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{session_id: String.t(), terminal_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :terminal_id]
  defstruct [:session_id, :terminal_id, _meta: %{}]

  @known_wire_keys ~w(sessionId terminalId)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, terminal_id) when is_binary(session_id) and is_binary(terminal_id) do
    %__MODULE__{session_id: session_id, terminal_id: terminal_id}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "terminalId" => r.terminal_id}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_terminal_output_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus do
  @moduledoc """
  Exit status of a terminal command: an exit code (normal exit) and/or a
  signal name (killed by signal), independently nullable per the
  schema-oracle.

  ## Fixed defect (missing field, vs. schema-oracle)

  Upstream modeled only `exitCode`; the oracle also has a nullable `signal`
  field. Added here.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          exit_code: non_neg_integer() | nil,
          signal: String.t() | nil,
          _meta: map()
        }

  defstruct exit_code: nil, signal: nil, _meta: %{}

  @known_wire_keys ~w(exitCode signal)

  @spec new(non_neg_integer() | nil, String.t() | nil) :: t()
  def new(exit_code \\ nil, signal \\ nil), do: %__MODULE__{exit_code: exit_code, signal: signal}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{}
    |> WireFields.put("exitCode", s.exit_code)
    |> WireFields.put("signal", s.signal)
    |> WireFields.emit_meta(s._meta)
  end

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       exit_code: WireFields.optional(map, "exitCode", &is_integer/1),
       signal: WireFields.optional(map, "signal", &is_binary/1),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse do
  @moduledoc """
  Response containing the terminal output captured so far, and its exit
  status if the command has completed.

  ## Fixed defect (missing required field, vs. schema-oracle)

  Upstream omitted the oracle's required `truncated: boolean` field
  entirely. Added here.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalExitStatus
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          output: String.t(),
          truncated: boolean(),
          exit_status: TerminalExitStatus.t() | nil,
          _meta: map()
        }

  @enforce_keys [:output, :truncated]
  defstruct [:output, :truncated, exit_status: nil, _meta: %{}]

  @known_wire_keys ~w(output truncated exitStatus)

  @spec new(String.t(), boolean()) :: t()
  def new(output, truncated \\ false) when is_binary(output) and is_boolean(truncated) do
    %__MODULE__{output: output, truncated: truncated}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"output" => r.output, "truncated" => r.truncated}
    |> WireFields.put("exitStatus", encode_exit_status(r.exit_status))
    |> WireFields.emit_meta(r._meta)
  end

  defp encode_exit_status(nil), do: nil
  defp encode_exit_status(%TerminalExitStatus{} = status), do: TerminalExitStatus.to_json(status)

  @doc """
  Total: never raises. Missing/non-string `output` or missing/non-boolean
  `truncated` is the only failure mode -- `exitStatus`, if present but
  unparseable, defaults to `nil` rather than failing the response.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, output} <- WireFields.require(map, "output", &is_binary/1),
         {:ok, truncated} <- WireFields.require(map, "truncated", &is_boolean/1) do
      {:ok,
       %__MODULE__{
         output: output,
         truncated: truncated,
         exit_status:
           WireFields.optional_nested(map, "exitStatus", &TerminalExitStatus.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_terminal_output_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.TerminalOutputResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest do
  @moduledoc """
  Request to release a terminal and free its resources (`terminal/release`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{session_id: String.t(), terminal_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :terminal_id]
  defstruct [:session_id, :terminal_id, _meta: %{}]

  @known_wire_keys ~w(sessionId terminalId)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, terminal_id) when is_binary(session_id) and is_binary(terminal_id) do
    %__MODULE__{session_id: session_id, terminal_id: terminal_id}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "terminalId" => r.terminal_id}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_release_terminal_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse do
  @moduledoc """
  Response to `terminal/release`. Carries no data of its own.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: WireFields.emit_meta(%{}, r._meta)

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map),
    do: {:ok, %__MODULE__{_meta: WireFields.fold_meta(map, [])}}

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ReleaseTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest do
  @moduledoc """
  Request to wait for a terminal command to exit (`terminal/wait_for_exit`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{session_id: String.t(), terminal_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :terminal_id]
  defstruct [:session_id, :terminal_id, _meta: %{}]

  @known_wire_keys ~w(sessionId terminalId)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, terminal_id) when is_binary(session_id) and is_binary(terminal_id) do
    %__MODULE__{session_id: session_id, terminal_id: terminal_id}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "terminalId" => r.terminal_id}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_wait_for_terminal_exit_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse do
  @moduledoc """
  Response containing the exit status of a terminal command.

  ## Fixed defect (wire-shape, vs. schema-oracle)

  Upstream wrapped the exit info in a nested `exitStatus: TerminalExitStatus`
  object (mirroring `TerminalOutputResponse`'s shape). The schema-oracle has
  `exitCode`/`signal` flattened directly on this response, with no nesting
  and no required fields (both nullable). Fixed here to flatten --
  `to_json`/`from_json` no longer round-trip through `TerminalExitStatus`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          exit_code: non_neg_integer() | nil,
          signal: String.t() | nil,
          _meta: map()
        }

  defstruct exit_code: nil, signal: nil, _meta: %{}

  @known_wire_keys ~w(exitCode signal)

  @spec new(non_neg_integer() | nil, String.t() | nil) :: t()
  def new(exit_code \\ nil, signal \\ nil), do: %__MODULE__{exit_code: exit_code, signal: signal}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{}
    |> WireFields.put("exitCode", r.exit_code)
    |> WireFields.put("signal", r.signal)
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       exit_code: WireFields.optional(map, "exitCode", &is_integer/1),
       signal: WireFields.optional(map, "signal", &is_binary/1),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.WaitForTerminalExitResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest do
  @moduledoc """
  Request to kill a terminal command without releasing the terminal
  (`terminal/kill`).

  ## Fixed defect (naming, vs. schema-oracle)

  Upstream named this `KillTerminalCommandRequest` for a method
  `terminal/kill_command`. The schema-oracle names it `KillTerminalRequest`
  for method `terminal/kill`. Renamed here to match.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{session_id: String.t(), terminal_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :terminal_id]
  defstruct [:session_id, :terminal_id, _meta: %{}]

  @known_wire_keys ~w(sessionId terminalId)

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, terminal_id) when is_binary(session_id) and is_binary(terminal_id) do
    %__MODULE__{session_id: session_id, terminal_id: terminal_id}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "terminalId" => r.terminal_id}
    |> WireFields.emit_meta(r._meta)
  end

  @doc "Total: never raises. Missing/non-string `sessionId`/`terminalId` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- WireFields.require(map, "sessionId", &is_binary/1),
         {:ok, terminal_id} <- WireFields.require(map, "terminalId", &is_binary/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         terminal_id: terminal_id,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_kill_terminal_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalRequest.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse do
  @moduledoc """
  Response to `terminal/kill`. Carries no data of its own.

  ## Fixed defect (naming, vs. schema-oracle)

  Upstream named this `KillTerminalCommandResponse`. The schema-oracle names
  it `KillTerminalResponse`. Renamed here to match.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: WireFields.emit_meta(%{}, r._meta)

  @doc "Total: never raises, even for a non-map argument."
  @spec from_json(term()) :: {:ok, t()}
  def from_json(map) when is_map(map),
    do: {:ok, %__MODULE__{_meta: WireFields.fold_meta(map, [])}}

  def from_json(_other), do: {:ok, %__MODULE__{}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.KillTerminalResponse.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# --- Client Capabilities ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities do
  @moduledoc """
  Capabilities declared by the client at `initialize`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          terminal: boolean(),
          file_system: FileSystemCapability.t() | nil,
          _meta: map()
        }

  defstruct terminal: false, file_system: nil, _meta: %{}

  @known_wire_keys ~w(terminal fileSystem)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"terminal" => c.terminal}
    |> then(fn map ->
      if c.file_system,
        do: Map.put(map, "fileSystem", FileSystemCapability.to_json(c.file_system)),
        else: map
    end)
    |> WireFields.emit_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, fs} <- decode_file_system(Map.get(map, "fileSystem")) do
      {:ok,
       %__MODULE__{
         terminal: Map.get(map, "terminal", false),
         file_system: fs,
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_client_capabilities, other}}

  defp decode_file_system(nil), do: {:ok, nil}
  defp decode_file_system(fs), do: FileSystemCapability.from_json(fs)
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# --- File System Capability ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability do
  @moduledoc """
  File-system capabilities supported by the client.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          write_text_file: boolean(),
          read_text_file: boolean(),
          _meta: map()
        }

  defstruct write_text_file: false, read_text_file: false, _meta: %{}

  @known_wire_keys ~w(writeTextFile readTextFile)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"writeTextFile" => c.write_text_file, "readTextFile" => c.read_text_file}
    |> WireFields.emit_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       write_text_file: Map.get(map, "writeTextFile", false),
       read_text_file: Map.get(map, "readTextFile", false),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_file_system_capability, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ClientTypes.FileSystemCapability.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

# --- Agent Request (routing enum) ---

defmodule Raxol.AgentClientProtocol.Schema.ClientTypes.AgentRequest do
  @moduledoc """
  Enum of all possible agent->client requests, with their wire method names.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.ClientTypes

  @type t ::
          {:write_text_file, ClientTypes.WriteTextFileRequest.t()}
          | {:read_text_file, ClientTypes.ReadTextFileRequest.t()}
          | {:request_permission, ClientTypes.RequestPermissionRequest.t()}
          | {:create_terminal, ClientTypes.CreateTerminalRequest.t()}
          | {:terminal_output, ClientTypes.TerminalOutputRequest.t()}
          | {:release_terminal, ClientTypes.ReleaseTerminalRequest.t()}
          | {:wait_for_terminal_exit, ClientTypes.WaitForTerminalExitRequest.t()}
          | {:kill_terminal_command, ClientTypes.KillTerminalRequest.t()}
          | {:ext_method, Raxol.AgentClientProtocol.Schema.Ext.ExtRequest.t()}

  @spec method(t()) :: String.t()
  def method({:write_text_file, _}), do: "fs/write_text_file"
  def method({:read_text_file, _}), do: "fs/read_text_file"
  def method({:request_permission, _}), do: "session/request_permission"
  def method({:create_terminal, _}), do: "terminal/create"
  def method({:terminal_output, _}), do: "terminal/output"
  def method({:release_terminal, _}), do: "terminal/release"
  def method({:wait_for_terminal_exit, _}), do: "terminal/wait_for_exit"
  def method({:kill_terminal_command, _}), do: "terminal/kill"
  def method({:ext_method, req}), do: req.method
end
