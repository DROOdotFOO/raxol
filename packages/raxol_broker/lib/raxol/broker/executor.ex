defmodule Raxol.Broker.Executor do
  @moduledoc """
  The one path every order takes: intent, policy, `review_*`, policy again,
  `placing`, `place_*`, each step journaled before the next one runs.

      run(intent, context)
        open_group       intent + context (policy and counters set here)
        verdict          :pre_review; DENY ends here
        review           the review tool's response; its warnings feed the context
        verdict          :post_review; DENY ends here, ASK parks the group
        [approval]       approve/3 or decline/3 on a parked group
        placing          Raxol.Broker.Executor.Place, with the ReviewReceipt
        order            :placed | :failed | :unknown

  ## Context

  The executor overwrites these `Raxol.Broker.Policy.Context` fields,
  whatever the caller passed:

    * `policy`, from the `:policy` start option.
    * `today_notional` and `orders_last_minute`, read from
      `Raxol.Broker.Journal` at decision time.
    * `review_warnings`, from this executor's own review call (empty
      before it).

  Every other field is trusted from the caller until #1185 sources it:
  `quotes`, `positions`, `portfolio_value`, `start_of_day_value`,
  `day_pnl` and `market_session`.

  ## Guards

  Everything is re-checked here, whatever the caller did:

    * Decisions are serialized through this process, so two callers cannot
      both pass the daily cap before either writes `placing`.
    * One executor per journal: `init/1` claims the journal with
      `Raxol.Broker.Journal.claim/1`, and a second executor on the same
      journal fails to start with `{:journal_claimed, pid}`. The journal
      only grants the claim to a process started as an executor, and
      refuses `placing` from any process but the claimant.
    * The claim lives in the journal's memory. The executor monitors the
      journal and stops with `{:journal_down, reason}` when it goes down,
      so its supervisor restarts it; the new executor claims again and
      closes the groups this one left open. Queued callers get an exit
      from their call, and an in-flight review task dies with the
      executor.
    * Review is mandatory: `Raxol.Broker.Executor.Place` is the only
      module that names an order tool, and it needs a
      `Raxol.Broker.Executor.ReviewReceipt` for the same intent and group,
      verified under a key this process generates at start and keeps in
      its own process dictionary (`receipt_key/0` is nil in any other
      process). The journal also refuses `placing` for a group without a
      review record and an ALLOW or an approval after it.
    * Threat model: the BEAM cannot stop code that deliberately writes
      into another module's private state, e.g. `Process.put` into its
      slots or `:sys.replace_state`. The guarantee is that no path through
      public APIs can send an order tool without this review pipeline.
      Every remaining bypass requires impersonating the executor's private
      process-dictionary slots on purpose.
    * Any journal error before `placing` is written, any review error, and
      any intent without an order tool mean no order is sent.
    * Once the order call has been made the result is always `{:ok, map}`.
      If the `order` record could not be written the map has
      `journaled: false` and `journal_error: reason`; the order may exist
      at the broker, so reconcile before retrying.
    * Idempotency: an intent id that already has a group with a `placing`
      record whose outcome is not `:failed` (including a crash closed as
      `crash_outcome_unknown`) returns `{:ok, :duplicate}` and calls
      nothing. Each place also sends a `ref_id` derived from the intent id,
      which Robinhood deduplicates on. Intent ids must be stable for a
      re-run to be recognised: pass `:id` to the `Raxol.Broker.Intent`
      constructor.

  ## ASK

  A post-review ASK parks the group and returns `{:ask, group_id, prompts}`;
  the group id is the token. `approve/3` rebuilds the counters from the
  journal, journals the approval and runs the policy again: a DENY now (the
  cap moved while it was parked) ends the group; an ASK (the questions the
  human just answered) or ALLOW goes on to `placing`. `decline/3` and
  `close/3` end the group. Routing an ASK to a person and denying on
  timeout are #1180's.

  `approve/3` and `decline/3` need a non-empty `by`, `close/3` a non-nil
  atom reason; anything else raises `FunctionClauseError` in the caller and
  leaves the group parked. An approve refused before the approval is
  journaled (port down, journal unreadable, or the approval entry rejected
  as invalid) also leaves the group parked.

  Parked groups live in this process. On start, every group the journal
  still has open is closed with `{:close, :executor_restarted}`, so a group
  parked before a restart cannot be approved after it.

  ## Concurrency

  The review call runs in a task, so `parked/2` answers while a review is
  in flight; other calls queue behind it in arrival order. A queued call
  whose caller has died by the time it is reached is dropped, never
  dispatched. The place call runs in this process (the journal only
  accepts `placing` from the claimant), so nothing answers until it
  returns or `:place_timeout` passes.

  ## Port

  The port is a `Raxol.Broker.Executor.Port.MCP` session started from
  `:session`, linked to this process. Exits are trapped: if the session's
  client dies, the executor stays up and every later `run/3` and
  `approve/3` returns `{:error, {:port_down, reason}}` before opening or
  journaling anything. Restart the executor to get a new session.

  ## Mode

  Only `mode: :dry_run` (the default) runs. `Raxol.Broker.Executor.Port.MCP`
  refuses to connect a live session in dry-run (`{:error,
  :live_port_in_dry_run}`): a dry-run `:session` must carry `sandbox: true`
  and a URL that is not on `robinhood.com`. The intent record carries
  `"mode": "dry_run"`. `mode: :armed` is `{:error, :not_armed}` until
  arming exists (#1179).

  ## Options

    * `:policy` (required) - a policy keyword list, validated with
      `Raxol.Broker.PolicyFile.validate/1`; `{:invalid_policy, reason}`
      otherwise.
    * `:session` (required) - a `Raxol.MCP.Client` spec for
      `Raxol.Broker.Executor.Port.MCP.start/2`.
    * `:account_number` (required) - the account orders are sent for.
    * `:journal` - the `Raxol.Broker.Journal` server (default that module).
    * `:mode` - `:dry_run` (default) or `:armed`.
    * `:clock` - zero-arity function returning the UTC `DateTime` used for
      the counters (default `DateTime.utc_now/0`).
    * `:review_timeout`, `:place_timeout` - per tool call, a positive
      integer of milliseconds (default 30 s); anything else is
      `{:invalid_timeout, key, value}`.
    * `:name`.

  `today_notional` counts a rolling 24 hours back from the clock's now,
  which counts at least as much as any calendar day would. No caller input
  moves the window; a calendar the executor owns (New York trading day) is
  #1185's.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Executor.{Place, Port, Review, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.{Intent, Journal, Policy, PolicyFile}
  alias Raxol.Broker.Policy.Context

  @default_timeout 30_000

  @type placed :: %{
          required(:group_id) => String.t(),
          required(:status) => Place.status(),
          required(:response) => map(),
          required(:journaled) => boolean(),
          optional(:journal_error) => term()
        }

  @type result ::
          {:ok, placed()}
          | {:ok, :duplicate}
          | {:ask, String.t(), [{Policy.rule_id(), String.t()}]}
          | {:deny, String.t(), term()}
          | {:error, term()}

  # -- API ----------------------------------------------------------------------

  @doc "Start the executor. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Run `intent` through the pipeline. See the moduledoc."
  @spec run(GenServer.server(), Intent.t(), Context.t()) :: result()
  def run(server, %Intent{} = intent, %Context{} = context),
    do: GenServer.call(server, {:run, intent, context}, :infinity)

  @doc "Approve a parked ASK; `by` names who approved (non-empty string)."
  @spec approve(GenServer.server(), String.t(), String.t()) :: result()
  def approve(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:approve, token, by}, :infinity)

  @doc "Decline a parked ASK; the group ends as DENY. `by` is a non-empty string."
  @spec decline(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def decline(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:decline, token, by}, :infinity)

  @doc "Abandon a parked ASK with `{:close, reason}`; `reason` is a non-nil atom."
  @spec close(GenServer.server(), String.t(), atom()) :: :ok | {:error, term()}
  def close(server, token, reason)
      when is_binary(token) and is_atom(reason) and not is_nil(reason),
      do: GenServer.call(server, {:close, token, reason}, :infinity)

  @doc "Parked ASKs: `[%{group_id, intent, prompts}]`, oldest first."
  @spec parked(GenServer.server(), timeout()) :: [map()]
  def parked(server, timeout \\ :infinity), do: GenServer.call(server, :parked, timeout)

  # The receipt key lives in the executor's own process dictionary, so it is
  # nil in every other process. `Raxol.Broker.Executor.Place` verifies
  # receipts with it, which means only this process can place.
  @doc false
  @spec receipt_key() :: binary() | nil
  def receipt_key, do: Process.get({__MODULE__, :receipt_key})

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = base_state(opts)
    Process.put({__MODULE__, :receipt_key}, state.key)

    with {:ok, config} <- check_opts(opts),
         {:ok, journal_ref} <- monitor_journal(state.journal),
         :ok <- safe(fn -> Journal.claim(state.journal) end),
         {:ok, port} <- start_port(config.session, state) do
      state =
        Map.merge(state, %{
          port: port,
          account: config.account,
          policy: config.policy,
          journal_ref: journal_ref
        })

      close_orphans(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check_opts(opts) do
    with :ok <- check_mode(Keyword.get(opts, :mode, :dry_run)),
         :ok <- check_timeout(opts, :review_timeout),
         :ok <- check_timeout(opts, :place_timeout),
         {:ok, account} <- fetch_account(opts),
         {:ok, policy} <- fetch_policy(opts),
         {:ok, session} <- fetch_session(opts) do
      {:ok, %{account: account, policy: policy, session: session}}
    end
  end

  defp check_timeout(opts, key) do
    case Keyword.get(opts, key, @default_timeout) do
      timeout when is_integer(timeout) and timeout > 0 -> :ok
      other -> {:error, {:invalid_timeout, key, other}}
    end
  end

  # The claim lives in the journal's memory, so a journal restart drops it.
  # The executor stops with the journal; its supervisor restarts it, and the
  # new one claims again and closes the groups this one left open.
  defp monitor_journal(journal) do
    case GenServer.whereis(journal) do
      pid when is_pid(pid) -> {:ok, Process.monitor(pid)}
      _ -> {:error, :journal_not_running}
    end
  end

  defp base_state(opts) do
    %{
      journal: Keyword.get(opts, :journal, Journal),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      review_timeout: Keyword.get(opts, :review_timeout, @default_timeout),
      place_timeout: Keyword.get(opts, :place_timeout, @default_timeout),
      key: :crypto.strong_rand_bytes(32),
      port_down: nil,
      parked: %{},
      busy: nil,
      queue: :queue.new()
    }
  end

  defp start_port(spec, state),
    do:
      PortMCP.start(spec,
        mode: :dry_run,
        call_timeout: max(state.review_timeout, state.place_timeout)
      )

  defp check_mode(:dry_run), do: :ok
  defp check_mode(:armed), do: {:error, :not_armed}
  defp check_mode(other), do: {:error, {:invalid_mode, other}}

  defp fetch_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) and account != "" -> {:ok, account}
      other -> {:error, {:invalid_account_number, other}}
    end
  end

  defp fetch_policy(opts) do
    case PolicyFile.validate(Keyword.get(opts, :policy)) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, {:invalid_policy, reason}}
    end
  end

  defp fetch_session(opts) do
    case Keyword.get(opts, :session) do
      spec when is_list(spec) and spec != [] -> {:ok, spec}
      _ -> {:error, :session_required}
    end
  end

  # A group the journal still has open was parked or mid-flight in an
  # executor that is gone; nothing may resume it.
  defp close_orphans(state) do
    case safe(fn -> Journal.open_groups(state.journal) end) do
      {:ok, ids} ->
        Enum.each(ids, &close_group(state, &1, :executor_restarted))

      {:error, reason} ->
        Logger.warning("[Broker.Executor] could not list open groups: #{inspect(reason)}")
    end
  end

  @impl GenServer
  def handle_call(:parked, _from, state) do
    list =
      state.parked
      |> Enum.sort_by(fn {_id, group} -> group.seq end)
      |> Enum.map(fn {id, group} ->
        %{group_id: id, intent: group.intent, prompts: group.prompts}
      end)

    {:reply, list, state}
  end

  def handle_call(request, from, %{busy: nil} = state) do
    case dispatch(request, from, state) do
      {:reply, reply, state} -> {:reply, reply, state}
      {:await, state} -> {:noreply, state}
    end
  end

  def handle_call(request, from, state),
    do: {:noreply, %{state | queue: :queue.in({request, from}, state.queue)}}

  @impl GenServer
  def handle_info({ref, result}, %{busy: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    review_done(state, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{ref: ref}} = state),
    do: review_done(state, {:error, {:review_crashed, reason}})

  # Queued callers get an exit from their call; the linked review task dies
  # with this process; the groups left open are closed by the next executor.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{journal_ref: ref} = state) do
    Logger.warning("[Broker.Executor] journal went down: #{inspect(reason)}")
    {:stop, {:journal_down, reason}, state}
  end

  def handle_info({:EXIT, pid, reason}, %{port: {PortMCP, %PortMCP{pid: pid}}} = state) do
    Logger.warning("[Broker.Executor] port session exited: #{inspect(reason)}")
    {:noreply, %{state | port_down: reason}}
  end

  # Review tasks are linked; their exits are handled through the monitor.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    Logger.debug("[Broker.Executor] unexpected message: #{inspect(message)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state), do: Port.stop(state.port)

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, %{} = state} -> {:state, %{state | key: :redacted}}
      other -> other
    end)
  end

  # -- Dispatch -----------------------------------------------------------------

  defp dispatch({:run, intent, context}, from, state),
    do: awaiting(run_intent(state, intent, context), from)

  defp dispatch({:approve, token, by}, _from, state),
    do: approve_parked(state, token, by)

  defp dispatch({:decline, token, by}, _from, state),
    do: finish_parked(state, token, {:approval, :declined, by})

  defp dispatch({:close, token, reason}, _from, state),
    do: finish_parked(state, token, {:close, reason})

  defp awaiting({:await, pending, state}, from),
    do: {:await, %{state | busy: Map.put(pending, :from, from)}}

  defp awaiting(done, _from), do: done

  defp review_done(%{busy: pending} = state, result) do
    {:reply, reply, state} = reviewed(%{state | busy: nil}, pending, result)
    GenServer.reply(pending.from, reply)
    {:noreply, drain(state)}
  end

  defp drain(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, entry}, queue} ->
        drain_entry(%{state | queue: queue}, entry)
    end
  end

  # A caller that died while queued is never dispatched: its order would be
  # placed with nobody to receive the result.
  defp drain_entry(state, {request, {pid, _tag} = from}) do
    if Process.alive?(pid) do
      case dispatch(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          drain(state)

        {:await, state} ->
          state
      end
    else
      Logger.info("[Broker.Executor] dropped a queued #{elem(request, 0)}: caller is gone")
      drain(state)
    end
  end

  # -- Pipeline -----------------------------------------------------------------

  defp run_intent(state, intent, context) do
    with :ok <- port_up(state),
         :ok <- not_parked(state, intent),
         {:ok, nil} <- placed_before(state, intent),
         {:ok, _tool} <- Review.tool(intent),
         {:ok, context} <- fill(state, %{context | review_warnings: []}),
         {:ok, group_id} <- open(state, intent, context) do
      pre_review(state, intent, context, group_id)
    else
      {:ok, group_id} when is_binary(group_id) -> {:reply, {:ok, :duplicate}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp port_up(%{port_down: nil, port: {PortMCP, %PortMCP{pid: pid}}}) do
    if Process.alive?(pid), do: :ok, else: {:error, {:port_down, :noproc}}
  end

  defp port_up(%{port_down: nil}), do: :ok
  defp port_up(%{port_down: reason}), do: {:error, {:port_down, reason}}

  defp not_parked(state, intent) do
    case Enum.find(state.parked, fn {_id, group} -> group.intent.id == intent.id end) do
      nil -> :ok
      {id, _group} -> {:error, {:parked, id}}
    end
  end

  defp placed_before(state, intent),
    do: safe(fn -> Journal.placing_for_intent(intent.id, state.journal) end)

  defp open(state, intent, context),
    do: safe(fn -> Journal.open_group(intent, context, state.journal, mode: :dry_run) end)

  defp pre_review(state, intent, context, group_id) do
    verdict = Policy.evaluate(intent, context)

    case {append(state, group_id, {:verdict, :pre_review, verdict}), verdict} do
      {{:error, reason}, _verdict} -> {:reply, {:error, reason}, state}
      {:ok, {:deny, reason}} -> {:reply, {:deny, group_id, reason}, state}
      {:ok, _allow_or_ask} -> review(state, intent, context, group_id)
    end
  end

  defp review(state, intent, context, group_id) do
    %{port: port, account: account, review_timeout: timeout} = state
    task = Task.async(fn -> Review.run(port, intent, account, timeout) end)
    {:await, %{ref: task.ref, intent: intent, context: context, group_id: group_id}, state}
  end

  defp reviewed(state, %{group_id: group_id}, {:error, reason}) do
    _ = close_group(state, group_id, :review_failed)
    {:reply, {:error, reason}, state}
  end

  defp reviewed(state, pending, {:ok, response, warnings}) do
    pending = %{pending | context: %{pending.context | review_warnings: warnings}}

    case append(state, pending.group_id, {:review, response}) do
      :ok -> post_review(state, pending)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp post_review(state, %{intent: intent, group_id: group_id} = pending) do
    receipt = ReviewReceipt.issue(state.key, intent, group_id)
    verdict = Policy.evaluate(intent, pending.context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} -> {:reply, {:error, reason}, state}
      {:ok, {:deny, reason}} -> {:reply, {:deny, group_id, reason}, state}
      {:ok, {:ask, prompts}} -> park(state, pending, receipt, prompts)
      {:ok, {:allow, _intent}} -> place(state, intent, group_id, receipt)
    end
  end

  defp park(state, %{group_id: group_id} = pending, receipt, prompts) do
    group = %{
      intent: pending.intent,
      context: pending.context,
      receipt: receipt,
      prompts: prompts,
      seq: System.unique_integer([:monotonic])
    }

    parked = Map.put(state.parked, group_id, group)
    {:reply, {:ask, group_id, prompts}, %{state | parked: parked}}
  end

  # Everything before the approval is journaled leaves the group parked.
  defp approve_parked(state, token, by) do
    with :ok <- port_up(state),
         {:ok, group} <- fetch_parked(state, token),
         {:ok, context} <- fill(state, group.context) do
      approved(state, token, group, by, context)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_parked(state, token) do
    case Map.fetch(state.parked, token) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, {:not_parked, token}}
    end
  end

  defp approved(state, group_id, group, by, context) do
    unparked = %{state | parked: Map.delete(state.parked, group_id)}

    case append(state, group_id, {:approval, :approved, by}) do
      :ok ->
        recheck(unparked, group_id, group, context)

      {:error, {:invalid_entry, _} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        _ = close_group(unparked, group_id, :approval_failed)
        {:reply, {:error, reason}, unparked}
    end
  end

  defp recheck(state, group_id, group, context) do
    verdict = Policy.evaluate(group.intent, context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        _ = close_group(state, group_id, :approval_failed)
        {:reply, {:error, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, _ask_answered_or_allow} ->
        place(state, group.intent, group_id, group.receipt)
    end
  end

  # Dropped from the parked map whatever the journal says: without its
  # receipt the group can never reach `placing`.
  defp finish_parked(state, token, entry) do
    case Map.pop(state.parked, token) do
      {nil, _parked} -> {:reply, {:error, {:not_parked, token}}, state}
      {_group, parked} -> {:reply, append(state, token, entry), %{state | parked: parked}}
    end
  end

  defp place(state, intent, group_id, receipt) do
    env = %{
      port: state.port,
      journal: state.journal,
      account: state.account,
      timeout: state.place_timeout
    }

    reply =
      case Place.run(receipt, intent, group_id, env) do
        {:ok, status, response} ->
          {:ok, %{group_id: group_id, status: status, response: response, journaled: true}}

        {:error, {:order_unjournaled, status, response, reason}} ->
          {:ok,
           %{
             group_id: group_id,
             status: status,
             response: response,
             journaled: false,
             journal_error: reason
           }}

        # `placing` was refused, the receipt failed, or the intent has no
        # order tool: nothing was sent.
        {:error, reason} ->
          _ = close_group(state, group_id, :placing_refused)
          {:error, reason}
      end

    {:reply, reply, state}
  end

  # -- Context and journal ------------------------------------------------------

  # The window is a rolling 24 hours back from this executor's clock; no
  # caller input moves it.
  defp fill(state, %Context{} = context) do
    now = state.clock.()
    day_start = DateTime.add(now, -24, :hour)

    with {:ok, notional} <- safe(fn -> Journal.today_notional(day_start, state.journal) end),
         {:ok, count} <- safe(fn -> Journal.orders_last_minute(now, state.journal) end) do
      {:ok,
       %{context | policy: state.policy, today_notional: notional, orders_last_minute: count}}
    else
      {:error, reason} -> {:error, {:context, reason}}
    end
  end

  defp close_group(state, group_id, reason) do
    with {:error, error} <- append(state, group_id, {:close, reason}) do
      Logger.warning(
        "[Broker.Executor] could not close group #{group_id} (#{reason}): #{inspect(error)}"
      )

      {:error, error}
    end
  end

  defp append(state, group_id, entry),
    do: safe(fn -> Journal.append_to_group(group_id, entry, state.journal) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end
end
