defmodule Raxol.Telegram.UpdatePoller do
  @moduledoc """
  Long-polls the Telegram Bot API `getUpdates` endpoint and hands each raw
  update to a caller-supplied function.

  Not to be confused with `Raxol.Telegram.Poll` (Telegram poll/vote message
  builders). This module is the update *feed*: the stateful loop that turns
  the Bot API into a stream of raw update maps. It is sink-agnostic - the
  `:on_update` function decides what an update means. Note the key shapes:
  raw `getUpdates` JSON is string-keyed, which `Raxol.Telegram.GatewayAdapter`
  accepts directly; `Raxol.Telegram.Bot.handle_update/2` matches Telegex's
  atom-keyed structs, so a Bot-driving `:on_update` must decode updates into
  Telegex types first.

  A gateway wiring - authorize BEFORE routing (the adapter is a pure
  translator and checks nothing), and never drop a reject silently (the
  poller advances the offset regardless, so an unlogged reject is permanent
  loss):

      {:ok, conn} = Raxol.Telegram.GatewayAdapter.connect(bot_token: token)

      Raxol.Telegram.UpdatePoller.start_link(
        conn: conn,
        on_update: fn raw ->
          with {:ok, route, event} <- Raxol.Telegram.GatewayAdapter.normalize_event(raw),
               :allow <- Raxol.Gateway.Pairing.authorize(MyPairing, route) do
            case Raxol.Gateway.SessionRouter.route(MyRouter, route, event) do
              :ok -> :ok
              {:error, reason} -> Logger.warning("update rejected: \#{inspect(reason)}")
            end
          else
            :ignore -> :ok
            :deny -> Logger.info("unauthorized telegram chat denied")
          end
        end
      )

  ## Options

    * `:on_update` (required) - 1-arity function called per raw update, in
      order. A crash inside it is caught and logged; the offset still
      advances past the bad update.
    * `:conn` - options for `Raxol.Telegram.HTTP.post/3` (`:bot_token`,
      `:api_base`, `:post_fn`, ...); default `[]` (token from app env)
    * `:poll_timeout_s` - the `getUpdates` long-poll hold in seconds
      (default 30). The HTTP receive timeout is always set strictly above
      it, otherwise every quiet cycle would transport-timeout.
    * `:allowed_updates` - `getUpdates` filter (default `["message"]`)
    * `:dets_path` - file path for durable offset storage; falls back to
      `Application.get_env(:raxol_telegram, :update_poller_dets_path)`.
      Unset means the offset lives in memory only.
    * `:dets_name` - DETS table name for the offset file (default
      `Raxol.Telegram.UpdatePoller.Offset`). Give each poller its own name
      when running several durable pollers in one node.
    * `:name` - optional registered name

  ## Semantics

  The update offset is in-memory by default: a restart re-reads pending
  updates from Telegram, so consumers may see a redelivered update after a
  crash. With `:dets_path` set, the offset is checkpointed to disk after
  each non-empty batch and reloaded on restart, shrinking redelivery to at
  most the last unsynced write window. Redelivery is possible either way;
  consumers that need exactly-once must dedup on `update_id`.
  Transport or Bot API errors back off exponentially (1s doubling, capped at
  30s) and reset on the next success. Errors are logged with the method name
  and classified reason only - never the request URL, which embeds the bot
  token.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Core.ErrorHandling
  alias Raxol.Core.Stores.Dets
  alias Raxol.Telegram.HTTP

  @default_poll_timeout_s 30
  @default_allowed_updates ["message"]
  @receive_timeout_margin_ms 5_000
  @backoff_base_ms 1_000
  @backoff_cap_ms 30_000
  @offset_key :offset

  @impl true
  def init_manager(opts) do
    dets = open_offset_store(opts)

    # terminate/2 (which syncs and closes the DETS file) only runs on a
    # supervisor shutdown when the process traps exits; without persistence
    # the default no-cleanup exit path stays.
    if dets, do: Process.flag(:trap_exit, true)

    state = %{
      conn: Keyword.get(opts, :conn, []),
      on_update: Keyword.fetch!(opts, :on_update),
      poll_timeout_s:
        Keyword.get(opts, :poll_timeout_s, @default_poll_timeout_s),
      allowed_updates:
        Keyword.get(opts, :allowed_updates, @default_allowed_updates),
      offset: load_offset(dets),
      dets: dets,
      failures: 0,
      timer: nil
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_manager_info(:poll, state) do
    state = cancel_backoff(state)

    case HTTP.post("getUpdates", poll_body(state), poll_opts(state)) do
      {:ok, updates} when is_list(updates) ->
        offset =
          Enum.reduce(updates, state.offset, &deliver(&1, &2, state.on_update))

        persist_offset(state, offset)
        send(self(), :poll)
        {:noreply, %{state | offset: offset, failures: 0}}

      {:ok, other} ->
        backoff(state, {:unexpected_result, other})

      {:error, reason} ->
        backoff(state, reason)
    end
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  # Crash and termination reports must never dump the state: :conn carries
  # the bot token.
  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{conn: _conn} = state -> %{state | conn: :redacted}
      other -> other
    end)
  end

  @impl GenServer
  def terminate(_reason, state) do
    Dets.close(state.dets)
    :ok
  end

  defp open_offset_store(opts) do
    case Dets.resolve_path(opts, :raxol_telegram, :update_poller_dets_path) do
      nil ->
        nil

      path ->
        name = Keyword.get(opts, :dets_name, __MODULE__.Offset)
        Dets.open!(name, path, fn _record -> :ok end)
    end
  end

  # A foreign or corrupted record must not poison poll_body: anything but a
  # positive integer restarts from Telegram's pending queue.
  defp load_offset(dets) do
    case Dets.get(dets, @offset_key) do
      offset when is_integer(offset) and offset > 0 -> offset
      _other -> nil
    end
  end

  defp persist_offset(%{offset: same}, same), do: :ok

  defp persist_offset(state, offset),
    do: Dets.put(state.dets, @offset_key, offset)

  defp poll_body(state) do
    body = %{
      timeout: state.poll_timeout_s,
      allowed_updates: state.allowed_updates
    }

    case state.offset do
      nil -> body
      offset -> Map.put(body, :offset, offset)
    end
  end

  # The HTTP receive timeout must exceed the server-side long-poll hold, or
  # every quiet cycle times out at the transport (HTTP.post defaults to 10s).
  defp poll_opts(state) do
    Keyword.put(
      state.conn,
      :timeout,
      state.poll_timeout_s * 1_000 + @receive_timeout_margin_ms
    )
  end

  defp deliver(update, offset, on_update) do
    case ErrorHandling.safe_call(fn -> on_update.(update) end) do
      {:ok, _result} ->
        :ok

      {:error, error} ->
        Logger.warning(
          "update_poller on_update failed for update #{inspect(update_id(update))}: " <>
            inspect(error)
        )
    end

    advance_offset(update, offset)
  end

  defp advance_offset(update, offset) do
    case update_id(update) do
      nil -> offset
      id -> max(id + 1, offset || 0)
    end
  end

  defp update_id(%{"update_id" => id}) when is_integer(id), do: id
  defp update_id(%{update_id: id}) when is_integer(id), do: id
  defp update_id(_update), do: nil

  defp backoff(state, reason) do
    failures = state.failures + 1

    delay =
      min(@backoff_base_ms * Integer.pow(2, failures - 1), @backoff_cap_ms)

    Logger.warning(
      "update_poller getUpdates failed (attempt #{failures}, retry in #{delay}ms): " <>
        inspect(reason)
    )

    timer = Process.send_after(self(), :poll, delay)
    {:noreply, %{state | failures: failures, timer: timer}}
  end

  defp cancel_backoff(%{timer: nil} = state), do: state

  defp cancel_backoff(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
