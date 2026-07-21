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

  @doc false
  # Optional string: an absent/null field decodes to nil (the encoder emits
  # nil for it too), a binary decodes as-is, any other type is an error.
  # Keeps `to_json` its own inverse for nil-valued optional string fields.
  @spec opt_str(term()) :: {:ok, String.t() | nil} | :error
  def opt_str(nil), do: {:ok, nil}
  def opt_str(v) when is_binary(v), do: {:ok, v}
  def opt_str(_), do: :error
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

defmodule Raxol.AgentClientProtocol.Ext.Schema.SteerRequest do
  @moduledoc """
  `_raxol/session.steer` request: redirect a running turn with
  new user input WITHOUT killing it, addressed by `sessionId`. A steer is the
  sibling of interrupt (kill-now); it injects at the next turn boundary.

  Mirrors the routed command shape `Raxol.Agent.Command`'s `:steer` codec
  validates and `Raxol.Agent.Steer.Request`:

    * `session_id` — the target session (routing key).
    * `text` — the steering text.
    * `expected_turn_id` — the turn ordinal the client believes is running; the
      compare-and-swap target. A JSON scalar (the turn `turnId` the client
      learned from the turn's start event); carried through opaquely.
    * `client_msg_id` — the client-supplied idempotency key (§5.1), or `nil`.

  `expected_turn_id` is grow-only opaque: this layer never interprets it, it
  only round-trips the JSON value to the CAS decision core.
  """

  alias Raxol.AgentClientProtocol.Ext.Schema

  @type t :: %__MODULE__{
          session_id: String.t(),
          text: String.t() | nil,
          expected_turn_id: term(),
          client_msg_id: term() | nil
        }

  @enforce_keys [:session_id, :expected_turn_id]
  defstruct [:session_id, :text, :expected_turn_id, :client_msg_id]

  @spec new(String.t(), String.t() | nil, term(), term() | nil) :: t()
  def new(session_id, text, expected_turn_id, client_msg_id \\ nil) do
    %__MODULE__{
      session_id: session_id,
      text: text,
      expected_turn_id: expected_turn_id,
      client_msg_id: client_msg_id
    }
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{
      "sessionId" => r.session_id,
      "text" => r.text,
      "expectedTurnId" => r.expected_turn_id,
      "clientMsgId" => r.client_msg_id
    }
  end

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    # `text` is optional (the type, `new/4`, and `to_json` all treat nil as
    # valid), so decode it with `opt_str` -- using `str` here rejected a
    # legitimate text-less steer that `to_json` itself emits, breaking the
    # encode/decode round-trip.
    with {:ok, sid} <- Schema.str(Map.get(map, "sessionId")),
         {:ok, text} <- Schema.opt_str(Map.get(map, "text")),
         expected when not is_nil(expected) <- Map.get(map, "expectedTurnId") do
      {:ok, new(sid, text, expected, Map.get(map, "clientMsgId"))}
    else
      _ -> {:error, {:invalid_steer_request, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_steer_request, other}}
end

defmodule Raxol.AgentClientProtocol.Ext.Schema.SteerResponse do
  @moduledoc """
  `_raxol/session.steer` response: the synchronous, honest CAS
  outcome — the full vocabulary a Surface banner renders.

  `steer/2` is deliberately a SYNCHRONOUS typed decision, not fire-and-forget:
  a stale-turn (or reuse, or no-live-turn) rejection is NON-journaled (zero model
  effect), so no event a surface could observe ever carries the outcome — only a
  direct reply can honestly distinguish "accepted" from "silently dropped".

  The wire `"outcome"` discriminator is one of:

    * `"accepted"`  — landed in the running turn; carries the accept `ref`
      (`turnId`/`offset`/`clientMsgId`).
    * `"duplicate"` — the same `clientMsgId` was already accepted; `ref`
      references the ORIGINAL accept (§5.1 mobile-retry idempotency).
    * `"stale"`     — the CAS lost (turn ended, or another steer won);
      carries `expectedTurnId`/`actualTurnId`. Nothing journaled.
    * `"no_live_turn"`      — no turn is currently running.
    * `"client_msg_id_reuse"` — the same idempotency key arrived with different
      content (a client bug/attack, never a retry).
    * `"no_steer_channel"`  — the session has no steer adapter wired (the honest
      refusal, unchanged from the legacy lane).
  """

  alias Raxol.AgentClientProtocol.Session.SteerAdapter

  @type t :: %__MODULE__{result: SteerAdapter.result()}

  @enforce_keys [:result]
  defstruct [:result]

  @doc "Wrap a CAS `result` (as returned by a `SteerAdapter.resolve/2`) for the wire."
  @spec new(SteerAdapter.result()) :: t()
  def new(result), do: %__MODULE__{result: result}

  @doc "The wrapped CAS result (the honest outcome vocabulary)."
  @spec result(t()) :: SteerAdapter.result()
  def result(%__MODULE__{result: result}), do: result

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{result: result}), do: encode_result(result)

  defp encode_result({:ok, {:accepted, ref}}),
    do: Map.put(ref_json(ref), "outcome", "accepted")

  defp encode_result({:ok, {:duplicate, ref}}),
    do: Map.put(ref_json(ref), "outcome", "duplicate")

  defp encode_result({:error, {:stale_turn, expected, actual}}),
    do: %{
      "outcome" => "stale",
      "expectedTurnId" => json_turn_token(expected),
      "actualTurnId" => json_turn_token(actual)
    }

  defp encode_result({:error, :no_live_turn}), do: %{"outcome" => "no_live_turn"}
  defp encode_result({:error, :client_msg_id_reuse}), do: %{"outcome" => "client_msg_id_reuse"}
  defp encode_result({:error, :no_steer_channel}), do: %{"outcome" => "no_steer_channel"}

  defp ref_json(ref) do
    %{
      "turnId" => ref |> Map.get(:turn_id) |> json_turn_token(),
      "offset" => Map.get(ref, :offset),
      "clientMsgId" => Map.get(ref, :client_msg_id)
    }
  end

  # A turn token is USUALLY the session's integer turn ordinal, but a real
  # `SteerAdapter` (e.g. the one closing over `Raxol.Agent.Steer` in the
  # `raxol_agent` package) issues a CAS-swap token after every accept --
  # `{:steered, cur, System.unique_integer(...)}`, a TUPLE -- as the new
  # `turn_id`. That swapped value has nowhere legitimate to go (an accept's
  # `ref` only ever carries the PRE-swap token, so no client can legitimately
  # learn the swapped one), which means the very next steer against the same
  # live turn ordinarily resolves `{:error, {:stale_turn, _, actual}}` with
  # `actual` bound to that tuple -- an everyday interaction, not a hostile
  # input. `Jason.Encoder` has no implementation for tuples, so handing one to
  # `Jason.encode!` raw (via this struct's `Jason.Encoder` impl) raises
  # `Protocol.UndefinedError` and crashes the reply. Keep the common
  # integer/binary/nil shapes byte-identical on the wire; stringify anything
  # else so `encode_result/1` stays total and the wire never carries a term
  # JSON cannot represent.
  defp json_turn_token(token) when is_integer(token) or is_binary(token) or is_nil(token),
    do: token

  defp json_turn_token(token), do: inspect(token)

  @spec from_json(map()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    case decode_result(Map.get(map, "outcome"), map) do
      {:ok, result} -> {:ok, new(result)}
      :error -> {:error, {:invalid_steer_response, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_steer_response, other}}

  defp decode_result("accepted", map), do: {:ok, {:ok, {:accepted, ref_of(map)}}}
  defp decode_result("duplicate", map), do: {:ok, {:ok, {:duplicate, ref_of(map)}}}

  defp decode_result("stale", map) do
    {:ok, {:error, {:stale_turn, Map.get(map, "expectedTurnId"), Map.get(map, "actualTurnId")}}}
  end

  defp decode_result("no_live_turn", _map), do: {:ok, {:error, :no_live_turn}}
  defp decode_result("client_msg_id_reuse", _map), do: {:ok, {:error, :client_msg_id_reuse}}
  defp decode_result("no_steer_channel", _map), do: {:ok, {:error, :no_steer_channel}}
  defp decode_result(_unknown, _map), do: :error

  defp ref_of(map) do
    %{
      turn_id: Map.get(map, "turnId"),
      offset: Map.get(map, "offset"),
      client_msg_id: Map.get(map, "clientMsgId")
    }
  end
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Ext.Schema.SessionRecordNotification,
    Raxol.AgentClientProtocol.Ext.Schema.CaughtUpNotification,
    Raxol.AgentClientProtocol.Ext.Schema.LaggedNotification,
    Raxol.AgentClientProtocol.Ext.Schema.ClosedNotification,
    Raxol.AgentClientProtocol.Ext.Schema.DetachNotification,
    Raxol.AgentClientProtocol.Ext.Schema.SteerRequest,
    Raxol.AgentClientProtocol.Ext.Schema.SteerResponse
  ] do
  def encode(%mod{} = struct, opts), do: Jason.Encode.map(mod.to_json(struct), opts)
end
