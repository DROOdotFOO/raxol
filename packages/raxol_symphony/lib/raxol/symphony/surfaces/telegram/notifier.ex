defmodule Raxol.Symphony.Surfaces.Telegram.Notifier do
  @moduledoc """
  Subscribes to a `Raxol.Symphony.Orchestrator` and pushes formatted
  messages to one or more Telegram chats on every interesting event.

  Uses `Raxol.Symphony.Surfaces.Telegram.Formatter` for message bodies. A
  pluggable `:send_fn` makes the GenServer testable without `Telegex`:

      Notifier.start_link(
        orchestrator: my_orch,
        chat_ids: [123456],
        send_fn: fn chat_id, text, keyboard -> send(parent, {:tg, chat_id, text, keyboard}); :ok end
      )

  In production the default `send_fn` calls `Telegex.send_message/3` with
  `parse_mode: "HTML"`. When `Telegex` is not loaded, sends are dropped and
  a single warning is logged at startup.

  ## Filtered events

  `:tick_completed` is suppressed by default (the formatter returns `:skip`
  for it) to avoid one notification per second. Pass `:include_ticks?` to
  re-enable for debugging.
  """

  use Raxol.Core.Behaviours.BaseManager
  require Logger

  alias Raxol.Symphony.Orchestrator
  alias Raxol.Symphony.Surfaces.Telegram.Formatter

  @compile {:no_warn_undefined, [Telegex]}

  @type state :: %{
          orchestrator: GenServer.server(),
          chat_ids: [integer() | String.t()],
          send_fn: (integer() | String.t(), String.t(), Formatter.keyboard() -> any()),
          include_ticks?: boolean()
        }

  # -- Public API -------------------------------------------------------------

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Manually push a snapshot to all configured chats. Useful for `/status` commands."
  @spec push_snapshot(GenServer.server()) :: :ok
  def push_snapshot(server \\ __MODULE__) do
    GenServer.cast(server, :push_snapshot)
  end

  @doc "Returns the configured chat ids and orchestrator. Test introspection."
  @spec config(GenServer.server()) :: state()
  def config(server \\ __MODULE__) do
    GenServer.call(server, :config)
  end

  @doc """
  Dispatch a `sym:`-namespace callback string from a Telegram
  inline-keyboard tap.

  Mirrors `Raxol.Symphony.Surfaces.Watch.Notifier.handle_action/2`:
  parses via `Raxol.Symphony.OperatorCallback` and dispatches to the
  orchestrator (refresh / stop / resume) or the notifier (list /
  per-run detail message push).

  ## Options

    * `:orchestrator` -- orchestrator pid or name; defaults to
      `Raxol.Symphony.Orchestrator`.
    * `:notifier` -- notifier pid or name for callbacks that push
      a message (`sym:list`, `sym:run:<id>`); defaults to
      `__MODULE__`. Pass `nil` to make those callbacks `:noop`.

  ## Return shape

      :noop
      | {:ok, :refresh | :listed | :stopped | {:resumed, decision} | {:run_pushed, id}}
      | {:error, :not_running | :not_paused | :orchestrator_unavailable}
  """
  @spec handle_callback(binary(), keyword()) ::
          :noop
          | {:ok,
             :refresh
             | :listed
             | :stopped
             | {:resumed, binary()}
             | {:run_pushed, binary()}}
          | {:error, atom()}
  def handle_callback(callback_data, opts \\ []) when is_binary(callback_data) do
    orch = Keyword.get(opts, :orchestrator, Raxol.Symphony.Orchestrator)
    notifier = Keyword.get(opts, :notifier, __MODULE__)

    callback_data
    |> Raxol.Symphony.OperatorCallback.parse()
    |> dispatch(orch, notifier)
  end

  defp dispatch(:refresh, orch, _notifier), do: do_refresh(orch)
  defp dispatch(:list, orch, notifier), do: do_list(orch, notifier)
  defp dispatch(:dismiss, _orch, _notifier), do: :noop
  defp dispatch({:stop, id}, orch, _notifier), do: do_stop(orch, id)
  defp dispatch({:run_detail, id}, orch, notifier), do: do_run_detail(orch, notifier, id)
  defp dispatch({:approve, _id}, _orch, _notifier), do: :noop
  defp dispatch({:resume, id, decision}, orch, _notifier), do: do_resume(orch, id, decision)
  defp dispatch({:unknown, _raw}, _orch, _notifier), do: :noop

  defp do_refresh(orch) do
    _ = safe_call(fn -> Orchestrator.refresh(orch) end)
    {:ok, :refresh}
  end

  defp do_list(_orch, nil), do: :noop

  defp do_list(_orch, notifier) do
    case safe_call(fn -> push_snapshot(notifier) end) do
      {:ok, _} -> {:ok, :listed}
      _ -> {:error, :notifier_unavailable}
    end
  end

  defp do_stop(orch, id) do
    case safe_call(fn -> Orchestrator.stop_run(orch, id) end) do
      {:ok, :ok} -> {:ok, :stopped}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  defp do_resume(orch, id, decision) do
    case safe_call(fn -> Orchestrator.resume_run(orch, id, decision) end) do
      {:ok, :ok} -> {:ok, {:resumed, decision}}
      {:ok, {:error, reason}} -> {:error, reason}
      _ -> {:error, :orchestrator_unavailable}
    end
  end

  defp do_run_detail(_orch, nil, _id), do: :noop

  defp do_run_detail(orch, notifier, id) do
    case safe_call(fn -> Orchestrator.snapshot(orch) end) do
      {:ok, snapshot} ->
        entry =
          (snapshot[:running] || []) ++ (snapshot[:paused] || []) ++ (snapshot[:retrying] || [])
          |> Enum.find(&(Map.get(&1, :issue_id) == id))

        if entry do
          GenServer.cast(notifier, {:push_run_detail, entry})
          {:ok, {:run_pushed, id}}
        else
          {:error, :not_found}
        end

      _ ->
        {:error, :orchestrator_unavailable}
    end
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    orch = Keyword.get(opts, :orchestrator, Raxol.Symphony.Orchestrator)
    chat_ids = Keyword.get(opts, :chat_ids, [])
    send_fn = Keyword.get(opts, :send_fn, &default_send/3)

    state = %{
      orchestrator: orch,
      chat_ids: chat_ids,
      send_fn: send_fn,
      include_ticks?: Keyword.get(opts, :include_ticks?, false)
    }

    # Subscribe synchronously in init/1 so callers can race-free trigger
    # orchestrator events as soon as start_link returns.
    case safe_call(fn -> Orchestrator.subscribe(orch) end) do
      {:ok, :ok} ->
        :ok

      _ ->
        Logger.warning(
          "symphony.telegram.subscribe_failed orchestrator=#{inspect(orch)}"
        )
    end

    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:config, _from, state), do: {:reply, state, state}

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast(:push_snapshot, state) do
    snapshot = safe_snapshot(state.orchestrator)
    {text, keyboard} = Formatter.snapshot_message(snapshot)
    broadcast(state, text, keyboard)
    {:noreply, state}
  end

  def handle_manager_cast({:push_run_detail, entry}, state) do
    {text, keyboard} =
      case Map.get(entry, :interrupt_reason) do
        nil -> Formatter.run_message(entry)
        _reason -> Formatter.paused_run_message(entry)
      end

    broadcast(state, text, keyboard)
    {:noreply, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info({:symphony_event, name, snapshot}, state) do
    handle_event(state, name, snapshot)
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # -- Internals --------------------------------------------------------------

  defp handle_event(%{include_ticks?: true} = state, :tick_completed, snapshot) do
    {text, keyboard} = Formatter.snapshot_message(snapshot)
    broadcast(state, text, keyboard)
    {:noreply, state}
  end

  defp handle_event(state, :tick_completed, _snapshot), do: {:noreply, state}

  defp handle_event(state, name, snapshot) do
    case Formatter.event_message(name, snapshot) do
      :skip ->
        :ok

      {text, keyboard} ->
        broadcast(state, text, keyboard)
    end

    {:noreply, state}
  end

  defp broadcast(%{chat_ids: []}, _text, _kb), do: :ok

  defp broadcast(%{chat_ids: chat_ids, send_fn: send_fn}, text, keyboard) do
    Enum.each(chat_ids, fn chat_id ->
      try do
        send_fn.(chat_id, text, keyboard)
      catch
        kind, reason ->
          Logger.warning(
            "symphony.telegram.send_failed chat_id=#{inspect(chat_id)} " <>
              "kind=#{inspect(kind)} reason=#{inspect(reason)}"
          )
      end
    end)

    :ok
  end

  defp safe_snapshot(orch) do
    case safe_call(fn -> Orchestrator.snapshot(orch) end) do
      {:ok, %{} = snap} -> snap
      _ -> %{counts: %{running: 0, retrying: 0}, running: [], retrying: [], generated_at: nil}
    end
  end

  defp safe_call(fun) do
    {:ok, fun.()}
  catch
    :exit, _ -> :error
    :error, _ -> :error
  end

  defp default_send(chat_id, text, keyboard) do
    if Code.ensure_loaded?(Telegex) do
      Telegex.send_message(chat_id, text,
        parse_mode: "HTML",
        reply_markup: %{inline_keyboard: keyboard}
      )
    else
      Logger.debug(
        "symphony.telegram.send_skipped (Telegex not loaded) chat_id=#{inspect(chat_id)}"
      )

      :ok
    end
  end
end
