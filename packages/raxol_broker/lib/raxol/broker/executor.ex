defmodule Raxol.Broker.Executor do
  @moduledoc """
  The one path every order takes: intent, policy, `review_*`, policy again,
  `placing`, `place_*`, each step journaled before the next one runs.

      run(intent, context)
        open_group       intent + context (counters read from the journal)
        verdict          :pre_review; DENY ends here
        review           the review tool's response; its warnings feed the context
        verdict          :post_review; DENY ends here, ASK parks the group
        [approval]       approve/3 or decline/3 on a parked group
        placing          Raxol.Broker.Executor.Place, with the ReviewReceipt
        order            :placed | :failed | :unknown

  ## Guards

  Everything is re-checked here, whatever the caller did:

    * Decisions are serialized through this process, and `today_notional`
      and `orders_last_minute` in the caller's context are overwritten from
      `Raxol.Broker.Journal` at decision time, so two callers cannot both
      pass the daily cap before either writes `placing`.
    * Review is structurally mandatory: `Raxol.Broker.Executor.Place` is the
      only module that names an order tool, and it needs a
      `Raxol.Broker.Executor.ReviewReceipt` issued here, for the same intent
      and group, under a key this process generates at start.
    * Any journal error, review error, or unknown tool means no order.
    * Idempotency: an intent id that already has a group with a `placing`
      record (any outcome, including a crash closed as
      `crash_outcome_unknown`) returns `{:ok, :duplicate}` and calls
      nothing. Each place also sends a `ref_id` derived from the intent id,
      which Robinhood deduplicates on. Intent ids must be stable for a
      re-run to be recognised: pass `:id` to the `Raxol.Broker.Intent`
      constructor.

  ## ASK

  A post-review ASK parks the group and returns `{:ask, group_id, prompts}`;
  the group id is the token. `approve/3` journals the approval, rebuilds the
  counters from the journal and runs the policy again: a DENY now (the cap
  moved while it was parked) ends the group; an ASK (the questions the human
  just answered) or ALLOW goes on to `placing`. `decline/3` and `close/3`
  end the group. Routing an ASK to a person and denying on timeout are
  #1180's.

  Parked groups live in this process. On start, every group the journal
  still has open is closed with `{:close, :executor_restarted}`, so a group
  parked before a restart cannot be approved after it. Run one executor per
  journal.

  ## Mode

  Only `mode: :dry_run` (the default) runs, and it refuses a port that
  reaches a live brokerage (`{:error, :live_port_in_dry_run}`). The intent
  record carries `"mode": "dry_run"`. `mode: :armed` is `{:error,
  :not_armed}` until arming exists (#1179).

  ## Options

    * `:journal` - the `Raxol.Broker.Journal` server (default that module).
    * `:port` - a started `Raxol.Broker.Executor.Port`, or `:session`, a
      `Raxol.MCP.Client` spec for `Raxol.Broker.Executor.Port.MCP.start/1`.
    * `:account_number` (required) - the account orders are sent for.
    * `:mode` - `:dry_run` (default) or `:armed`.
    * `:clock` - zero-arity function returning the UTC `DateTime` used for
      the counters (default `DateTime.utc_now/0`).
    * `:review_timeout`, `:place_timeout` - per tool call (default 30 s).
    * `:name`.

  `run/4` takes `:day_start`, the UTC instant the exchange day began
  (default: UTC midnight of the clock's now; the New York calendar is
  #1185's).
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Executor.{Place, Port, Review, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.{Intent, Journal, Policy}
  alias Raxol.Broker.Policy.Context

  @default_timeout 30_000

  @type result ::
          {:ok, %{group_id: String.t(), status: Place.status(), response: map()}}
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
  @spec run(GenServer.server(), Intent.t(), Context.t(), keyword()) :: result()
  def run(server, %Intent{} = intent, %Context{} = context, opts \\ []),
    do: GenServer.call(server, {:run, intent, context, opts}, :infinity)

  @doc "Approve a parked ASK; `by` names who approved (non-empty string)."
  @spec approve(GenServer.server(), String.t(), String.t(), keyword()) :: result()
  def approve(server, token, by, opts \\ []) when is_binary(token),
    do: GenServer.call(server, {:approve, token, by, opts}, :infinity)

  @doc "Decline a parked ASK; the group ends as DENY."
  @spec decline(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def decline(server, token, by) when is_binary(token),
    do: GenServer.call(server, {:decline, token, by}, :infinity)

  @doc "Abandon a parked ASK with `{:close, reason}`."
  @spec close(GenServer.server(), String.t(), atom()) :: :ok | {:error, term()}
  def close(server, token, reason) when is_binary(token) and is_atom(reason),
    do: GenServer.call(server, {:close, token, reason}, :infinity)

  @doc "Parked ASKs: `[%{group_id, intent, prompts}]`, oldest first."
  @spec parked(GenServer.server()) :: [map()]
  def parked(server), do: GenServer.call(server, :parked)

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    with :ok <- check_mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, account} <- fetch_account(opts),
         {:ok, port} <- open_port(opts),
         :ok <- check_port(port) do
      state = %{
        journal: Keyword.get(opts, :journal, Journal),
        port: port,
        account: account,
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        review_timeout: Keyword.get(opts, :review_timeout, @default_timeout),
        place_timeout: Keyword.get(opts, :place_timeout, @default_timeout),
        key: :crypto.strong_rand_bytes(32),
        spent: MapSet.new(),
        parked: %{}
      }

      close_orphans(state)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp check_mode(:dry_run), do: :ok
  defp check_mode(:armed), do: {:error, :not_armed}
  defp check_mode(other), do: {:error, {:invalid_mode, other}}

  defp fetch_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) and account != "" -> {:ok, account}
      other -> {:error, {:invalid_account_number, other}}
    end
  end

  defp open_port(opts) do
    case {Keyword.get(opts, :port), Keyword.get(opts, :session)} do
      {{module, _handle} = port, nil} when is_atom(module) -> {:ok, port}
      {nil, spec} when is_list(spec) -> PortMCP.start(spec)
      _ -> {:error, :port_or_session_required}
    end
  end

  defp check_port(port) do
    if Port.live?(port), do: {:error, :live_port_in_dry_run}, else: :ok
  end

  # A group the journal still has open was parked or mid-flight in an
  # executor that is gone; nothing may resume it.
  defp close_orphans(state) do
    case safe(fn -> Journal.open_groups(state.journal) end) do
      {:ok, ids} ->
        Enum.each(ids, &append(state, &1, {:close, :executor_restarted}))

      {:error, reason} ->
        Logger.warning("[Broker.Executor] could not list open groups: #{inspect(reason)}")
    end
  end

  @impl GenServer
  def handle_call({:run, intent, context, opts}, _from, state) do
    {reply, state} = run_intent(state, intent, context, opts)
    {:reply, reply, state}
  end

  def handle_call({:approve, token, by, opts}, _from, state) do
    case Map.pop(state.parked, token) do
      {nil, _parked} -> {:reply, {:error, {:not_parked, token}}, state}
      {group, parked} -> approved(%{state | parked: parked}, token, group, by, opts)
    end
  end

  def handle_call({:decline, token, by}, _from, state),
    do: finish_parked(state, token, {:approval, :declined, by})

  def handle_call({:close, token, reason}, _from, state),
    do: finish_parked(state, token, {:close, reason})

  def handle_call(:parked, _from, state) do
    list =
      state.parked
      |> Enum.sort_by(fn {_id, group} -> group.seq end)
      |> Enum.map(fn {id, group} ->
        %{group_id: id, intent: group.intent, prompts: group.prompts}
      end)

    {:reply, list, state}
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

  # -- Pipeline -----------------------------------------------------------------

  defp run_intent(state, intent, context, opts) do
    with :ok <- not_parked(state, intent),
         {:ok, nil} <- placed_before(state, intent),
         {:ok, _tool} <- Review.tool(intent),
         {:ok, context} <- fill(state, context, opts),
         {:ok, group_id} <- open(state, intent, context) do
      pre_review(state, intent, context, group_id)
    else
      {:ok, group_id} when is_binary(group_id) -> {{:ok, :duplicate}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

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
      {{:error, reason}, _verdict} -> {{:error, reason}, state}
      {:ok, {:deny, reason}} -> {{:deny, group_id, reason}, state}
      {:ok, _allow_or_ask} -> review(state, intent, context, group_id)
    end
  end

  defp review(state, intent, context, group_id) do
    case Review.run(state.port, intent, state.account, state.review_timeout) do
      {:ok, response, warnings} ->
        reviewed(state, intent, %{context | review_warnings: warnings}, group_id, response)

      {:error, reason} ->
        _ = append(state, group_id, {:close, :review_failed})
        {{:error, reason}, state}
    end
  end

  defp reviewed(state, intent, context, group_id, response) do
    with :ok <- append(state, group_id, {:review, response}),
         receipt = ReviewReceipt.issue(state.key, intent.id, group_id, response),
         verdict = Policy.evaluate(intent, context),
         :ok <- append(state, group_id, {:verdict, :post_review, verdict}) do
      case verdict do
        {:deny, reason} ->
          {{:deny, group_id, reason}, state}

        {:ask, prompts} ->
          group = %{
            intent: intent,
            context: context,
            receipt: receipt,
            prompts: prompts,
            seq: System.unique_integer([:monotonic])
          }

          {{:ask, group_id, prompts}, %{state | parked: Map.put(state.parked, group_id, group)}}

        {:allow, _intent} ->
          place(state, intent, group_id, receipt)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp approved(state, group_id, group, by, opts) do
    with :ok <- append(state, group_id, {:approval, :approved, by}),
         {:ok, context} <- fill(state, group.context, opts),
         verdict = Policy.evaluate(group.intent, context),
         :ok <- append(state, group_id, {:verdict, :post_review, verdict}) do
      case verdict do
        {:deny, reason} -> {:reply, {:deny, group_id, reason}, state}
        _ask_answered_or_allow -> reply(place(state, group.intent, group_id, group.receipt))
      end
    else
      {:error, reason} ->
        _ = append(state, group_id, {:close, :approval_failed})
        {:reply, {:error, reason}, state}
    end
  end

  defp reply({reply, state}), do: {:reply, reply, state}

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
      key: state.key,
      spent: state.spent,
      port: state.port,
      journal: state.journal,
      account: state.account,
      timeout: state.place_timeout
    }

    case Place.run(receipt, intent, group_id, env) do
      {:spent, nonce, outcome} ->
        state = %{state | spent: MapSet.put(state.spent, nonce)}
        {placed(state, group_id, outcome), state}

      {:error, reason} ->
        _ = append(state, group_id, {:close, reason})
        {{:error, reason}, state}
    end
  end

  defp placed(_state, group_id, {:ok, status, response}),
    do: {:ok, %{group_id: group_id, status: status, response: response}}

  defp placed(_state, _group_id, {:error, {:order_unjournaled, _, _} = reason}),
    do: {:error, reason}

  # `placing` was refused or the intent has no order tool: nothing was sent.
  defp placed(state, group_id, {:error, reason}) do
    _ = append(state, group_id, {:close, :placing_refused})
    {:error, reason}
  end

  # -- Context and journal ------------------------------------------------------

  defp fill(state, %Context{} = context, opts) do
    now = state.clock.()
    day_start = Keyword.get_lazy(opts, :day_start, fn -> utc_midnight(now) end)

    with {:ok, notional} <- safe(fn -> Journal.today_notional(day_start, state.journal) end),
         {:ok, count} <- safe(fn -> Journal.orders_last_minute(now, state.journal) end) do
      {:ok, %{context | today_notional: notional, orders_last_minute: count}}
    else
      {:error, reason} -> {:error, {:context, reason}}
    end
  end

  defp utc_midnight(%DateTime{} = now) do
    now |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_date() |> DateTime.new!(~T[00:00:00])
  end

  defp append(state, group_id, entry),
    do: safe(fn -> Journal.append_to_group(group_id, entry, state.journal) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end
end
