defmodule Raxol.AgentClientProtocol.Schema.AgentTypes do
  @moduledoc """
  Agent-side types for the Agent Client Protocol: the `initialize`/
  `authenticate` handshake, session lifecycle (`session/new`, `session/load`,
  `session/set_mode`, `session/prompt`, `session/cancel`), capability
  negotiation, and MCP server descriptors.

  Every struct here carries an `_meta` map (default `%{}`) that is total on
  decode: unrecognized top-level wire keys, plus the contents of an explicit
  `"_meta"` wire object, are folded into it (via `extract_meta/2`) and
  re-emitted nested under the wire `"_meta"` key on encode (via
  `put_meta/2`, matching every sibling schema module's
  `WireFields.emit_meta/2` convention), so round-tripping an object this
  library doesn't fully understand never loses data. `from_json/1` never
  raises; it always returns `{:ok, t}` or `{:error, reason}`.

  ## Cross-module references

  `PromptRequest.prompt` is a list of
  `Raxol.AgentClientProtocol.Schema.ContentBlock` (ported separately from
  `content.ex`); `InitializeRequest.client_capabilities` /
  `InitializeResponse` reference
  `Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities` (ported
  separately from `client_types.ex`); `ClientRequest`/`ClientNotification`
  reference `Raxol.AgentClientProtocol.Schema.Ext.{ExtRequest, ExtNotification,
  ExtResponse}` (ported separately from `ext.ex`); protocol version decode
  uses `Raxol.AgentClientProtocol.Schema.Version.coerce/1` (ported separately
  from `version.ex`, already landed). All referenced by their expected final
  module names; until every sibling port lands in this package, `mix compile
  --warnings-as-errors` on the whole package may flag the not-yet-landed ones
  as undefined (this file's own structs, decode helpers, and tests are
  self-contained and compile/test clean in isolation — see the coder's
  report).

  Note: `ACP.SessionUpdate` (the `session/update` notification's
  `sessionUpdate`-discriminated union) lives in upstream's
  `lib/acp/client_types.ex`, not `agent_types.ex` — it is intentionally NOT
  ported here. It has since landed as
  `Raxol.AgentClientProtocol.Schema.SessionUpdate` in its own file,
  `session_update.ex` (not `client_types.ex`, since the union's own variant
  payload structs — `ContentChunk`, `CurrentModeUpdate`,
  `AvailableCommandsUpdate`/`AvailableCommand`/`AvailableCommandInput`/
  `UnstructuredCommandInput` — had no other landed home yet); the
  `ACP.SessionNotification` envelope (`{sessionId, update, _meta}`) that
  wraps it for the wire, and the `AgentNotification` routing union that
  carries it, still belong to whichever coder ports `client_types.ex`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @doc false
  # Fetch a required wire field, turning a missing key into a typed error
  # instead of a `KeyError`-raising hard match.
  @spec fetch(map(), String.t()) :: {:ok, term()} | {:error, {:missing_field, String.t()}}
  def fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_field, key}}
    end
  end

  @doc false
  # Decode a list strictly: the first item that fails to decode aborts the
  # whole list with its error.
  @spec decode_list(term(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def decode_list(list, decoder) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case decoder.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  def decode_list(_not_a_list, _decoder), do: {:error, :not_a_list}

  @doc false
  # Decode an optional field: absent/nil short-circuits to `{:ok, nil}`,
  # otherwise delegates to `decoder`.
  @spec decode_optional(map(), String.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term() | nil} | {:error, term()}
  def decode_optional(map, key, decoder) when is_map(map) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value -> decoder.(value)
    end
  end

  @doc false
  # Everything in `map` that isn't one of `known_keys`, plus the contents of
  # an explicit `"_meta"` object (if present), merged into one map. This is
  # the forward-compat pass-through: wire fields this module doesn't know
  # about are never dropped, they ride along in `_meta` and are re-emitted
  # on encode by `put_meta/2`.
  @spec extract_meta(map(), [String.t()]) :: map()
  def extract_meta(map, known_keys) when is_map(map) do
    map
    |> Map.drop(known_keys)
    |> Map.drop(["_meta"])
    |> Map.merge(meta_of(map))
  end

  defp meta_of(%{"_meta" => meta}) when is_map(meta), do: meta
  defp meta_of(_map), do: %{}

  @doc """
  Re-emit a struct's `_meta` bucket under the wire `"_meta"` key, omitted
  when empty -- matches `Raxol.AgentClientProtocol.Schema.WireFields.emit_meta/2`,
  the convention every sibling module in this package (`content.ex`,
  `plan.ex`, `tool_call.ex`, `client_types.ex`) follows. Previously this
  flattened `meta`'s contents directly onto the top-level wire object
  (`Map.merge/2`), a genuine encode/decode asymmetry bug: `extract_meta/2`
  above already folds an explicit `"_meta"` object correctly on decode, so
  a round trip through the old `put_meta/2` silently promoted nested
  `_meta` content to top-level fields instead of preserving the nesting.
  """
  @spec put_meta(map(), map()) :: map()
  def put_meta(json, meta) when map_size(meta) == 0, do: json
  def put_meta(json, meta) when is_map(meta), do: Map.put(json, "_meta", meta)
end

# -- Implementation ----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation do
  @moduledoc """
  Identifies an agent or client implementation (name, version, optional title).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "version", "title", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          title: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:name, :version]
  defstruct name: nil, version: nil, title: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, version), do: %__MODULE__{name: name, version: version}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = impl) do
    %{"name" => impl.name, "version" => impl.version}
    |> maybe_put("title", impl.title)
    |> AgentTypes.put_meta(impl._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, version} <- AgentTypes.fetch(map, "version") do
      {:ok,
       %__MODULE__{
         name: name,
         version: version,
         title: Map.get(map, "title"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_implementation, other}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation

  def encode(%Implementation{} = val, opts) do
    val |> Implementation.to_json() |> Jason.Encode.map(opts)
  end
end

# -- AuthMethod ----------------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod do
  @moduledoc """
  A method by which a client may authenticate with an agent.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["id", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:id, :name]
  defstruct id: nil, name: nil, description: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(id, name), do: %__MODULE__{id: id, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = m) do
    %{"id" => m.id, "name" => m.name}
    |> maybe_put("description", m.description)
    |> AgentTypes.put_meta(m._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- AgentTypes.fetch(map, "id"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_auth_method, other}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthMethod

  def encode(%AuthMethod{} = val, opts) do
    val |> AuthMethod.to_json() |> Jason.Encode.map(opts)
  end
end

# -- InitializeRequest ----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest do
  @moduledoc """
  The `initialize` request, sent by the client to negotiate protocol version
  and capabilities.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.Implementation
  alias Raxol.AgentClientProtocol.Schema.ClientTypes.ClientCapabilities
  alias Raxol.AgentClientProtocol.Schema.Version

  @known_keys ["protocolVersion", "clientCapabilities", "clientInfo", "_meta"]

  @type t :: %__MODULE__{
          protocol_version: Version.t(),
          client_capabilities: ClientCapabilities.t() | nil,
          client_info: Implementation.t() | nil,
          _meta: map()
        }

  @enforce_keys [:protocol_version]
  defstruct protocol_version: nil, client_capabilities: nil, client_info: nil, _meta: %{}

  @spec new(Version.t()) :: t()
  def new(protocol_version) do
    %__MODULE__{
      protocol_version: protocol_version,
      client_capabilities: ClientCapabilities.new()
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"protocolVersion" => r.protocol_version}
    |> maybe_put_capabilities(r.client_capabilities)
    |> maybe_put_info(r.client_info)
    |> AgentTypes.put_meta(r._meta)
  end

  @doc """
  Decodes an `initialize` request. Uses `Version.coerce/1` (tolerant of legacy
  string protocol versions from older clients, e.g. Zed's date-string
  handshake) since this is the initial handshake.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_pv} <- AgentTypes.fetch(map, "protocolVersion"),
         {:ok, pv} <- Version.coerce(raw_pv),
         {:ok, client_capabilities} <-
           decode_client_capabilities(Map.get(map, "clientCapabilities")),
         {:ok, client_info} <-
           AgentTypes.decode_optional(map, "clientInfo", &Implementation.from_json/1) do
      {:ok,
       %__MODULE__{
         protocol_version: pv,
         client_capabilities: client_capabilities,
         client_info: client_info,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_initialize_request, other}}

  defp decode_client_capabilities(nil), do: {:ok, ClientCapabilities.new()}
  defp decode_client_capabilities(cc), do: ClientCapabilities.from_json(cc)

  defp maybe_put_capabilities(map, nil), do: map

  defp maybe_put_capabilities(map, cc) do
    if cc == ClientCapabilities.new(),
      do: map,
      else: Map.put(map, "clientCapabilities", ClientCapabilities.to_json(cc))
  end

  defp maybe_put_info(map, nil), do: map
  defp maybe_put_info(map, info), do: Map.put(map, "clientInfo", Implementation.to_json(info))
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeRequest

  def encode(%InitializeRequest{} = val, opts) do
    val |> InitializeRequest.to_json() |> Jason.Encode.map(opts)
  end
end

# -- InitializeResponse ----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse do
  @moduledoc """
  The `initialize` response, sent by the agent with its capabilities and
  supported authentication methods.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentCapabilities,
    AuthMethod,
    Implementation
  }

  alias Raxol.AgentClientProtocol.Schema.Version

  @known_keys ["protocolVersion", "agentCapabilities", "authMethods", "agentInfo", "_meta"]

  @type t :: %__MODULE__{
          protocol_version: Version.t(),
          agent_capabilities: AgentCapabilities.t() | nil,
          auth_methods: [AuthMethod.t()] | nil,
          agent_info: Implementation.t() | nil,
          _meta: map()
        }

  @enforce_keys [:protocol_version]
  defstruct protocol_version: nil,
            agent_capabilities: nil,
            auth_methods: nil,
            agent_info: nil,
            _meta: %{}

  @spec new(Version.t()) :: t()
  def new(protocol_version) do
    %__MODULE__{
      protocol_version: protocol_version,
      agent_capabilities: AgentCapabilities.new(),
      auth_methods: []
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"protocolVersion" => r.protocol_version}
    |> maybe_put_capabilities(r.agent_capabilities)
    |> maybe_put_auth_methods(r.auth_methods)
    |> maybe_put_info(r.agent_info)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_pv} <- AgentTypes.fetch(map, "protocolVersion"),
         {:ok, pv} <- Version.coerce(raw_pv),
         {:ok, agent_capabilities} <-
           decode_agent_capabilities(Map.get(map, "agentCapabilities")),
         {:ok, auth_methods} <-
           AgentTypes.decode_list(Map.get(map, "authMethods", []), &AuthMethod.from_json/1),
         {:ok, agent_info} <-
           AgentTypes.decode_optional(map, "agentInfo", &Implementation.from_json/1) do
      {:ok,
       %__MODULE__{
         protocol_version: pv,
         agent_capabilities: agent_capabilities,
         auth_methods: auth_methods,
         agent_info: agent_info,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_initialize_response, other}}

  defp decode_agent_capabilities(nil), do: {:ok, AgentCapabilities.new()}
  defp decode_agent_capabilities(ac), do: AgentCapabilities.from_json(ac)

  defp maybe_put_capabilities(map, nil), do: map

  defp maybe_put_capabilities(map, ac) do
    if ac == AgentCapabilities.new(),
      do: map,
      else: Map.put(map, "agentCapabilities", AgentCapabilities.to_json(ac))
  end

  defp maybe_put_auth_methods(map, nil), do: map
  defp maybe_put_auth_methods(map, []), do: map

  defp maybe_put_auth_methods(map, methods) do
    Map.put(map, "authMethods", Enum.map(methods, &AuthMethod.to_json/1))
  end

  defp maybe_put_info(map, nil), do: map
  defp maybe_put_info(map, info), do: Map.put(map, "agentInfo", Implementation.to_json(info))
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

  def encode(%InitializeResponse{} = val, opts) do
    val |> InitializeResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- AuthenticateRequest / AuthenticateResponse --------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest do
  @moduledoc """
  The `authenticate` request, sent by the client with the chosen auth method id.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["methodId", "_meta"]

  @type t :: %__MODULE__{method_id: String.t(), _meta: map()}

  @enforce_keys [:method_id]
  defstruct method_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(method_id), do: %__MODULE__{method_id: method_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"methodId" => r.method_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, method_id} <- AgentTypes.fetch(map, "methodId") do
      {:ok, %__MODULE__{method_id: method_id, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_authenticate_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateRequest

  def encode(%AuthenticateRequest{} = val, opts) do
    val |> AuthenticateRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `authenticate`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other), do: {:error, {:invalid_authenticate_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AuthenticateResponse

  def encode(%AuthenticateResponse{} = val, opts) do
    val |> AuthenticateResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- NewSessionRequest / NewSessionResponse ------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest do
  @moduledoc """
  The `session/new` request: creates a new session rooted at `cwd`, optionally
  wiring up MCP servers.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer

  @known_keys ["cwd", "mcpServers", "_meta"]

  @type t :: %__MODULE__{cwd: String.t(), mcp_servers: [McpServer.t()], _meta: map()}

  @enforce_keys [:cwd]
  defstruct cwd: nil, mcp_servers: [], _meta: %{}

  @spec new(String.t()) :: t()
  def new(cwd), do: %__MODULE__{cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"cwd" => r.cwd, "mcpServers" => Enum.map(r.mcp_servers || [], &McpServer.to_json/1)}
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(Map.get(map, "mcpServers", []), &McpServer.from_json/1) do
      {:ok,
       %__MODULE__{
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_new_session_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionRequest

  def encode(%NewSessionRequest{} = val, opts) do
    val |> NewSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse do
  @moduledoc """
  The `session/new` response: the new session id plus optional mode/model/
  config-option state (the latter two are unstable extensions).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.Unstable.{SessionConfigOption, SessionModelState}

  @known_keys ["sessionId", "modes", "models", "configOptions", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil,
          _meta: map()
        }

  @enforce_keys [:session_id]
  defstruct session_id: nil, modes: nil, models: nil, config_options: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id}
    |> maybe_put_modes(r.modes)
    |> maybe_put_models(r.models)
    |> maybe_put_config_options(r.config_options)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, modes} <- AgentTypes.decode_optional(map, "modes", &SessionModeState.from_json/1),
         {:ok, models} <-
           AgentTypes.decode_optional(map, "models", &SessionModelState.from_json/1),
         {:ok, config_options} <- decode_config_options(Map.get(map, "configOptions")) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         modes: modes,
         models: models,
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_new_session_response, other}}

  defp decode_config_options(nil), do: {:ok, nil}

  defp decode_config_options(opts),
    do: AgentTypes.decode_list(opts, &SessionConfigOption.from_json/1)

  defp maybe_put_modes(map, nil), do: map
  defp maybe_put_modes(map, modes), do: Map.put(map, "modes", SessionModeState.to_json(modes))

  defp maybe_put_models(map, nil), do: map

  defp maybe_put_models(map, models),
    do: Map.put(map, "models", SessionModelState.to_json(models))

  defp maybe_put_config_options(map, nil), do: map

  defp maybe_put_config_options(map, opts) do
    Map.put(map, "configOptions", Enum.map(opts, &SessionConfigOption.to_json/1))
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse

  def encode(%NewSessionResponse{} = val, opts) do
    val |> NewSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- LoadSessionRequest / LoadSessionResponse ----------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest do
  @moduledoc """
  The `session/load` request: replays an existing session's history.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer

  @known_keys ["sessionId", "cwd", "mcpServers", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          mcp_servers: [McpServer.t()],
          _meta: map()
        }

  @enforce_keys [:session_id, :cwd]
  defstruct session_id: nil, cwd: nil, mcp_servers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, cwd), do: %__MODULE__{session_id: session_id, cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "cwd" => r.cwd,
      "mcpServers" => Enum.map(r.mcp_servers || [], &McpServer.to_json/1)
    }
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(Map.get(map, "mcpServers", []), &McpServer.from_json/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_load_session_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest

  def encode(%LoadSessionRequest{} = val, opts) do
    val |> LoadSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse do
  @moduledoc """
  The `session/load` response: optional mode/model/config-option state.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState
  alias Raxol.AgentClientProtocol.Schema.Unstable.{SessionConfigOption, SessionModelState}

  @known_keys ["modes", "models", "configOptions", "_meta"]

  @type t :: %__MODULE__{
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil,
          _meta: map()
        }

  defstruct modes: nil, models: nil, config_options: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{}
    |> maybe_put_modes(r.modes)
    |> maybe_put_models(r.models)
    |> maybe_put_config_options(r.config_options)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, modes} <- AgentTypes.decode_optional(map, "modes", &SessionModeState.from_json/1),
         {:ok, models} <-
           AgentTypes.decode_optional(map, "models", &SessionModelState.from_json/1),
         {:ok, config_options} <- decode_config_options(Map.get(map, "configOptions")) do
      {:ok,
       %__MODULE__{
         modes: modes,
         models: models,
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_load_session_response, other}}

  defp decode_config_options(nil), do: {:ok, nil}

  defp decode_config_options(opts),
    do: AgentTypes.decode_list(opts, &SessionConfigOption.from_json/1)

  defp maybe_put_modes(map, nil), do: map
  defp maybe_put_modes(map, modes), do: Map.put(map, "modes", SessionModeState.to_json(modes))

  defp maybe_put_models(map, nil), do: map

  defp maybe_put_models(map, models),
    do: Map.put(map, "models", SessionModelState.to_json(models))

  defp maybe_put_config_options(map, nil), do: map

  defp maybe_put_config_options(map, opts) do
    Map.put(map, "configOptions", Enum.map(opts, &SessionConfigOption.to_json/1))
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse

  def encode(%LoadSessionResponse{} = val, opts) do
    val |> LoadSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- SessionModeState / SessionMode --------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState do
  @moduledoc """
  The set of available session modes and the one currently active.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode

  @known_keys ["currentModeId", "availableModes", "_meta"]

  @type t :: %__MODULE__{
          current_mode_id: String.t(),
          available_modes: [SessionMode.t()],
          _meta: map()
        }

  @enforce_keys [:current_mode_id, :available_modes]
  defstruct current_mode_id: nil, available_modes: nil, _meta: %{}

  @spec new(String.t(), [SessionMode.t()]) :: t()
  def new(current_mode_id, available_modes) do
    %__MODULE__{current_mode_id: current_mode_id, available_modes: available_modes}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentModeId" => s.current_mode_id,
      "availableModes" => Enum.map(s.available_modes, &SessionMode.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_mode_id} <- AgentTypes.fetch(map, "currentModeId"),
         {:ok, raw_modes} <- AgentTypes.fetch(map, "availableModes"),
         {:ok, available_modes} <- AgentTypes.decode_list(raw_modes, &SessionMode.from_json/1) do
      {:ok,
       %__MODULE__{
         current_mode_id: current_mode_id,
         available_modes: available_modes,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_mode_state, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState

  def encode(%SessionModeState{} = val, opts) do
    val |> SessionModeState.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode do
  @moduledoc """
  A single selectable session mode (e.g. "code", "ask").

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["id", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:id, :name]
  defstruct id: nil, name: nil, description: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(id, name), do: %__MODULE__{id: id, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = m) do
    %{"id" => m.id, "name" => m.name}
    |> maybe_put("description", m.description)
    |> AgentTypes.put_meta(m._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- AgentTypes.fetch(map, "id"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_mode, other}}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionMode

  def encode(%SessionMode{} = val, opts) do
    val |> SessionMode.to_json() |> Jason.Encode.map(opts)
  end
end

# -- SetSessionModeRequest / SetSessionModeResponse ----------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest do
  @moduledoc """
  The `session/set_mode` request.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "modeId", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), mode_id: String.t(), _meta: map()}

  @enforce_keys [:session_id, :mode_id]
  defstruct session_id: nil, mode_id: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, mode_id), do: %__MODULE__{session_id: session_id, mode_id: mode_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"sessionId" => r.session_id, "modeId" => r.mode_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, mode_id} <- AgentTypes.fetch(map, "modeId") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         mode_id: mode_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_set_session_mode_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeRequest

  def encode(%SetSessionModeRequest{} = val, opts) do
    val |> SetSessionModeRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/set_mode`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other), do: {:error, {:invalid_set_session_mode_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SetSessionModeResponse

  def encode(%SetSessionModeResponse{} = val, opts) do
    val |> SetSessionModeResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- PromptRequest / PromptResponse / StopReason -------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest do
  @moduledoc """
  The `session/prompt` request: a turn's content blocks sent to the agent.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.ContentBlock

  @known_keys ["sessionId", "prompt", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), prompt: [ContentBlock.t()], _meta: map()}

  @enforce_keys [:session_id, :prompt]
  defstruct session_id: nil, prompt: nil, _meta: %{}

  @spec new(String.t(), [ContentBlock.t()]) :: t()
  def new(session_id, prompt), do: %__MODULE__{session_id: session_id, prompt: prompt}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "prompt" => Enum.map(r.prompt, &ContentBlock.to_json/1)}
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, raw_prompt} <- AgentTypes.fetch(map, "prompt"),
         {:ok, prompt} <- AgentTypes.decode_list(raw_prompt, &ContentBlock.from_json/1) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         prompt: prompt,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_prompt_request, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest

  def encode(%PromptRequest{} = val, opts) do
    val |> PromptRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.StopReason do
  @moduledoc """
  Why a `session/prompt` turn ended.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: :end_turn | :max_tokens | :max_turn_requests | :refusal | :cancelled

  @spec to_json(t()) :: String.t()
  def to_json(:end_turn), do: "end_turn"
  def to_json(:max_tokens), do: "max_tokens"
  def to_json(:max_turn_requests), do: "max_turn_requests"
  def to_json(:refusal), do: "refusal"
  def to_json(:cancelled), do: "cancelled"

  @doc """
  Total: unrecognized stop reason strings return
  `{:error, {:invalid_stop_reason, _}}` instead of raising
  (upstream's version had no catch-all clause here).
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, {:invalid_stop_reason, term()}}
  def from_json("end_turn"), do: {:ok, :end_turn}
  def from_json("max_tokens"), do: {:ok, :max_tokens}
  def from_json("max_turn_requests"), do: {:ok, :max_turn_requests}
  def from_json("refusal"), do: {:ok, :refusal}
  def from_json("cancelled"), do: {:ok, :cancelled}
  def from_json(other), do: {:error, {:invalid_stop_reason, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse do
  @moduledoc """
  The `session/prompt` response: why the turn ended.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.StopReason

  @known_keys ["stopReason", "_meta"]

  @type t :: %__MODULE__{stop_reason: StopReason.t(), _meta: map()}

  @enforce_keys [:stop_reason]
  defstruct stop_reason: nil, _meta: %{}

  @spec new(StopReason.t()) :: t()
  def new(stop_reason), do: %__MODULE__{stop_reason: stop_reason}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"stopReason" => StopReason.to_json(r.stop_reason)}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw} <- AgentTypes.fetch(map, "stopReason"),
         {:ok, stop_reason} <- StopReason.from_json(raw) do
      {:ok,
       %__MODULE__{stop_reason: stop_reason, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_prompt_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptResponse

  def encode(%PromptResponse{} = val, opts) do
    val |> PromptResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- CancelNotification ---------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification do
  @moduledoc """
  The `session/cancel` notification.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), _meta: map()}

  @enforce_keys [:session_id]
  defstruct session_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"sessionId" => r.session_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId") do
      {:ok, %__MODULE__{session_id: session_id, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_cancel_notification, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification

  def encode(%CancelNotification{} = val, opts) do
    val |> CancelNotification.to_json() |> Jason.Encode.map(opts)
  end
end

# -- AgentCapabilities / PromptCapabilities / McpCapabilities / SessionCapabilities

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities do
  @moduledoc """
  Capabilities declared by the agent in the `initialize` response.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    McpCapabilities,
    PromptCapabilities,
    SessionCapabilities
  }

  @known_keys [
    "loadSession",
    "promptCapabilities",
    "mcpCapabilities",
    "sessionCapabilities",
    "_meta"
  ]

  @type t :: %__MODULE__{
          load_session: boolean(),
          prompt_capabilities: PromptCapabilities.t() | nil,
          mcp_capabilities: McpCapabilities.t() | nil,
          session_capabilities: SessionCapabilities.t() | nil,
          _meta: map()
        }

  defstruct load_session: false,
            prompt_capabilities: nil,
            mcp_capabilities: nil,
            session_capabilities: nil,
            _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"loadSession" => c.load_session}
    |> maybe_put_prompt(c.prompt_capabilities)
    |> maybe_put_mcp(c.mcp_capabilities)
    |> maybe_put_session(c.session_capabilities)
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, prompt_capabilities} <-
           AgentTypes.decode_optional(map, "promptCapabilities", &PromptCapabilities.from_json/1),
         {:ok, mcp_capabilities} <-
           AgentTypes.decode_optional(map, "mcpCapabilities", &McpCapabilities.from_json/1),
         {:ok, session_capabilities} <-
           AgentTypes.decode_optional(
             map,
             "sessionCapabilities",
             &SessionCapabilities.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         load_session: Map.get(map, "loadSession", false),
         prompt_capabilities: prompt_capabilities,
         mcp_capabilities: mcp_capabilities,
         session_capabilities: session_capabilities,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_agent_capabilities, other}}

  defp maybe_put_prompt(map, nil), do: map

  defp maybe_put_prompt(map, pc),
    do: Map.put(map, "promptCapabilities", PromptCapabilities.to_json(pc))

  defp maybe_put_mcp(map, nil), do: map
  defp maybe_put_mcp(map, mc), do: Map.put(map, "mcpCapabilities", McpCapabilities.to_json(mc))

  defp maybe_put_session(map, nil), do: map

  defp maybe_put_session(map, sc),
    do: Map.put(map, "sessionCapabilities", SessionCapabilities.to_json(sc))
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.AgentCapabilities

  def encode(%AgentCapabilities{} = val, opts) do
    val |> AgentCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.PromptCapabilities do
  @moduledoc """
  Content-block kinds the agent accepts in a `session/prompt`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["image", "audio", "embeddedContext", "_meta"]

  @type t :: %__MODULE__{
          image: boolean(),
          audio: boolean(),
          embedded_context: boolean(),
          _meta: map()
        }

  defstruct image: false, audio: false, embedded_context: false, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"image" => c.image, "audio" => c.audio, "embeddedContext" => c.embedded_context}
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       image: Map.get(map, "image", false),
       audio: Map.get(map, "audio", false),
       embedded_context: Map.get(map, "embeddedContext", false),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_prompt_capabilities, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.PromptCapabilities do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptCapabilities

  def encode(%PromptCapabilities{} = val, opts) do
    val |> PromptCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpCapabilities do
  @moduledoc """
  MCP transports the agent supports for client-provided MCP servers.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["http", "sse", "_meta"]

  @type t :: %__MODULE__{http: boolean(), sse: boolean(), _meta: map()}

  defstruct http: false, sse: false, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    AgentTypes.put_meta(%{"http" => c.http, "sse" => c.sse}, c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       http: Map.get(map, "http", false),
       sse: Map.get(map, "sse", false),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_mcp_capabilities, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpCapabilities do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpCapabilities

  def encode(%McpCapabilities{} = val, opts) do
    val |> McpCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities do
  @moduledoc """
  Session-lifecycle capabilities the agent supports, including the unstable
  `list`/`fork`/`resume` extensions.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionForkCapabilities,
    SessionListCapabilities,
    SessionResumeCapabilities
  }

  @known_keys ["modes", "list", "fork", "resume", "_meta"]

  @type t :: %__MODULE__{
          modes: boolean(),
          list: SessionListCapabilities.t() | nil,
          fork: SessionForkCapabilities.t() | nil,
          resume: SessionResumeCapabilities.t() | nil,
          _meta: map()
        }

  defstruct modes: false, list: nil, fork: nil, resume: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    %{"modes" => c.modes}
    |> maybe_put_list(c.list)
    |> maybe_put_fork(c.fork)
    |> maybe_put_resume(c.resume)
    |> AgentTypes.put_meta(c._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, list} <-
           AgentTypes.decode_optional(map, "list", &SessionListCapabilities.from_json/1),
         {:ok, fork} <-
           AgentTypes.decode_optional(map, "fork", &SessionForkCapabilities.from_json/1),
         {:ok, resume} <-
           AgentTypes.decode_optional(map, "resume", &SessionResumeCapabilities.from_json/1) do
      {:ok,
       %__MODULE__{
         modes: Map.get(map, "modes", false),
         list: list,
         fork: fork,
         resume: resume,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_capabilities, other}}

  defp maybe_put_list(map, nil), do: map
  defp maybe_put_list(map, l), do: Map.put(map, "list", SessionListCapabilities.to_json(l))

  defp maybe_put_fork(map, nil), do: map
  defp maybe_put_fork(map, f), do: Map.put(map, "fork", SessionForkCapabilities.to_json(f))

  defp maybe_put_resume(map, nil), do: map
  defp maybe_put_resume(map, r), do: Map.put(map, "resume", SessionResumeCapabilities.to_json(r))
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionCapabilities

  def encode(%SessionCapabilities{} = val, opts) do
    val |> SessionCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

# -- McpServer (union) / McpServerHttp / McpServerSse / McpServerStdio --------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServer do
  @moduledoc """
  A client-provided MCP server descriptor: tagged union of `http`, `sse`
  (both discriminated by a `"type"` wire field), and the untagged `stdio`
  fallback.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{McpServerHttp, McpServerSse, McpServerStdio}

  @type t ::
          {:http, McpServerHttp.t()}
          | {:sse, McpServerSse.t()}
          | {:stdio, McpServerStdio.t()}

  @spec to_json(t()) :: map()
  def to_json({:http, server}), do: Map.put(McpServerHttp.to_json(server), "type", "http")
  def to_json({:sse, server}), do: Map.put(McpServerSse.to_json(server), "type", "sse")
  def to_json({:stdio, server}), do: McpServerStdio.to_json(server)

  @doc """
  Total: never raises. Dispatches on `"type"` for the `http`/`sse` tagged
  variants; anything else (including a bare map with no `"type"` at all) is
  attempted as the untagged `stdio` variant, matching the wire spec (`type`
  is stripped before delegating so it never leaks into the sub-struct's
  `_meta`).
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "http"} = map) do
    case McpServerHttp.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:http, v}}
      error -> error
    end
  end

  def from_json(%{"type" => "sse"} = map) do
    case McpServerSse.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:sse, v}}
      error -> error
    end
  end

  def from_json(map) when is_map(map) do
    case McpServerStdio.from_json(Map.delete(map, "type")) do
      {:ok, v} -> {:ok, {:stdio, v}}
      error -> error
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp do
  @moduledoc """
  A streamable-HTTP MCP server descriptor.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader

  @known_keys ["name", "url", "headers", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          headers: [HttpHeader.t()],
          _meta: map()
        }

  @enforce_keys [:name, :url]
  defstruct name: nil, url: nil, headers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, url), do: %__MODULE__{name: name, url: url, headers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "url" => s.url,
      "headers" => Enum.map(s.headers || [], &HttpHeader.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, url} <- AgentTypes.fetch(map, "url"),
         {:ok, headers} <-
           AgentTypes.decode_list(Map.get(map, "headers", []), &HttpHeader.from_json/1) do
      {:ok,
       %__MODULE__{
         name: name,
         url: url,
         headers: headers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_http, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerHttp

  def encode(%McpServerHttp{} = val, opts) do
    val |> McpServerHttp.to_json() |> Map.put("type", "http") |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse do
  @moduledoc """
  An SSE MCP server descriptor.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader

  @known_keys ["name", "url", "headers", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          headers: [HttpHeader.t()],
          _meta: map()
        }

  @enforce_keys [:name, :url]
  defstruct name: nil, url: nil, headers: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, url), do: %__MODULE__{name: name, url: url, headers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "url" => s.url,
      "headers" => Enum.map(s.headers || [], &HttpHeader.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, url} <- AgentTypes.fetch(map, "url"),
         {:ok, headers} <-
           AgentTypes.decode_list(Map.get(map, "headers", []), &HttpHeader.from_json/1) do
      {:ok,
       %__MODULE__{
         name: name,
         url: url,
         headers: headers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_sse, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerSse

  def encode(%McpServerSse{} = val, opts) do
    val |> McpServerSse.to_json() |> Map.put("type", "sse") |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio do
  @moduledoc """
  A stdio-launched MCP server descriptor (the untagged wire variant: no
  `"type"` field).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable

  @known_keys ["name", "command", "args", "env", "_meta"]

  @type t :: %__MODULE__{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: [EnvVariable.t()],
          _meta: map()
        }

  @enforce_keys [:name, :command]
  defstruct name: nil, command: nil, args: [], env: [], _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, command), do: %__MODULE__{name: name, command: command, args: [], env: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "name" => s.name,
      "command" => s.command,
      "args" => s.args || [],
      "env" => Enum.map(s.env || [], &EnvVariable.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, command} <- AgentTypes.fetch(map, "command"),
         {:ok, env} <-
           AgentTypes.decode_list(Map.get(map, "env", []), &EnvVariable.from_json/1) do
      {:ok,
       %__MODULE__{
         name: name,
         command: command,
         args: Map.get(map, "args", []),
         env: env,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_mcp_server_stdio, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.McpServerStdio

  def encode(%McpServerStdio{} = val, opts) do
    val |> McpServerStdio.to_json() |> Jason.Encode.map(opts)
  end
end

# -- EnvVariable / HttpHeader ---------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable do
  @moduledoc """
  A single `name=value` environment variable for a stdio-launched MCP server.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "value", "_meta"]

  @type t :: %__MODULE__{name: String.t(), value: String.t(), _meta: map()}

  @enforce_keys [:name, :value]
  defstruct name: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, value), do: %__MODULE__{name: name, value: value}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = e) do
    AgentTypes.put_meta(%{"name" => e.name, "value" => e.value}, e._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, value} <- AgentTypes.fetch(map, "value") do
      {:ok,
       %__MODULE__{name: name, value: value, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_env_variable, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.EnvVariable

  def encode(%EnvVariable{} = val, opts) do
    val |> EnvVariable.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader do
  @moduledoc """
  A single HTTP header for an HTTP/SSE MCP server.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["name", "value", "_meta"]

  @type t :: %__MODULE__{name: String.t(), value: String.t(), _meta: map()}

  @enforce_keys [:name, :value]
  defstruct name: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(name, value), do: %__MODULE__{name: name, value: value}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = h) do
    AgentTypes.put_meta(%{"name" => h.name, "value" => h.value}, h._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, value} <- AgentTypes.fetch(map, "value") do
      {:ok,
       %__MODULE__{name: name, value: value, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_http_header, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader do
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.HttpHeader

  def encode(%HttpHeader{} = val, opts) do
    val |> HttpHeader.to_json() |> Jason.Encode.map(opts)
  end
end

# -- ClientRequest / AgentResponse / ClientNotification (routing unions) ------
#
# Pure tagged-tuple unions used for RPC method routing; they carry no
# `_meta`/`to_json`/`from_json` of their own in the upstream source (each
# variant's payload struct handles its own encode/decode), so none is added
# here either.

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.ClientRequest do
  @moduledoc """
  Tagged union of every request the client may send to the agent, used for
  JSON-RPC method-name routing.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AuthenticateRequest,
    InitializeRequest,
    NewSessionRequest,
    PromptRequest,
    SetSessionModeRequest
  }

  alias Raxol.AgentClientProtocol.Schema.Ext.ExtRequest

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionRequest

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ForkSessionRequest,
    ListSessionsRequest,
    ResumeSessionRequest,
    SetSessionConfigOptionRequest,
    SetSessionModelRequest
  }

  @type t ::
          {:initialize, InitializeRequest.t()}
          | {:authenticate, AuthenticateRequest.t()}
          | {:new_session, NewSessionRequest.t()}
          | {:load_session, LoadSessionRequest.t()}
          | {:list_sessions, ListSessionsRequest.t()}
          | {:fork_session, ForkSessionRequest.t()}
          | {:resume_session, ResumeSessionRequest.t()}
          | {:set_session_mode, SetSessionModeRequest.t()}
          | {:set_session_config_option, SetSessionConfigOptionRequest.t()}
          | {:prompt, PromptRequest.t()}
          | {:set_session_model, SetSessionModelRequest.t()}
          | {:ext_method, ExtRequest.t()}

  @spec method(t()) :: String.t()
  def method({:initialize, _}), do: "initialize"
  def method({:authenticate, _}), do: "authenticate"
  def method({:new_session, _}), do: "session/new"
  def method({:load_session, _}), do: "session/load"
  def method({:list_sessions, _}), do: "session/list"
  def method({:fork_session, _}), do: "session/fork"
  def method({:resume_session, _}), do: "session/resume"
  def method({:set_session_mode, _}), do: "session/set_mode"
  def method({:set_session_config_option, _}), do: "session/set_config_option"
  def method({:prompt, _}), do: "session/prompt"
  def method({:set_session_model, _}), do: "session/set_model"
  def method({:ext_method, req}), do: req.method
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.AgentResponse do
  @moduledoc """
  Tagged union of every response the agent may send back to the client.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AuthenticateResponse,
    InitializeResponse,
    NewSessionResponse,
    PromptResponse,
    SetSessionModeResponse
  }

  alias Raxol.AgentClientProtocol.Schema.Ext.ExtResponse

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.LoadSessionResponse

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ForkSessionResponse,
    ListSessionsResponse,
    ResumeSessionResponse,
    SetSessionConfigOptionResponse,
    SetSessionModelResponse
  }

  @type t ::
          {:initialize, InitializeResponse.t()}
          | {:authenticate, AuthenticateResponse.t()}
          | {:new_session, NewSessionResponse.t()}
          | {:load_session, LoadSessionResponse.t()}
          | {:list_sessions, ListSessionsResponse.t()}
          | {:fork_session, ForkSessionResponse.t()}
          | {:resume_session, ResumeSessionResponse.t()}
          | {:set_session_mode, SetSessionModeResponse.t()}
          | {:set_session_config_option, SetSessionConfigOptionResponse.t()}
          | {:prompt, PromptResponse.t()}
          | {:set_session_model, SetSessionModelResponse.t()}
          | {:ext_method, ExtResponse.t()}
end

defmodule Raxol.AgentClientProtocol.Schema.AgentTypes.ClientNotification do
  @moduledoc """
  Tagged union of every notification the client may send to the agent, used
  for JSON-RPC method-name routing.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.CancelNotification
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtNotification

  @type t ::
          {:cancel, CancelNotification.t()}
          | {:ext_notification, ExtNotification.t()}

  @spec method(t()) :: String.t()
  def method({:cancel, _}), do: "session/cancel"
  def method({:ext_notification, notif}), do: notif.method
end
