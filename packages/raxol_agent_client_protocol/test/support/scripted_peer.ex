defmodule Raxol.AgentClientProtocol.Test.ScriptedPeer do
  @moduledoc """
  Test-only helper for driving the *peer* side of a
  `Raxol.AgentClientProtocol.Transport.Paired` pair against a real
  `Raxol.AgentClientProtocol.Connection` under test (see
  `test/connection_test.exs`).

  Wraps raw JSON-RPC-shaped map construction plus the
  `assert_receive`/`refute_receive` boilerplate around
  `{:acp_transport, ref, {:message | :closed, _}}` deliveries. Deliberately
  works at the *wire map* level (never constructs `Rpc.*` structs, never
  calls `Router`) -- the whole point of exercising the Connection through a
  scripted peer is to observe exactly the bytes-would-be-bytes a real peer
  sees, independent of how `Connection` happens to be implemented
  internally.

  Every frame is sent through `Raxol.AgentClientProtocol.Transport.Paired`,
  which passes Elixir maps through unchanged (no JSON encode/decode) -- see
  that module's moduledoc for why byte-level codec correctness is out of
  scope here (it belongs to the stdio transport's own tests).
  """

  import ExUnit.Assertions

  alias Raxol.AgentClientProtocol.Transport.Paired

  @enforce_keys [:handle]
  defstruct [:handle]

  @type t :: %__MODULE__{handle: Paired.t()}

  @doc """
  Build a connected pair: `{conn_handle, peer}`.

  `conn_handle` is the raw, not-yet-owned `Paired.t()` -- hand it to
  `Connection.start_link/1` as `transport: {Paired, conn_handle}` (the
  Connection adopts it itself in `handle_continue/2`, per IC-8; this helper
  must NOT call `Paired.set_owner/2` on it).

  `peer` is this module's wrapper around the *other* side, already owned by
  the calling (test) process -- inbound frames from the Connection arrive
  in the test process's mailbox and are read via `recv/2`.
  """
  @spec new() :: {Paired.t(), t()}
  def new do
    {conn_handle, peer_handle} = Paired.create_pair()
    :ok = Paired.set_owner(peer_handle, self())
    {conn_handle, %__MODULE__{handle: peer_handle}}
  end

  @doc "Send a JSON-RPC request frame `{jsonrpc, id, method, params?}`."
  @spec send_request(t(), term(), String.t(), term()) :: :ok
  def send_request(%__MODULE__{} = peer, id, method, params \\ nil) do
    send_raw(peer, request_frame(id, method, params))
  end

  @doc "Send a JSON-RPC notification frame `{jsonrpc, method, params?}` (no id)."
  @spec send_notification(t(), String.t(), term()) :: :ok
  def send_notification(%__MODULE__{} = peer, method, params \\ nil) do
    send_raw(peer, notification_frame(method, params))
  end

  @doc "Send a JSON-RPC success response frame for `id`."
  @spec send_result(t(), term(), term()) :: :ok
  def send_result(%__MODULE__{} = peer, id, result) do
    send_raw(peer, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
  end

  @doc "Send a JSON-RPC error response frame for `id`."
  @spec send_error(t(), term(), map()) :: :ok
  def send_error(%__MODULE__{} = peer, id, error) do
    send_raw(peer, %{"jsonrpc" => "2.0", "id" => id, "error" => error})
  end

  @doc "Send the protocol-layer `$/cancel_request` notification for `request_id`."
  @spec send_cancel_request(t(), term()) :: :ok
  def send_cancel_request(%__MODULE__{} = peer, request_id) do
    send_notification(peer, "$/cancel_request", %{"requestId" => request_id})
  end

  @doc "Send the session-control `session/cancel` notification for `session_id`."
  @spec send_session_cancel(t(), String.t()) :: :ok
  def send_session_cancel(%__MODULE__{} = peer, session_id) do
    send_notification(peer, "session/cancel", %{"sessionId" => session_id})
  end

  @doc "Send an arbitrary (possibly malformed / non-JSON-RPC-shaped) raw map frame."
  @spec send_raw(t(), map()) :: :ok
  def send_raw(%__MODULE__{handle: handle}, frame) when is_map(frame) do
    {:ok, _state} = Paired.send_message(handle, frame)
    :ok
  end

  @doc """
  Send an arbitrary term as a "frame" -- including a non-map shape like a
  JSON array (batch request), which `Paired.send_message/2`'s own public API
  guards against (`when is_map(message)`) since a real byte-level transport
  would never hand the Connection anything but a decoded map. This bypasses
  that guard by calling straight into the `Paired` GenServer's `handle_call`
  clause (which has no such guard), purely to exercise the Connection's own
  classification path (design §4: "a JSON array (batch) frame -> `-32600`,
  `null` id") against a shape `Paired`'s normal contract never produces on
  its own. Test-only; never use this for anything but that one scenario.
  """
  @spec send_raw_unchecked(t(), term()) :: :ok
  def send_raw_unchecked(%__MODULE__{handle: %Paired{pid: pid}}, frame) do
    :ok = GenServer.call(pid, {:send, frame})
  end

  @doc "Close this peer's transport handle (simulates the peer hanging up on the Connection)."
  @spec close_peer(t()) :: :ok
  def close_peer(%__MODULE__{handle: handle}), do: Paired.close(handle)

  @doc "Block for the next frame the Connection sent us; returns the decoded (raw) map."
  @spec recv(t(), timeout()) :: map()
  def recv(%__MODULE__{} = _peer, timeout \\ 500) do
    assert_receive {:acp_transport, _ref, {:message, frame}}, timeout
    frame
  end

  @doc "Assert no frame arrives within `timeout`."
  @spec assert_no_frame(t(), timeout()) :: :ok
  def assert_no_frame(%__MODULE__{} = _peer, timeout \\ 100) do
    refute_receive {:acp_transport, _ref, {:message, _frame}}, timeout
    :ok
  end

  @doc "Block for the transport-closed delivery; returns the close reason."
  @spec recv_closed(t(), timeout()) :: term()
  def recv_closed(%__MODULE__{} = _peer, timeout \\ 500) do
    assert_receive {:acp_transport, _ref, {:closed, reason}}, timeout
    reason
  end

  @spec request_frame(term(), String.t(), term()) :: map()
  def request_frame(id, method, params \\ nil) do
    put_params(%{"jsonrpc" => "2.0", "id" => id, "method" => method}, params)
  end

  @spec notification_frame(String.t(), term()) :: map()
  def notification_frame(method, params \\ nil) do
    put_params(%{"jsonrpc" => "2.0", "method" => method}, params)
  end

  defp put_params(base, nil), do: base
  defp put_params(base, params), do: Map.put(base, "params", params)
end
