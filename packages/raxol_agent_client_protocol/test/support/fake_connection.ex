defmodule Raxol.AgentClientProtocol.Test.FakeConnection do
  @moduledoc """
  A minimal Connection double implementing ONLY the IC surface the
  `Raxol.AgentClientProtocol.Session` consumes:

    * `delegate_reply/3` (IC-4)
    * `reply/3` (IC-4)
    * `notify/3` (IC-3)
    * `async_request/6` (IC-3)
    * `cancel_request/2` (IC-3)

  It records every interaction in wire order (`log/1`) so tests can assert the
  ordering invariants (updates before the reply, etc.), and it can auto-answer a
  `session/request_permission` `async_request` via a `:perm_responder` fun so the
  permission flow can be driven end-to-end. Because the Session reaches the
  Connection through an injected module (`:conn_mod`), this double stands in for
  the real Connection and thereby double-checks that the IC surface is sufficient
  for the Session — any gap surfaces as a missing callback here.

  The `:perm_responder` is an arity-1 fun `(req -> outcome)` where `outcome` is any
  `async_request` outcome the Session's §5 matrix expects, e.g.
  `{:ok, %RequestPermissionResponse{...}}`, `{:error, :timeout}`,
  `{:error, :connection_closed}`, `:decline` (sentinel for "record but do not
  answer"). Returning `:decline` records the ask but delivers nothing, so the test
  can inject `{:acp_result, tag, _}` itself (the tag is available via `last_async/1`).
  """

  use GenServer

  # -- IC surface (called by the Session via conn_mod) ------------------------

  @spec delegate_reply(pid(), reference(), pid()) :: :ok | {:error, :unknown_ref}
  def delegate_reply(conn, reply_ref, adopter) do
    GenServer.call(conn, {:record, {:delegate_reply, reply_ref, adopter}, :ok})
  end

  @spec reply(pid(), reference(), term()) :: :ok
  def reply(conn, reply_ref, result) do
    GenServer.call(conn, {:record, {:reply, reply_ref, result}, :ok})
  end

  @spec notify(pid(), String.t(), term()) :: :ok
  def notify(conn, method, params) do
    GenServer.call(conn, {:record, {:notify, method, params}, :ok})
  end

  @spec async_request(pid(), String.t(), term(), pid(), term(), timeout()) ::
          :ok | {:error, term()}
  def async_request(conn, method, params, owner, tag, timeout) do
    GenServer.call(conn, {:async_request, method, params, owner, tag, timeout})
  end

  @spec cancel_request(pid(), term()) :: :ok
  def cancel_request(conn, tag) do
    GenServer.call(conn, {:record, {:cancel_request, tag}, :ok})
  end

  # -- test helpers -----------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The recorded interactions, in wire order."
  @spec log(pid()) :: [tuple()]
  def log(conn), do: GenServer.call(conn, :log)

  @doc "The interactions of a given kind (`:notify`, `:reply`, ...), in order."
  @spec entries(pid(), atom()) :: [tuple()]
  def entries(conn, kind) do
    conn |> log() |> Enum.filter(fn t -> elem(t, 0) == kind end)
  end

  @doc "The most recent `async_request` as `{method, params, owner, tag}`, or nil."
  @spec last_async(pid()) :: {String.t(), term(), pid(), term()} | nil
  def last_async(conn), do: GenServer.call(conn, :last_async)

  @doc "Count of recorded interactions of a kind."
  @spec count(pid(), atom()) :: non_neg_integer()
  def count(conn, kind), do: conn |> entries(kind) |> length()

  # -- GenServer --------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, %{log: [], last_async: nil, perm_responder: Keyword.get(opts, :perm_responder)}}
  end

  @impl true
  def handle_call({:record, event, reply}, _from, state) do
    {:reply, reply, %{state | log: [event | state.log]}}
  end

  def handle_call({:async_request, method, params, owner, tag, _timeout}, _from, state) do
    event = {:async_request, method, params, owner, tag}
    state = %{state | log: [event | state.log], last_async: {method, params, owner, tag}}

    case state.perm_responder && state.perm_responder.(params) do
      nil -> :ok
      :decline -> :ok
      outcome -> send(owner, {:acp_result, tag, outcome})
    end

    {:reply, :ok, state}
  end

  def handle_call(:log, _from, state), do: {:reply, Enum.reverse(state.log), state}
  def handle_call(:last_async, _from, state), do: {:reply, state.last_async, state}
end
