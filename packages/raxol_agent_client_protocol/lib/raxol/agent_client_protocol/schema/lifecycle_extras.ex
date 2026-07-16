defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras do
  @moduledoc """
  Minimal, oracle-derived param/result structs for v1.19.0 ACP methods that
  had no home in the ported f1729 `Schema.*` layer: `session/close`,
  `session/delete`, `logout`, `session/update` (the notification envelope),
  and the protocol-level `$/cancel_request`.

  Unlike the sibling `agent_types.ex`/`client_types.ex`/`unstable.ex` files,
  these are **not** ports of an upstream f1729 module (f1729 predates
  `schema-v1.19.0` and never had these types) — they are read directly off
  `priv/schema-oracle/v1/schema.json`'s `$defs` for `CloseSessionRequest`,
  `CloseSessionResponse`, `DeleteSessionRequest`, `DeleteSessionResponse`,
  `LogoutResponse`, `SessionNotification`, and `CancelRequestNotification`.
  No upstream MIT attribution applies to this file.

  Every struct here follows the same total-decode + `_meta` pass-through
  convention as the rest of the package, reusing the shared decode helpers
  from `Raxol.AgentClientProtocol.Schema.AgentTypes` (`fetch/2`,
  `decode_optional/3`, `extract_meta/2`, `put_meta/2`) exactly as
  `Schema.Unstable` does. `from_json/1` never raises; it always returns
  `{:ok, t}` or `{:error, reason}`.

  ## `LogoutRequest` is intentionally NOT ported here

  `priv/schema-oracle/v1/schema.json`'s `LogoutRequest` def carries no
  properties beyond the universal `_meta` envelope. The `logout` row in
  `Raxol.AgentClientProtocol.MethodTable` declares `params: nil` for exactly
  this reason (see the MethodTable design doc's D1-6 fix and its own
  `logout` example) — the Router decodes `nil` straight through and the
  generated callback drops to arity 1 (`ctx` only, no params argument), so
  there is no `from_json/1` call site that would ever receive a
  `LogoutRequest` struct. `LogoutResponse` IS ported below because
  `logout` is a `:request`-kind row and every request row needs a non-nil
  `result` module regardless of whether its params are decoded.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate
  alias Raxol.AgentClientProtocol.Rpc.RequestId
end

# -- CloseSessionRequest / CloseSessionResponse ------------------------------

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest do
  @moduledoc """
  Request parameters for `session/close`: closes an active session, best-
  effort cancelling any in-flight work first. Oracle-derived (schema.json
  `CloseSessionRequest`); not a port of any upstream f1729 module.
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

  def from_json(other), do: {:error, {:invalid_close_session_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest

  def encode(%CloseSessionRequest{} = val, opts) do
    val |> CloseSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/close`. Oracle-derived
  (schema.json `CloseSessionResponse`).
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

  def from_json(other), do: {:error, {:invalid_close_session_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse

  def encode(%CloseSessionResponse{} = val, opts) do
    val |> CloseSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- DeleteSessionRequest / DeleteSessionResponse ----------------------------

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest do
  @moduledoc """
  Request parameters for `session/delete`: deletes an existing session from
  `session/list`. Oracle-derived (schema.json `DeleteSessionRequest`); not a
  port of any upstream f1729 module.
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

  def from_json(other), do: {:error, {:invalid_delete_session_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest

  def encode(%DeleteSessionRequest{} = val, opts) do
    val |> DeleteSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/delete`. Oracle-derived
  (schema.json `DeleteSessionResponse`).
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

  def from_json(other), do: {:error, {:invalid_delete_session_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse

  def encode(%DeleteSessionResponse{} = val, opts) do
    val |> DeleteSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- LogoutResponse -----------------------------------------------------------

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `logout`. Oracle-derived
  (schema.json `LogoutResponse`). See the module doc above for why there is
  no sibling `LogoutRequest` in this file.
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

  def from_json(other), do: {:error, {:invalid_logout_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse

  def encode(%LogoutResponse{} = val, opts) do
    val |> LogoutResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# -- SessionNotification (session/update envelope) ---------------------------

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification do
  @moduledoc """
  The `session/update` notification envelope: `{sessionId, update, _meta}`,
  where `update` is the `Raxol.AgentClientProtocol.Schema.SessionUpdate`
  discriminated union (ported separately, `session_update.ex`).
  Oracle-derived (schema.json `SessionNotification`); not a port of any
  upstream f1729 module — upstream's `ACP.SessionNotification` envelope was
  explicitly left unported by `agent_types.ex`'s and `session_update.ex`'s
  own moduledocs pending whoever wired the routing union it belongs to.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  @known_keys ["sessionId", "update", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), update: SessionUpdate.t(), _meta: map()}

  @enforce_keys [:session_id, :update]
  defstruct session_id: nil, update: nil, _meta: %{}

  @spec new(String.t(), SessionUpdate.t()) :: t()
  def new(session_id, update), do: %__MODULE__{session_id: session_id, update: update}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "update" => SessionUpdate.to_json(r.update)}
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId"),
         {:ok, raw_update} <- AgentTypes.fetch(map, "update"),
         {:ok, update} <- SessionUpdate.from_json(raw_update) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         update: update,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_notification, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  def encode(%SessionNotification{} = val, opts) do
    val |> SessionNotification.to_json() |> Jason.Encode.map(opts)
  end
end

# -- CancelRequestNotification ($/cancel_request) ----------------------------

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification do
  @moduledoc """
  The protocol-level `$/cancel_request` notification: `{requestId, _meta}`,
  where `requestId` is a JSON-RPC request id (`null | integer | string`,
  see `Raxol.AgentClientProtocol.Rpc.RequestId`). Oracle-derived
  (schema.json `CancelRequestNotification`); not a port of any upstream
  f1729 module (f1729 has no `$/cancel_request` support).

  Per `MethodTable`'s D1-2 fix, this struct exists for `MethodTable.rows/0`
  completeness and for whichever layer (`Connection`) pre-filters this wire
  method before `Router.decode/4` — `Router` itself never generates a
  decode clause for this `layer: :protocol` row.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Rpc.RequestId

  @known_keys ["requestId", "_meta"]

  @type t :: %__MODULE__{request_id: RequestId.t(), _meta: map()}

  @enforce_keys [:request_id]
  defstruct request_id: nil, _meta: %{}

  @spec new(RequestId.t()) :: t()
  def new(request_id), do: %__MODULE__{request_id: request_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"requestId" => RequestId.to_json(r.request_id)}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"requestId" => id} = map) do
    if RequestId.valid?(id) do
      {:ok,
       %__MODULE__{
         request_id: RequestId.from_json(id),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    else
      {:error, {:invalid_cancel_request_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_cancel_request_notification, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification

  def encode(%CancelRequestNotification{} = val, opts) do
    val |> CancelRequestNotification.to_json() |> Jason.Encode.map(opts)
  end
end
