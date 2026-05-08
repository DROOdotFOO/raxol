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

  use GenServer
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

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(opts) do
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

  @impl true
  def handle_call(:config, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast(:push_snapshot, state) do
    snapshot = safe_snapshot(state.orchestrator)
    {text, keyboard} = Formatter.snapshot_message(snapshot)
    broadcast(state, text, keyboard)
    {:noreply, state}
  end

  @impl true
  def handle_info({:symphony_event, name, snapshot}, state) do
    handle_event(state, name, snapshot)
  end

  def handle_info(_msg, state), do: {:noreply, state}

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
