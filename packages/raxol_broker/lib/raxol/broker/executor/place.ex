defmodule Raxol.Broker.Executor.Place do
  @moduledoc """
  The only module that names an order-writing tool (`place_equity_order`,
  `cancel_equity_order`) or sends one. `Raxol.Broker.Executor.StructureTest`
  checks this from compiled code: only `Raxol.Broker.Executor` calls `run/4`,
  only this module and `Raxol.Broker.Executor.Review` call
  `Raxol.Broker.Executor.Port.call/4`, and no module in the app uses dynamic
  dispatch.

  `run/4` re-checks everything itself, whatever its caller checked:

    1. the `Raxol.Broker.Executor.ReviewReceipt` verifies, for this whole
       intent and this group id, under the key the calling process holds as
       `Raxol.Broker.Executor.receipt_key/0`. The key is read from the
       caller's process dictionary, never from an argument, so only the
       executor process (which puts it there in `init/1`) can spend a
       receipt; in any other process the key is nil and the receipt is
       refused before anything is journaled or sent;
    2. the intent has an order tool (equity orders and cancels), and that
       tool is `:write` in the session's `Raxol.Broker.Tools.Catalog`
       classes (`env.catalog`), so a tool the capture lacks or one whose
       schema changed is refused with `{:error, {:tool_refused, tool, class}}`;
    3. `{:placing}` is journaled. The journal refuses it unless this process
       holds the journal's claim (which only an executor process can take),
       the group was reviewed and allowed (or approved), and no other live
       group placed the same intent id, so a receipt cannot be spent twice.
       Any journal error means no call. The append waits as long as the
       journal takes (`:infinity`): a caller-side timeout would leave a
       queued `placing` landing after the executor gave up on it;
    4. the tool is called once, with `ref_id` (a UUID derived from the intent
       id) on a place, which Robinhood deduplicates on;
    5. the response is journaled as `{:order, status, response}`, also with
       no caller-side timeout.

  ## Threat model

  The guarantee is that no path through public APIs sends an order tool
  without the executor's review pipeline. The BEAM cannot stop code that
  deliberately writes into another module's private state: a process that
  sets the executor's `:"$initial_call"` and receipt-key slots in its own
  process dictionary (as `Raxol.Broker.Test.ExecutorIdentity` does in the
  tests), or that uses `:sys.replace_state/2` on the executor, can impersonate
  it. Every remaining bypass requires impersonating those private slots on
  purpose.

  ## Status

    * `:placed`: a result without `isError`;
    * `:failed`: a result with `isError`, a JSON-RPC error that says the
      request was never acted on (parse error, invalid request, unknown
      method, invalid params), or a client refusal made before anything was
      sent (the response then carries `"not_sent" => true`);
    * `:unknown`: everything else (timeout, transport failure, port exit, any
      other server error). The order may exist, and it keeps counting.
  """

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.Executor.{Port, Review, ReviewReceipt}
  alias Raxol.Broker.Tools.Catalog

  @failed_codes [-32_700, -32_600, -32_601, -32_602]

  @type env :: %{
          port: Port.t(),
          catalog: Catalog.session(),
          journal: Journal.server(),
          account: String.t(),
          timeout: timeout()
        }
  @type status :: :placed | :failed | :unknown
  @type outcome ::
          {:ok, status(), map()}
          | {:error, :invalid_receipt}
          | {:error, {:order_unjournaled, status(), map(), term()}}
          | {:error, term()}

  @doc """
  Place (or cancel) `intent` for journal group `group_id` with `receipt`.

  `env` carries no key: the receipt is verified under
  `Raxol.Broker.Executor.receipt_key/0` of the calling process.

  `{:ok, status, response}` once the order call ran and its response is
  journaled. `{:error, :invalid_receipt}` and any other `{:error, reason}`
  mean nothing was sent, except
  `{:error, {:order_unjournaled, status, response, reason}}`: the order WAS
  sent and its response could not be journaled.
  """
  @spec run(ReviewReceipt.t(), Intent.t(), String.t(), env()) :: outcome()
  def run(receipt, %Intent{} = intent, group_id, env) do
    with :ok <- ReviewReceipt.verify(receipt, Executor.receipt_key(), intent, group_id),
         {:ok, tool, args} <- permitted_call(intent, env),
         :ok <- journal(group_id, {:placing}, env.journal) do
      {status, response} = env.port |> Port.call(tool, args, env.timeout) |> classify(tool)

      case journal(group_id, {:order, status, response}, env.journal) do
        :ok -> {:ok, status, response}
        {:error, reason} -> {:error, {:order_unjournaled, status, response, reason}}
      end
    end
  end

  # The order tool for `intent`, only if it is `:write` for this session.
  defp permitted_call(intent, env) do
    with {:ok, tool, _args} = call <- call_for(intent, env.account),
         :ok <- Catalog.permit(env.catalog, tool, :write),
         do: call
  end

  defp call_for(%Intent{kind: :cancel} = intent, account),
    do: {:ok, "cancel_equity_order", Review.order_args(intent, account)}

  defp call_for(%Intent{kind: kind} = intent, account) do
    if Review.equity?(intent) do
      args = Map.put(Review.order_args(intent, account), "ref_id", ref_id(intent.id))
      {:ok, "place_equity_order", args}
    else
      {:error, {:no_adapter, kind}}
    end
  end

  defp journal(group_id, entry, journal) do
    Journal.append_to_group(group_id, entry, journal, :infinity)
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end

  @doc false
  # Public for the classification tests; `run/4` is the only caller in lib.
  @spec classify({:ok, map()} | {:error, term()}, String.t()) :: {status(), map()}
  def classify({:ok, %{is_error: false, content: content}}, tool),
    do: {:placed, %{"tool" => tool, "is_error" => false, "content" => content}}

  def classify({:ok, %{is_error: true, content: content}}, tool),
    do: {:failed, %{"tool" => tool, "is_error" => true, "content" => content}}

  def classify({:error, %{"code" => code} = error}, tool) when code in @failed_codes,
    do: {:failed, %{"tool" => tool, "error" => error}}

  def classify({:error, %{"code" => code} = error}, tool) when is_integer(code),
    do: {:unknown, %{"tool" => tool, "error" => error}}

  def classify({:error, reason}, tool) do
    if not_sent?(reason),
      do: {:failed, %{"tool" => tool, "not_sent" => true, "error" => text(reason)}},
      else: {:unknown, %{"tool" => tool, "error" => text(reason)}}
  end

  def classify(other, tool), do: {:unknown, %{"tool" => tool, "error" => text(other)}}

  # The reason can hold any term the client or the network produced; a
  # struct's Inspect implementation must not run in the executor.
  defp text(term), do: inspect(term, structs: false)

  # Refusals `Raxol.MCP.Client` and its HTTP transport return before a
  # request is written: the client not ready or never connected, a full
  # queue, the spend gate, the breaker, the target policy, a bad spec.
  # `{:noproc, _}`: the client was already gone when the call was made
  # (`GenServer.call/3` exits `{:noproc, {GenServer, :call, _}}`), so no
  # request was written.
  defp not_sent?({:port_down, {:noproc, _call}}), do: true
  defp not_sent?({:not_ready, _status}), do: true
  defp not_sent?({:connect_failed, _reason}), do: true
  defp not_sent?({:blocked, _reason}), do: true
  defp not_sent?({:invalid_spec, _spec}), do: true
  defp not_sent?({:unknown_price, _tool}), do: true

  defp not_sent?(reason),
    do: reason in [:busy, :unmetered_call, :breaker_open, :dns_failed, :no_http_client]

  @doc """
  The `ref_id` sent with a place: a version-8 UUID from the SHA-256 of the
  intent id, so every attempt at one intent carries the same key.
  """
  @spec ref_id(String.t()) :: String.t()
  def ref_id(intent_id) when is_binary(intent_id) do
    <<a::48, _v::4, b::12, _r::2, c::62, _rest::binary>> =
      :crypto.hash(:sha256, "raxol.broker.ref_id:" <> intent_id)

    <<a::48, 8::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> ->
      Enum.join([p1, p2, p3, p4, p5], "-")
    end)
  end
end
