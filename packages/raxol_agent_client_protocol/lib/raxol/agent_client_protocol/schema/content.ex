defmodule Raxol.AgentClientProtocol.Schema.WireFields do
  @moduledoc false
  # Shared decode/encode helpers for the ACP schema layer (Content, Plan,
  # ToolCall and friends). These are NOT ported from upstream f1729 -- they
  # are new glue code implementing the total-decode + forward-compat
  # defect fixes uniformly across every schema struct in this namespace.
  #
  # Leniency here mirrors the official ACP JSON Schema's own
  # `x-deserialize-default-on-error` / `x-deserialize-skip-invalid-items`
  # vendor extensions (see `priv/schema-oracle/v1/schema.json`): optional
  # fields fall back to their absent value on a decode error instead of
  # failing the whole object, and list items that fail to decode are
  # skipped rather than aborting the whole list. Required fields still make
  # the *enclosing* object's decode fail.

  @doc """
  Split a raw wire map into its `_meta` bucket: the wire object's own
  `"_meta"` map (if any) merged with any top-level field the caller didn't
  recognize (`known_keys`). Nothing is ever silently dropped; re-emit via
  `emit_meta/2` on encode.
  """
  @spec fold_meta(map(), [String.t()]) :: map()
  def fold_meta(map, known_keys) when is_map(map) and is_list(known_keys) do
    extras = map |> Map.drop(known_keys) |> Map.drop(["_meta"])
    Map.merge(meta_of(map), extras)
  end

  defp meta_of(%{"_meta" => meta}) when is_map(meta), do: meta
  defp meta_of(_map), do: %{}

  @doc "Re-emit a struct's `_meta` bucket under the wire `\"_meta\"` key, omitted when empty."
  @spec emit_meta(map(), map()) :: map()
  def emit_meta(json, meta) when map_size(meta) == 0, do: json
  def emit_meta(json, meta) when is_map(meta), do: Map.put(json, "_meta", meta)

  @doc "Put `key => value` unless `value` is `nil` (nil fields are omitted, never emitted as `null`)."
  @spec put(map(), String.t(), term()) :: map()
  def put(json, _key, nil), do: json
  def put(json, key, value), do: Map.put(json, key, value)

  @doc """
  Fetch a required field. A missing key, or a present value failing
  `valid?`, returns a descriptive `{:error, _}` instead of raising -- the
  caller's `from_json` propagates this via `with`, failing the whole object.
  """
  @spec require(map(), String.t(), (term() -> boolean())) ::
          {:ok, term()}
          | {:error, {:missing_field, String.t()} | {:invalid_field, String.t(), term()}}
  def require(map, key, valid?) do
    case Map.fetch(map, key) do
      :error -> {:error, {:missing_field, key}}
      {:ok, value} -> require_valid(key, value, valid?)
    end
  end

  defp require_valid(key, value, valid?) do
    if valid?.(value) do
      {:ok, value}
    else
      {:error, {:invalid_field, key, value}}
    end
  end

  @doc """
  Fetch an optional field, defaulting to `nil` when the key is absent or the
  value fails `valid?` (the "default on error" leniency the official schema
  documents for optional scalar fields).
  """
  @spec optional(map(), String.t(), (term() -> boolean())) :: term() | nil
  def optional(map, key, valid?) do
    case Map.get(map, key) do
      nil -> nil
      value -> optional_valid(value, valid?)
    end
  end

  defp optional_valid(value, valid?) do
    if valid?.(value), do: value, else: nil
  end

  @doc """
  Fetch and decode an optional nested object, defaulting to `nil` when the
  key is absent or `decoder` returns `{:error, _}` (same "default on error"
  leniency, for fields whose value is itself another ACP schema object).
  """
  @spec optional_nested(map(), String.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          term() | nil
  def optional_nested(map, key, decoder) do
    case Map.get(map, key) do
      nil -> nil
      value -> unwrap_or_nil(decoder.(value))
    end
  end

  defp unwrap_or_nil({:ok, value}), do: value
  defp unwrap_or_nil({:error, _reason}), do: nil

  @doc """
  Decode a wire array leniently: items that fail `decoder` are skipped
  rather than aborting the whole list, and a missing/non-list value falls
  back to `default` (matches the schema's combined
  `x-deserialize-default-on-error` + `x-deserialize-skip-invalid-items`).
  """
  @spec list_lenient(term(), (term() -> {:ok, term()} | {:error, term()}), term()) :: term()
  def list_lenient(list, decoder, _default) when is_list(list) do
    Enum.flat_map(list, fn item ->
      case decoder.(item) do
        {:ok, value} -> [value]
        {:error, _reason} -> []
      end
    end)
  end

  def list_lenient(_not_a_list, _decoder, default), do: default
end

defmodule Raxol.AgentClientProtocol.Schema.Role do
  @moduledoc """
  The sender or recipient of messages and data in a conversation.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @type t :: :assistant | :user

  @spec encode(t()) :: String.t()
  def encode(:assistant), do: "assistant"
  def encode(:user), do: "user"

  @doc "Total: an unrecognized role string returns `{:error, _}` rather than raising."
  @spec decode(term()) :: {:ok, t()} | {:error, {:invalid_role, term()}}
  def decode("assistant"), do: {:ok, :assistant}
  def decode("user"), do: {:ok, :user}
  def decode(other), do: {:error, {:invalid_role, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Annotations do
  @moduledoc """
  Optional annotations for the client (audience, priority, last-modified).
  Every field is optional and decode-lenient: a malformed value defaults to
  absent rather than failing the whole `Annotations`.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Role
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          audience: [Role.t()] | nil,
          last_modified: String.t() | nil,
          priority: float() | nil,
          _meta: map()
        }

  defstruct audience: nil, last_modified: nil, priority: nil, _meta: %{}

  @known_wire_keys ~w(audience lastModified priority)

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = a) do
    %{}
    |> WireFields.put("audience", encode_audience(a.audience))
    |> WireFields.put("lastModified", a.last_modified)
    |> WireFields.put("priority", a.priority)
    |> WireFields.emit_meta(a._meta)
  end

  defp encode_audience(nil), do: nil
  defp encode_audience(audience), do: Enum.map(audience, &Role.encode/1)

  @doc "Total: never raises. Malformed optional fields default to absent (never fail the whole object)."
  @spec from_json(term()) :: {:ok, t()} | {:error, {:invalid_annotations, term()}}
  def from_json(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       audience: WireFields.list_lenient(Map.get(map, "audience"), &Role.decode/1, nil),
       last_modified: WireFields.optional(map, "lastModified", &is_binary/1),
       priority: WireFields.optional(map, "priority", &is_number/1),
       _meta: WireFields.fold_meta(map, @known_wire_keys)
     }}
  end

  def from_json(other), do: {:error, {:invalid_annotations, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Annotations do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.Annotations.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.TextContent do
  @moduledoc """
  Text provided to or from an LLM.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          annotations: Annotations.t() | nil,
          text: String.t(),
          _meta: map()
        }

  @enforce_keys [:text]
  defstruct [:text, annotations: nil, _meta: %{}]

  @known_wire_keys ~w(text annotations)

  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: %__MODULE__{text: text}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = tc) do
    %{"text" => tc.text}
    |> WireFields.put("annotations", encode_annotations(tc.annotations))
    |> WireFields.emit_meta(tc._meta)
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(annotations), do: Annotations.to_json(annotations)

  @doc "Total: never raises. A missing/non-string `text` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, text} <- WireFields.require(map, "text", &is_binary/1) do
      {:ok,
       %__MODULE__{
         text: text,
         annotations: WireFields.optional_nested(map, "annotations", &Annotations.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_text_content, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.TextContent do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.TextContent.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ImageContent do
  @moduledoc """
  An image provided to or from an LLM.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          annotations: Annotations.t() | nil,
          data: String.t(),
          mime_type: String.t(),
          uri: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:data, :mime_type]
  defstruct [:data, :mime_type, annotations: nil, uri: nil, _meta: %{}]

  @known_wire_keys ~w(data mimeType annotations uri)

  @spec new(String.t(), String.t()) :: t()
  def new(data, mime_type) when is_binary(data) and is_binary(mime_type) do
    %__MODULE__{data: data, mime_type: mime_type}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = ic) do
    %{"data" => ic.data, "mimeType" => ic.mime_type}
    |> WireFields.put("annotations", encode_annotations(ic.annotations))
    |> WireFields.put("uri", ic.uri)
    |> WireFields.emit_meta(ic._meta)
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(annotations), do: Annotations.to_json(annotations)

  @doc "Total: never raises. Missing/non-string `data` or `mimeType` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, data} <- WireFields.require(map, "data", &is_binary/1),
         {:ok, mime_type} <- WireFields.require(map, "mimeType", &is_binary/1) do
      {:ok,
       %__MODULE__{
         data: data,
         mime_type: mime_type,
         annotations: WireFields.optional_nested(map, "annotations", &Annotations.from_json/1),
         uri: WireFields.optional(map, "uri", &is_binary/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_image_content, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ImageContent do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ImageContent.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.AudioContent do
  @moduledoc """
  Audio provided to or from an LLM.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          annotations: Annotations.t() | nil,
          data: String.t(),
          mime_type: String.t(),
          _meta: map()
        }

  @enforce_keys [:data, :mime_type]
  defstruct [:data, :mime_type, annotations: nil, _meta: %{}]

  @known_wire_keys ~w(data mimeType annotations)

  @spec new(String.t(), String.t()) :: t()
  def new(data, mime_type) when is_binary(data) and is_binary(mime_type) do
    %__MODULE__{data: data, mime_type: mime_type}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = ac) do
    %{"data" => ac.data, "mimeType" => ac.mime_type}
    |> WireFields.put("annotations", encode_annotations(ac.annotations))
    |> WireFields.emit_meta(ac._meta)
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(annotations), do: Annotations.to_json(annotations)

  @doc "Total: never raises. Missing/non-string `data` or `mimeType` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, data} <- WireFields.require(map, "data", &is_binary/1),
         {:ok, mime_type} <- WireFields.require(map, "mimeType", &is_binary/1) do
      {:ok,
       %__MODULE__{
         data: data,
         mime_type: mime_type,
         annotations: WireFields.optional_nested(map, "annotations", &Annotations.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_audio_content, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.AudioContent do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.AudioContent.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.TextResourceContents do
  @moduledoc """
  Text-based resource contents.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          mime_type: String.t() | nil,
          text: String.t(),
          uri: String.t(),
          _meta: map()
        }

  @enforce_keys [:text, :uri]
  defstruct [:text, :uri, mime_type: nil, _meta: %{}]

  @known_wire_keys ~w(text uri mimeType)

  @spec new(String.t(), String.t()) :: t()
  def new(text, uri) when is_binary(text) and is_binary(uri) do
    %__MODULE__{text: text, uri: uri}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = trc) do
    %{"text" => trc.text, "uri" => trc.uri}
    |> WireFields.put("mimeType", trc.mime_type)
    |> WireFields.emit_meta(trc._meta)
  end

  @doc "Total: never raises. Missing/non-string `text` or `uri` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, text} <- WireFields.require(map, "text", &is_binary/1),
         {:ok, uri} <- WireFields.require(map, "uri", &is_binary/1) do
      {:ok,
       %__MODULE__{
         text: text,
         uri: uri,
         mime_type: WireFields.optional(map, "mimeType", &is_binary/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_text_resource_contents, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.TextResourceContents do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.TextResourceContents.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.BlobResourceContents do
  @moduledoc """
  Binary resource contents.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          blob: String.t(),
          mime_type: String.t() | nil,
          uri: String.t(),
          _meta: map()
        }

  @enforce_keys [:blob, :uri]
  defstruct [:blob, :uri, mime_type: nil, _meta: %{}]

  @known_wire_keys ~w(blob uri mimeType)

  @spec new(String.t(), String.t()) :: t()
  def new(blob, uri) when is_binary(blob) and is_binary(uri) do
    %__MODULE__{blob: blob, uri: uri}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = brc) do
    %{"blob" => brc.blob, "uri" => brc.uri}
    |> WireFields.put("mimeType", brc.mime_type)
    |> WireFields.emit_meta(brc._meta)
  end

  @doc "Total: never raises. Missing/non-string `blob` or `uri` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, blob} <- WireFields.require(map, "blob", &is_binary/1),
         {:ok, uri} <- WireFields.require(map, "uri", &is_binary/1) do
      {:ok,
       %__MODULE__{
         blob: blob,
         uri: uri,
         mime_type: WireFields.optional(map, "mimeType", &is_binary/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_blob_resource_contents, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.BlobResourceContents do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.BlobResourceContents.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.EmbeddedResourceResource do
  @moduledoc """
  Resource content that can be embedded in a message (untagged union,
  discriminated by the presence of a `"text"` or `"blob"` wire key).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.BlobResourceContents
  alias Raxol.AgentClientProtocol.Schema.TextResourceContents

  @type t :: TextResourceContents.t() | BlobResourceContents.t()

  @spec to_json(t()) :: map()
  def to_json(%TextResourceContents{} = trc), do: TextResourceContents.to_json(trc)
  def to_json(%BlobResourceContents{} = brc), do: BlobResourceContents.to_json(brc)

  @doc """
  Total: never raises. A map lacking both `"text"` and `"blob"` (so the
  variant can't be discriminated) returns `{:error, :ambiguous_resource}`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"text" => _} = map), do: TextResourceContents.from_json(map)
  def from_json(%{"blob" => _} = map), do: BlobResourceContents.from_json(map)
  def from_json(map) when is_map(map), do: {:error, :ambiguous_resource}
  def from_json(other), do: {:error, {:invalid_embedded_resource_resource, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.EmbeddedResource do
  @moduledoc """
  The contents of a resource, embedded into a prompt or tool call result.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.EmbeddedResourceResource
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          annotations: Annotations.t() | nil,
          resource: EmbeddedResourceResource.t(),
          _meta: map()
        }

  @enforce_keys [:resource]
  defstruct [:resource, annotations: nil, _meta: %{}]

  @known_wire_keys ~w(resource annotations)

  @spec new(EmbeddedResourceResource.t()) :: t()
  def new(resource), do: %__MODULE__{resource: resource}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = er) do
    %{"resource" => EmbeddedResourceResource.to_json(er.resource)}
    |> WireFields.put("annotations", encode_annotations(er.annotations))
    |> WireFields.emit_meta(er._meta)
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(annotations), do: Annotations.to_json(annotations)

  @doc "Total: never raises. A missing/unparseable `resource` is the only failure mode (required field)."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"resource" => resource_map} = map) do
    with {:ok, resource} <- EmbeddedResourceResource.from_json(resource_map) do
      {:ok,
       %__MODULE__{
         resource: resource,
         annotations: WireFields.optional_nested(map, "annotations", &Annotations.from_json/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "resource"}}
  def from_json(other), do: {:error, {:invalid_embedded_resource, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.EmbeddedResource do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.EmbeddedResource.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ResourceLink do
  @moduledoc """
  A resource that the server is capable of reading.

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.Annotations
  alias Raxol.AgentClientProtocol.Schema.WireFields

  @type t :: %__MODULE__{
          annotations: Annotations.t() | nil,
          description: String.t() | nil,
          mime_type: String.t() | nil,
          name: String.t(),
          size: integer() | nil,
          title: String.t() | nil,
          uri: String.t(),
          _meta: map()
        }

  @enforce_keys [:name, :uri]
  defstruct [
    :name,
    :uri,
    annotations: nil,
    description: nil,
    mime_type: nil,
    size: nil,
    title: nil,
    _meta: %{}
  ]

  @known_wire_keys ~w(name uri annotations description mimeType size title)

  @spec new(String.t(), String.t()) :: t()
  def new(name, uri) when is_binary(name) and is_binary(uri) do
    %__MODULE__{name: name, uri: uri}
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = rl) do
    %{"name" => rl.name, "uri" => rl.uri}
    |> WireFields.put("annotations", encode_annotations(rl.annotations))
    |> WireFields.put("description", rl.description)
    |> WireFields.put("mimeType", rl.mime_type)
    |> WireFields.put("size", rl.size)
    |> WireFields.put("title", rl.title)
    |> WireFields.emit_meta(rl._meta)
  end

  defp encode_annotations(nil), do: nil
  defp encode_annotations(annotations), do: Annotations.to_json(annotations)

  @doc "Total: never raises. Missing/non-string `name` or `uri` is the only failure mode."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, name} <- WireFields.require(map, "name", &is_binary/1),
         {:ok, uri} <- WireFields.require(map, "uri", &is_binary/1) do
      {:ok,
       %__MODULE__{
         name: name,
         uri: uri,
         annotations: WireFields.optional_nested(map, "annotations", &Annotations.from_json/1),
         description: WireFields.optional(map, "description", &is_binary/1),
         mime_type: WireFields.optional(map, "mimeType", &is_binary/1),
         size: WireFields.optional(map, "size", &is_integer/1),
         title: WireFields.optional(map, "title", &is_binary/1),
         _meta: WireFields.fold_meta(map, @known_wire_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_resource_link, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.ResourceLink do
  def encode(val, opts) do
    val
    |> Raxol.AgentClientProtocol.Schema.ResourceLink.to_json()
    |> Jason.Encoder.encode(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.ContentBlock do
  @moduledoc """
  Content blocks represent displayable information in ACP: a tagged union
  discriminated by a `"type"` wire key (`text` | `image` | `audio` |
  `resource_link` | `resource`). Named `ContentBlock` both upstream and
  here (all other structs ported from `content.ex` -- `Role`, `Annotations`,
  `TextContent`, `ImageContent`, `AudioContent`, `TextResourceContents`,
  `BlobResourceContents`, `EmbeddedResourceResource`, `EmbeddedResource`,
  `ResourceLink` -- are separate, bare `Schema.*` modules, not nested under
  this one).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  alias Raxol.AgentClientProtocol.Schema.AudioContent
  alias Raxol.AgentClientProtocol.Schema.EmbeddedResource
  alias Raxol.AgentClientProtocol.Schema.ImageContent
  alias Raxol.AgentClientProtocol.Schema.ResourceLink
  alias Raxol.AgentClientProtocol.Schema.TextContent

  @type t ::
          {:text, TextContent.t()}
          | {:image, ImageContent.t()}
          | {:audio, AudioContent.t()}
          | {:resource_link, ResourceLink.t()}
          | {:resource, EmbeddedResource.t()}

  @spec text(TextContent.t()) :: t()
  def text(text_content), do: {:text, text_content}

  @spec image(ImageContent.t()) :: t()
  def image(image_content), do: {:image, image_content}

  @spec audio(AudioContent.t()) :: t()
  def audio(audio_content), do: {:audio, audio_content}

  @spec resource_link(ResourceLink.t()) :: t()
  def resource_link(rl), do: {:resource_link, rl}

  @spec resource(EmbeddedResource.t()) :: t()
  def resource(er), do: {:resource, er}

  @doc "Convenience: create a text content block from a plain string."
  @spec from_string(String.t()) :: t()
  def from_string(text) when is_binary(text), do: {:text, TextContent.new(text)}

  @spec to_json(t()) :: map()
  def to_json({:text, tc}), do: Map.put(TextContent.to_json(tc), "type", "text")
  def to_json({:image, ic}), do: Map.put(ImageContent.to_json(ic), "type", "image")
  def to_json({:audio, ac}), do: Map.put(AudioContent.to_json(ac), "type", "audio")

  def to_json({:resource_link, rl}) do
    Map.put(ResourceLink.to_json(rl), "type", "resource_link")
  end

  def to_json({:resource, er}), do: Map.put(EmbeddedResource.to_json(er), "type", "resource")

  @doc """
  Total: never raises. An unrecognized/missing `"type"`, or a variant body
  that fails to decode, returns `{:error, _}` (a content block has no
  documented default variant, unlike e.g. `ToolCall.ToolKind`).
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "text"} = map) do
    with {:ok, tc} <- TextContent.from_json(Map.delete(map, "type")), do: {:ok, {:text, tc}}
  end

  def from_json(%{"type" => "image"} = map) do
    with {:ok, ic} <- ImageContent.from_json(Map.delete(map, "type")), do: {:ok, {:image, ic}}
  end

  def from_json(%{"type" => "audio"} = map) do
    with {:ok, ac} <- AudioContent.from_json(Map.delete(map, "type")), do: {:ok, {:audio, ac}}
  end

  def from_json(%{"type" => "resource_link"} = map) do
    with {:ok, rl} <- ResourceLink.from_json(Map.delete(map, "type")) do
      {:ok, {:resource_link, rl}}
    end
  end

  def from_json(%{"type" => "resource"} = map) do
    with {:ok, er} <- EmbeddedResource.from_json(Map.delete(map, "type")) do
      {:ok, {:resource, er}}
    end
  end

  def from_json(%{"type" => other_type}), do: {:error, {:unknown_content_block_type, other_type}}
  def from_json(map) when is_map(map), do: {:error, {:missing_field, "type"}}
  def from_json(other), do: {:error, {:invalid_content_block, other}}
end
