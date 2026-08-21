defmodule Raxol.AgentClientProtocol.Schema.Unstable do
  @moduledoc """
  Unstable ACP types that are not yet part of the stable protocol surface —
  the Elixir counterpart of the Rust reference implementation's
  `#[cfg(feature = "unstable_*")]`-gated types: session model selection
  (`session/set_model`), generic session config options
  (`session/set_config_option`), session fork/resume/list
  (`session/fork`, `session/resume`, `session/list`), and their capability
  flags. These may be removed or changed at any point; callers should gate
  their use on the corresponding `Raxol.AgentClientProtocol.Schema.AgentTypes.
  SessionCapabilities` fields (`:list`, `:fork`, `:resume`) rather than
  assuming availability.

  Every struct here carries an `_meta` map (default `%{}`), total on decode
  via the shared `Raxol.AgentClientProtocol.Schema.AgentTypes` decode helpers
  (`fetch/2`, `decode_list/2`, `decode_optional/3`, `extract_meta/2`,
  `put_meta/2`) — unrecognized top-level wire keys are folded into `_meta` on
  decode and re-emitted on encode. `from_json/1` never raises.

  ## Cross-module references

  `SessionInfoUpdate` uses `Raxol.AgentClientProtocol.Schema.MaybeUndefined`
  (ported separately from `maybe_undefined.ex`) for its three-state
  undefined/null/value fields. `ForkSessionRequest`/`ResumeSessionRequest.
  mcp_servers` and `ForkSessionResponse`/`ResumeSessionResponse.modes`
  reference `Raxol.AgentClientProtocol.Schema.AgentTypes.{McpServer,
  SessionModeState}` (this package's sibling file, `agent_types.ex`,
  already ported alongside this one). Referenced by expected final module
  names; see `agent_types.ex`'s moduledoc for the same compile-barrier
  caveat.

  Note: `ACP.SessionUpdate`'s unstable variants (`config_option_update`,
  `session_info_update`) are NOT ported here — in the upstream source the
  `SessionUpdate` union itself lives in `lib/acp/client_types.ex`, so its
  variant wiring belongs to whichever coder ports that file. This file ports
  only the payload structs those variants would carry
  (`ConfigOptionUpdate`, `SessionInfoUpdate`).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """
end

# -- Session Model Types -------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo do
  @moduledoc """
  Information about a selectable model. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["modelId", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          model_id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:model_id, :name]
  defstruct model_id: nil, name: nil, description: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(model_id, name), do: %__MODULE__{model_id: model_id, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = m) do
    %{"modelId" => m.model_id, "name" => m.name}
    |> AgentTypes.maybe_put("description", m.description)
    |> AgentTypes.put_meta(m._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, model_id} <- AgentTypes.fetch(map, "modelId"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         model_id: model_id,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_model_info, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo

  def encode(%ModelInfo{} = val, opts) do
    val |> ModelInfo.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionModelState do
  @moduledoc """
  The set of selectable models and the one currently active. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.ModelInfo

  @known_keys ["currentModelId", "availableModels", "_meta"]

  @type t :: %__MODULE__{
          current_model_id: String.t(),
          available_models: [ModelInfo.t()],
          _meta: map()
        }

  @enforce_keys [:current_model_id, :available_models]
  defstruct current_model_id: nil, available_models: nil, _meta: %{}

  @spec new(String.t(), [ModelInfo.t()]) :: t()
  def new(current_model_id, available_models) do
    %__MODULE__{
      current_model_id: current_model_id,
      available_models: available_models
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentModelId" => s.current_model_id,
      "availableModels" => Enum.map(s.available_models, &ModelInfo.to_json/1)
    }
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_model_id} <- AgentTypes.fetch(map, "currentModelId"),
         {:ok, raw_models} <- AgentTypes.fetch(map, "availableModels"),
         {:ok, available_models} <-
           AgentTypes.decode_list(raw_models, &ModelInfo.from_json/1) do
      {:ok,
       %__MODULE__{
         current_model_id: current_model_id,
         available_models: available_models,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_model_state, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionModelState do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionModelState

  def encode(%SessionModelState{} = val, opts) do
    val |> SessionModelState.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelRequest do
  @moduledoc """
  Request to set the active model for a session (`session/set_model`).
  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "modelId", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          model_id: String.t(),
          _meta: map()
        }

  @enforce_keys [:session_id, :model_id]
  defstruct session_id: nil, model_id: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, model_id),
    do: %__MODULE__{session_id: session_id, model_id: model_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{"sessionId" => r.session_id, "modelId" => r.model_id},
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, model_id} <- AgentTypes.fetch(map, "modelId") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         model_id: model_id,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_model_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelRequest do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelRequest

  def encode(%SetSessionModelRequest{} = val, opts) do
    val |> SetSessionModelRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/set_model`. (Unstable)

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

  def from_json(other),
    do: {:error, {:invalid_set_session_model_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelResponse do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SetSessionModelResponse

  def encode(%SetSessionModelResponse{} = val, opts) do
    val |> SetSessionModelResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Session Config Option Types ------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption do
  @moduledoc """
  A possible value for a `select`-kind session configuration option.
  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["value", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          value: term(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:value, :name]
  defstruct value: nil, name: nil, description: nil, _meta: %{}

  @spec new(term(), String.t()) :: t()
  def new(value, name), do: %__MODULE__{value: value, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = o) do
    %{"value" => o.value, "name" => o.name}
    |> AgentTypes.maybe_put("description", o.description)
    |> AgentTypes.put_meta(o._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, value} <- AgentTypes.fetch(map, "value"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         value: value,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_option, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption

  def encode(%SessionConfigSelectOption{} = val, opts) do
    val |> SessionConfigSelectOption.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectGroup do
  @moduledoc """
  A named group of `SessionConfigSelectOption`s. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption

  @known_keys ["group", "name", "options", "_meta"]

  @type t :: %__MODULE__{
          group: String.t(),
          name: String.t(),
          options: [SessionConfigSelectOption.t()],
          _meta: map()
        }

  @enforce_keys [:group, :name, :options]
  defstruct group: nil, name: nil, options: nil, _meta: %{}

  @spec new(String.t(), String.t(), [SessionConfigSelectOption.t()]) :: t()
  def new(group, name, options),
    do: %__MODULE__{group: group, name: name, options: options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = g) do
    %{
      "group" => g.group,
      "name" => g.name,
      "options" => Enum.map(g.options, &SessionConfigSelectOption.to_json/1)
    }
    |> AgentTypes.put_meta(g._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, group} <- AgentTypes.fetch(map, "group"),
         {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, raw_options} <- AgentTypes.fetch(map, "options"),
         {:ok, options} <-
           AgentTypes.decode_list(
             raw_options,
             &SessionConfigSelectOption.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         group: group,
         name: name,
         options: options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_group, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectGroup do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectGroup

  def encode(%SessionConfigSelectGroup{} = val, opts) do
    val |> SessionConfigSelectGroup.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOptions do
  @moduledoc """
  Possible values for a `select`-kind session configuration option: an
  untagged union of either a flat list of options (`{:ungrouped, [...]}`) or
  a list of groups (`{:grouped, [...]}`), distinguished on decode by whether
  the first list element has a `"group"` key. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigSelectGroup,
    SessionConfigSelectOption
  }

  @type t ::
          {:ungrouped, [SessionConfigSelectOption.t()]}
          | {:grouped, [SessionConfigSelectGroup.t()]}

  @spec to_json(t()) :: [map()]
  def to_json({:ungrouped, options}),
    do: Enum.map(options, &SessionConfigSelectOption.to_json/1)

  def to_json({:grouped, groups}),
    do: Enum.map(groups, &SessionConfigSelectGroup.to_json/1)

  @doc "Total: never raises. Non-list input returns `{:error, _}`."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json([]), do: {:ok, {:ungrouped, []}}

  def from_json([first | _] = list) when is_list(list) and is_map(first) do
    if Map.has_key?(first, "group") do
      case AgentTypes.decode_list(list, &SessionConfigSelectGroup.from_json/1) do
        {:ok, groups} -> {:ok, {:grouped, groups}}
        error -> error
      end
    else
      case AgentTypes.decode_list(list, &SessionConfigSelectOption.from_json/1) do
        {:ok, options} -> {:ok, {:ungrouped, options}}
        error -> error
      end
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_options, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect do
  @moduledoc """
  A single-value selector (dropdown) session configuration option payload.
  (Unstable)

  Unlike its siblings this struct has no `_meta` of its own: it is never
  independently serialized on the wire, only flattened into its parent
  `SessionConfigOption`'s top-level JSON object (alongside `"type" =>
  "select"`), which is the one that owns the wire object's `_meta`
  catch-all.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOptions

  @type t :: %__MODULE__{
          current_value: term(),
          options: SessionConfigSelectOptions.t()
        }

  @enforce_keys [:current_value, :options]
  defstruct current_value: nil, options: nil

  @spec new(term(), SessionConfigSelectOptions.t()) :: t()
  def new(current_value, options),
    do: %__MODULE__{current_value: current_value, options: options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentValue" => s.current_value,
      "options" => SessionConfigSelectOptions.to_json(s.options)
    }
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_value} <- AgentTypes.fetch(map, "currentValue"),
         {:ok, raw_options} <- AgentTypes.fetch(map, "options"),
         {:ok, options} <- SessionConfigSelectOptions.from_json(raw_options) do
      {:ok, %__MODULE__{current_value: current_value, options: options}}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_config_select, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect

  def encode(%SessionConfigSelect{} = val, opts) do
    val |> SessionConfigSelect.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOptionCategory do
  @moduledoc """
  Semantic category for a session configuration option. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: :mode | :model | :thought_level | :other

  @spec to_json(t()) :: String.t()
  def to_json(:mode), do: "mode"
  def to_json(:model), do: "model"
  def to_json(:thought_level), do: "thought_level"
  def to_json(:other), do: "other"

  @doc """
  Total (always succeeds): any unrecognized wire string maps to `:other`,
  by design — this is a genuinely forward-compat field, not a defect fix.
  Still returns `{:ok, _}` for a uniform decode contract with the rest of
  this module.
  """
  @spec from_json(term()) :: {:ok, t()}
  def from_json("mode"), do: {:ok, :mode}
  def from_json("model"), do: {:ok, :model}
  def from_json("thought_level"), do: {:ok, :thought_level}
  def from_json(_other), do: {:ok, :other}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigKind do
  @moduledoc """
  Type-specific session configuration option payload: a tagged union by the
  wire `"type"` field. Currently only `:select` is defined by the spec.
  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect

  @type t :: {:select, SessionConfigSelect.t()}

  @spec to_json(t()) :: map()
  def to_json({:select, select}),
    do: Map.put(SessionConfigSelect.to_json(select), "type", "select")

  @doc """
  Total: never raises. An unrecognized `"type"` (upstream had no catch-all
  here) or a missing `"type"` key returns `{:error, _}`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "select"} = map) do
    case SessionConfigSelect.from_json(map) do
      {:ok, select} -> {:ok, {:select, select}}
      error -> error
    end
  end

  def from_json(%{"type" => other}),
    do: {:error, {:unsupported_session_config_kind, other}}

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "type"}}
  def from_json(other), do: {:error, {:invalid_session_config_kind, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption do
  @moduledoc """
  A session configuration option selector and its current state. The
  `kind`-specific payload (currently only `select`) is flattened directly
  into this struct's top-level wire object alongside `id`/`name`/etc.
  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigKind,
    SessionConfigOptionCategory
  }

  # "type"/"currentValue"/"options" are the flattened SessionConfigKind
  # payload fields, consumed at this level even though they belong to the
  # nested `kind`.
  @known_keys [
    "id",
    "name",
    "description",
    "category",
    "type",
    "currentValue",
    "options",
    "_meta"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          category: SessionConfigOptionCategory.t() | nil,
          kind: SessionConfigKind.t(),
          _meta: map()
        }

  @enforce_keys [:id, :name, :kind]
  defstruct id: nil,
            name: nil,
            description: nil,
            category: nil,
            kind: nil,
            _meta: %{}

  @spec new(String.t(), String.t(), SessionConfigKind.t()) :: t()
  def new(id, name, kind), do: %__MODULE__{id: id, name: name, kind: kind}

  @doc "Convenience: build a `select`-kind option directly."
  @spec select(String.t(), String.t(), term(), term()) :: t()
  def select(id, name, current_value, options) do
    alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect
    new(id, name, {:select, SessionConfigSelect.new(current_value, options)})
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = o) do
    SessionConfigKind.to_json(o.kind)
    |> Map.merge(%{"id" => o.id, "name" => o.name})
    |> AgentTypes.maybe_put("description", o.description)
    |> maybe_put_category(o.category)
    |> AgentTypes.put_meta(o._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- AgentTypes.fetch(map, "id"),
         {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, kind} <- SessionConfigKind.from_json(map),
         {:ok, category} <-
           AgentTypes.decode_optional(
             map,
             "category",
             &SessionConfigOptionCategory.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Map.get(map, "description"),
         category: category,
         kind: kind,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_config_option, other}}

  defp maybe_put_category(map, nil), do: map

  defp maybe_put_category(map, category) do
    Map.put(map, "category", SessionConfigOptionCategory.to_json(category))
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption

  def encode(%SessionConfigOption{} = val, opts) do
    val |> SessionConfigOption.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionRequest do
  @moduledoc """
  Request to set a session configuration option value
  (`session/set_config_option`). (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "configId", "value", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          config_id: String.t(),
          value: term(),
          _meta: map()
        }

  @enforce_keys [:session_id, :config_id, :value]
  defstruct session_id: nil, config_id: nil, value: nil, _meta: %{}

  @spec new(String.t(), String.t(), term()) :: t()
  def new(session_id, config_id, value) do
    %__MODULE__{session_id: session_id, config_id: config_id, value: value}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{
        "sessionId" => r.session_id,
        "configId" => r.config_id,
        "value" => r.value
      },
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, config_id} <- AgentTypes.fetch(map, "configId"),
         {:ok, value} <- AgentTypes.fetch(map, "value") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         config_id: config_id,
         value: value,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_config_option_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionRequest do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionRequest

  def encode(%SetSessionConfigOptionRequest{} = val, opts) do
    val |> SetSessionConfigOptionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionResponse do
  @moduledoc """
  Response to `session/set_config_option`: the full, refreshed set of config
  options. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption

  @known_keys ["configOptions", "_meta"]

  @type t :: %__MODULE__{
          config_options: [SessionConfigOption.t()],
          _meta: map()
        }

  @enforce_keys [:config_options]
  defstruct config_options: nil, _meta: %{}

  @spec new([SessionConfigOption.t()]) :: t()
  def new(config_options), do: %__MODULE__{config_options: config_options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(
      %{
        "configOptions" => Enum.map(r.config_options, &SessionConfigOption.to_json/1)
      },
      r._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_opts} <- AgentTypes.fetch(map, "configOptions"),
         {:ok, config_options} <-
           AgentTypes.decode_list(raw_opts, &SessionConfigOption.from_json/1) do
      {:ok,
       %__MODULE__{
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_set_session_config_option_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionResponse do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SetSessionConfigOptionResponse

  def encode(%SetSessionConfigOptionResponse{} = val, opts) do
    val |> SetSessionConfigOptionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Session Fork Types ----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionRequest do
  @moduledoc """
  Request to fork an existing session (`session/fork`). (Unstable)

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
  def new(session_id, cwd),
    do: %__MODULE__{session_id: session_id, cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "cwd" => r.cwd}
    |> maybe_put_mcp_servers(r.mcp_servers)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(
             Map.get(map, "mcpServers", []),
             &McpServer.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_fork_session_request, other}}

  defp maybe_put_mcp_servers(map, nil), do: map
  defp maybe_put_mcp_servers(map, []), do: map

  defp maybe_put_mcp_servers(map, servers) do
    Map.put(map, "mcpServers", Enum.map(servers, &McpServer.to_json/1))
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionRequest

  def encode(%ForkSessionRequest{} = val, opts) do
    val |> ForkSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionResponse do
  @moduledoc """
  Response from forking a session: the new session id plus optional
  mode/model/config-option state. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigOption,
    SessionModelState
  }

  @known_keys ["sessionId", "modes", "models", "configOptions", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          modes: SessionModeState.t() | nil,
          models: SessionModelState.t() | nil,
          config_options: [SessionConfigOption.t()] | nil,
          _meta: map()
        }

  @enforce_keys [:session_id]
  defstruct session_id: nil,
            modes: nil,
            models: nil,
            config_options: nil,
            _meta: %{}

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
         {:ok, modes} <-
           AgentTypes.decode_optional(
             map,
             "modes",
             &SessionModeState.from_json/1
           ),
         {:ok, models} <-
           AgentTypes.decode_optional(
             map,
             "models",
             &SessionModelState.from_json/1
           ),
         {:ok, config_options} <-
           decode_config_options(Map.get(map, "configOptions")) do
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

  def from_json(other), do: {:error, {:invalid_fork_session_response, other}}

  defp decode_config_options(nil), do: {:ok, nil}

  defp decode_config_options(opts),
    do: AgentTypes.decode_list(opts, &SessionConfigOption.from_json/1)

  defp maybe_put_modes(map, nil), do: map

  defp maybe_put_modes(map, modes),
    do: Map.put(map, "modes", SessionModeState.to_json(modes))

  defp maybe_put_models(map, nil), do: map

  defp maybe_put_models(map, models),
    do: Map.put(map, "models", SessionModelState.to_json(models))

  defp maybe_put_config_options(map, nil), do: map

  defp maybe_put_config_options(map, opts) do
    Map.put(
      map,
      "configOptions",
      Enum.map(opts, &SessionConfigOption.to_json/1)
    )
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ForkSessionResponse

  def encode(%ForkSessionResponse{} = val, opts) do
    val |> ForkSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Session Resume Types --------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionRequest do
  @moduledoc """
  Request to resume an existing session without replaying its history
  (`session/resume`). (Unstable)

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
  def new(session_id, cwd),
    do: %__MODULE__{session_id: session_id, cwd: cwd, mcp_servers: []}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "cwd" => r.cwd}
    |> maybe_put_mcp_servers(r.mcp_servers)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd"),
         {:ok, mcp_servers} <-
           AgentTypes.decode_list(
             Map.get(map, "mcpServers", []),
             &McpServer.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         mcp_servers: mcp_servers,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_resume_session_request, other}}

  defp maybe_put_mcp_servers(map, nil), do: map
  defp maybe_put_mcp_servers(map, []), do: map

  defp maybe_put_mcp_servers(map, servers) do
    Map.put(map, "mcpServers", Enum.map(servers, &McpServer.to_json/1))
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionRequest

  def encode(%ResumeSessionRequest{} = val, opts) do
    val |> ResumeSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionResponse do
  @moduledoc """
  Response from resuming a session: optional mode/model/config-option state.
  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.SessionModeState

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigOption,
    SessionModelState
  }

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
    with {:ok, modes} <-
           AgentTypes.decode_optional(
             map,
             "modes",
             &SessionModeState.from_json/1
           ),
         {:ok, models} <-
           AgentTypes.decode_optional(
             map,
             "models",
             &SessionModelState.from_json/1
           ),
         {:ok, config_options} <-
           decode_config_options(Map.get(map, "configOptions")) do
      {:ok,
       %__MODULE__{
         modes: modes,
         models: models,
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_resume_session_response, other}}

  defp decode_config_options(nil), do: {:ok, nil}

  defp decode_config_options(opts),
    do: AgentTypes.decode_list(opts, &SessionConfigOption.from_json/1)

  defp maybe_put_modes(map, nil), do: map

  defp maybe_put_modes(map, modes),
    do: Map.put(map, "modes", SessionModeState.to_json(modes))

  defp maybe_put_models(map, nil), do: map

  defp maybe_put_models(map, models),
    do: Map.put(map, "models", SessionModelState.to_json(models))

  defp maybe_put_config_options(map, nil), do: map

  defp maybe_put_config_options(map, opts) do
    Map.put(
      map,
      "configOptions",
      Enum.map(opts, &SessionConfigOption.to_json/1)
    )
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ResumeSessionResponse

  def encode(%ResumeSessionResponse{} = val, opts) do
    val |> ResumeSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Session List Types -----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo do
  @moduledoc """
  Information about a session returned by `session/list`. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "cwd", "title", "updatedAt", "_meta"]

  @type t :: %__MODULE__{
          session_id: String.t(),
          cwd: String.t(),
          title: String.t() | nil,
          updated_at: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:session_id, :cwd]
  defstruct session_id: nil, cwd: nil, title: nil, updated_at: nil, _meta: %{}

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, cwd), do: %__MODULE__{session_id: session_id, cwd: cwd}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{"sessionId" => s.session_id, "cwd" => s.cwd}
    |> AgentTypes.maybe_put("title", s.title)
    |> AgentTypes.maybe_put("updatedAt", s.updated_at)
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, cwd} <- AgentTypes.fetch(map, "cwd") do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         cwd: cwd,
         title: Map.get(map, "title"),
         updated_at: Map.get(map, "updatedAt"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_info, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo

  def encode(%SessionInfo{} = val, opts) do
    val |> SessionInfo.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsRequest do
  @moduledoc """
  Request to list existing sessions (`session/list`). (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["cwd", "cursor", "_meta"]

  @type t :: %__MODULE__{
          cwd: String.t() | nil,
          cursor: String.t() | nil,
          _meta: map()
        }

  defstruct cwd: nil, cursor: nil, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{}
    |> AgentTypes.maybe_put("cwd", r.cwd)
    |> AgentTypes.maybe_put("cursor", r.cursor)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       cwd: Map.get(map, "cwd"),
       cursor: Map.get(map, "cursor"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_list_sessions_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsRequest do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsRequest

  def encode(%ListSessionsRequest{} = val, opts) do
    val |> ListSessionsRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsResponse do
  @moduledoc """
  Response from listing sessions. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfo

  @known_keys ["sessions", "nextCursor", "_meta"]

  @type t :: %__MODULE__{
          sessions: [SessionInfo.t()],
          next_cursor: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:sessions]
  defstruct sessions: nil, next_cursor: nil, _meta: %{}

  @spec new([SessionInfo.t()]) :: t()
  def new(sessions), do: %__MODULE__{sessions: sessions}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessions" => Enum.map(r.sessions, &SessionInfo.to_json/1)}
    |> maybe_put_next_cursor(r.next_cursor)
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, raw_sessions} <- AgentTypes.fetch(map, "sessions"),
         {:ok, sessions} <-
           AgentTypes.decode_list(raw_sessions, &SessionInfo.from_json/1) do
      {:ok,
       %__MODULE__{
         sessions: sessions,
         next_cursor: Map.get(map, "nextCursor"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_list_sessions_response, other}}

  defp maybe_put_next_cursor(map, nil), do: map

  defp maybe_put_next_cursor(map, cursor),
    do: Map.put(map, "nextCursor", cursor)
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsResponse do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ListSessionsResponse

  def encode(%ListSessionsResponse{} = val, opts) do
    val |> ListSessionsResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Session Capabilities (Unstable) ----------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities do
  @moduledoc """
  Capability flag for `session/list`. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_list_capabilities, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionListCapabilities

  def encode(%SessionListCapabilities{} = val, opts) do
    val |> SessionListCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionForkCapabilities do
  @moduledoc """
  Capability flag for `session/fork`. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_fork_capabilities, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionForkCapabilities do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionForkCapabilities

  def encode(%SessionForkCapabilities{} = val, opts) do
    val |> SessionForkCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities do
  @moduledoc """
  Capability flag for `session/resume`. (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c), do: AgentTypes.put_meta(%{}, c._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other),
    do: {:error, {:invalid_session_resume_capabilities, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionResumeCapabilities

  def encode(%SessionResumeCapabilities{} = val, opts) do
    val |> SessionResumeCapabilities.to_json() |> Jason.Encode.map(opts)
  end
end

# -- Client-Side Unstable Types (SessionUpdate variant payloads) -----------------

defmodule Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate do
  @moduledoc """
  Payload for the `session/update` notification's `config_option_update`
  variant: session configuration options have been updated. The variant
  wiring itself lives in `SessionUpdate` (ported from `client_types.ex`, not
  this file). (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption

  @known_keys ["configOptions", "_meta"]

  @type t :: %__MODULE__{
          config_options: [SessionConfigOption.t()],
          _meta: map()
        }

  @enforce_keys [:config_options]
  defstruct config_options: nil, _meta: %{}

  @spec new([SessionConfigOption.t()]) :: t()
  def new(config_options), do: %__MODULE__{config_options: config_options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = c) do
    AgentTypes.put_meta(
      %{
        "configOptions" => Enum.map(c.config_options, &SessionConfigOption.to_json/1)
      },
      c._meta
    )
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, config_options} <-
           AgentTypes.decode_list(
             Map.get(map, "configOptions", []),
             &SessionConfigOption.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         config_options: config_options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_config_option_update, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate do
  alias Raxol.AgentClientProtocol.Schema.Unstable.ConfigOptionUpdate

  def encode(%ConfigOptionUpdate{} = val, opts) do
    val |> ConfigOptionUpdate.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate do
  @moduledoc """
  Payload for the `session/update` notification's `session_info_update`
  variant: a partial update to session metadata. The variant wiring itself
  lives in `SessionUpdate` (ported from `client_types.ex`, not this file).

  Uses `Raxol.AgentClientProtocol.Schema.MaybeUndefined` for its fields to
  support partial-update semantics:

    * `:undefined` — field not included on the wire (no change)
    * `nil` — explicitly `null` on the wire (clear the value)
    * `{:value, v}` — set to `v`

  (Unstable)

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.MaybeUndefined

  @known_keys ["title", "updatedAt", "_meta"]

  @type t :: %__MODULE__{
          title: MaybeUndefined.t(String.t()),
          updated_at: MaybeUndefined.t(String.t()),
          _meta: map()
        }

  defstruct title: :undefined, updated_at: :undefined, _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{}
    |> maybe_put_maybe_undefined("title", s.title)
    |> maybe_put_maybe_undefined("updatedAt", s.updated_at)
    |> AgentTypes.put_meta(s._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       title: decode_maybe_undefined(map, "title"),
       updated_at: decode_maybe_undefined(map, "updatedAt"),
       _meta: AgentTypes.extract_meta(map, @known_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_session_info_update, other}}

  defp decode_maybe_undefined(map, key) do
    if Map.has_key?(map, key) do
      MaybeUndefined.from_json(Map.get(map, key))
    else
      :undefined
    end
  end

  defp maybe_put_maybe_undefined(map, key, value) do
    case MaybeUndefined.to_json(value) do
      {:skip} -> map
      v -> Map.put(map, key, v)
    end
  end
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate do
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionInfoUpdate

  def encode(%SessionInfoUpdate{} = val, opts) do
    val |> SessionInfoUpdate.to_json() |> Jason.Encode.map(opts)
  end
end
