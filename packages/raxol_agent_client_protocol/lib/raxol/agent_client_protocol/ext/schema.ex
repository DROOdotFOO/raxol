defmodule Raxol.AgentClientProtocol.Ext.Schema do
  @moduledoc """
  Wire schema structs for the reattach extension's `_raxol/*` notification
  vocabulary (`acp-reattach-design.md` §3.2 / §3.3).

  These are the RECEIVER-side decode structs for the frames the reattach
  subscriber emits. The sender (`Raxol.AgentClientProtocol.Ext.Reattach`)
  builds JSON-safe string-keyed maps directly on the `notify` path — the
  stamp-location rule (§3.3) is: fields on `_raxol/*` frames are FIRST-CLASS
  (our vocabulary), while riders on core-protocol frames travel in
  `_meta["raxol.io"]`. An offset-aware client decodes these structs; a stock
  client drops the `_raxol/*` notifications as unknown (legal, §3.4).

  Every struct follows the package convention: a total `from_json/1`
  (`{:ok, t} | {:error, reason}`, never raises), a `to_json/1`, and a
  `Jason.Encoder` impl. All fields are grow-only (add optional-with-default;
  never rename/retype/reorder/narrow) — a reader that meets an unknown field
  folds it into `_meta` and passes it through.

  Derived from the frozen `acp-reattach-design.md` (danger-zone, G5-PASS).
  """

  @doc false
  @spec int(term()) :: {:ok, integer()} | :error
  def int(v) when is_integer(v), do: {:ok, v}
  def int(_), do: :error

  @doc false
  @spec str(term()) :: {:ok, String.t()} | :error
  def str(v) when is_binary(v), do: {:ok, v}
  def str(_), do: :error
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.SessionRecordNotification do
  @moduledoc """
  `_raxol/session.record` (§3.3): the generic, self-describing delivery frame
  for every record kind OTHER than `session_update` (`turn_started`,
  `turn_completed`, `session_created`, and every future kind). New record
  kinds require NO new method rows — readers skip-unknown-kind as a fold.
  """

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{
          session_id: String.t(),
          offset: pos_integer(),
          kind: String.t(),
          payload: map(),
          taint: String.t(),
          ts: integer()
        }

  @enforce_keys [:session_id, :offset, :kind, :payload, :taint, :ts]
  defstruct [:session_id, :offset, :kind, :payload, :taint, :ts]

  @doc "Build a record notification (first-class fields)."
  @spec new(String.t(), pos_integer(), String.t(), map(), String.t(), integer()) :: t()
  def new(session_id, offset, kind, payload, taint, ts) do
    %__MODULE__{
      session_id: session_id,
      offset: offset,
      kind: kind,
      payload: payload,
      taint: taint,
      ts: ts
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "offset" => r.offset,
      "kind" => r.kind,
      "payload" => r.payload,
      "taint" => r.taint,
      "ts" => r.ts
    }
  end

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, sid} <- Schema.str(Map.get(map, "sessionId")),
         {:ok, offset} <- Schema.int(Map.get(map, "offset")),
         {:ok, kind} <- Schema.str(Map.get(map, "kind")),
         payload when is_map(payload) <- Map.get(map, "payload", %{}),
         {:ok, taint} <- Schema.str(Map.get(map, "taint")),
         {:ok, ts} <- Schema.int(Map.get(map, "ts")) do
      {:ok, new(sid, offset, kind, payload, taint, ts)}
    else
      _ -> {:error, {:invalid_session_record_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_record_notification, other}}
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.CaughtUpNotification do
  @moduledoc "`_raxol/session.caught_up` (§3.3): the history→live boundary UX signal (`offset = h+1`). OPTIONAL, non-load-bearing (bus §2.1)."

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{session_id: String.t(), offset: pos_integer()}
  @enforce_keys [:session_id, :offset]
  defstruct [:session_id, :offset]

  @spec new(String.t(), pos_integer()) :: t()
  def new(session_id, offset), do: %__MODULE__{session_id: session_id, offset: offset}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: %{"sessionId" => r.session_id, "offset" => r.offset}

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, sid} <- Schema.str(Map.get(map, "sessionId")),
         {:ok, offset} <- Schema.int(Map.get(map, "offset")) do
      {:ok, new(sid, offset)}
    else
      _ -> {:error, {:invalid_caught_up_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_caught_up_notification, other}}
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.LaggedNotification do
  @moduledoc "`_raxol/session.lagged` (§3.2 / §5): terminal drop-on-lag. `lastOffset` is the subscriber's own last forwarded offset; heal by reattaching from `lastOffset + 1`."

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{session_id: String.t(), last_offset: non_neg_integer()}
  @enforce_keys [:session_id, :last_offset]
  defstruct [:session_id, :last_offset]

  @spec new(String.t(), non_neg_integer()) :: t()
  def new(session_id, last_offset),
    do: %__MODULE__{session_id: session_id, last_offset: last_offset}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r),
    do: %{"sessionId" => r.session_id, "lastOffset" => r.last_offset}

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, sid} <- Schema.str(Map.get(map, "sessionId")),
         {:ok, last} <- Schema.int(Map.get(map, "lastOffset")) do
      {:ok, new(sid, last)}
    else
      _ -> {:error, {:invalid_lagged_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_lagged_notification, other}}
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.ClosedNotification do
  @moduledoc "`_raxol/session.closed` (§3.2 / CDI-5/CDI-6): terminate an ALREADY-REGISTERED subscriber mid-stream. `reason` is a grow-only string set."

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{session_id: String.t(), reason: String.t()}
  @enforce_keys [:session_id, :reason]
  defstruct [:session_id, :reason]

  @spec new(String.t(), String.t()) :: t()
  def new(session_id, reason), do: %__MODULE__{session_id: session_id, reason: reason}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: %{"sessionId" => r.session_id, "reason" => r.reason}

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, sid} <- Schema.str(Map.get(map, "sessionId")),
         {:ok, reason} <- Schema.str(Map.get(map, "reason")) do
      {:ok, new(sid, reason)}
    else
      _ -> {:error, {:invalid_closed_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_closed_notification, other}}
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.DetachNotification do
  @moduledoc "`_raxol/session.detach` (§3.2): client→agent voluntary unsubscribe. Idempotent (bus §2.2)."

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{session_id: String.t()}
  @enforce_keys [:session_id]
  defstruct [:session_id]

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: %{"sessionId" => r.session_id}

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    case Schema.str(Map.get(map, "sessionId")) do
      {:ok, sid} -> {:ok, new(sid)}
      :error -> {:error, {:invalid_detach_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_detach_notification, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Ext.Schema.SessionRecordNotification,
    Raxol.AgentClientProtocol.Ext.Schema.CaughtUpNotification,
    Raxol.AgentClientProtocol.Ext.Schema.LaggedNotification,
    Raxol.AgentClientProtocol.Ext.Schema.ClosedNotification,
    Raxol.AgentClientProtocol.Ext.Schema.DetachNotification
  ] do
  def encode(%mod{} = struct, opts), do: Jason.Encode.map(mod.to_json(struct), opts)
end
