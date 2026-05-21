defmodule Raxol.Telegram.Bot do
  @moduledoc """
  Telegram bot update handler.

  Routes incoming Telegram updates (messages, callback queries) to
  the SessionRouter. Handles `/start` and `/stop` commands directly.

  This module provides `handle_update/2` which can be called from
  a Telegex polling loop or webhook handler.

  ## Access Control

  Pass `allowed_chat_ids: [id1, id2]` to restrict which chats can
  interact with the bot. When set, updates from unlisted chats are
  silently ignored. When omitted or `nil`, all chats are allowed.
  """

  alias Raxol.Telegram.{InputAdapter, SessionRouter}

  require Logger

  @compile {:no_warn_undefined, [Telegex]}

  @doc """
  Processes a Telegram update.

  Dispatches messages and callback queries to the appropriate session.

  ## Options

    * `:allowed_chat_ids` - list of allowed chat IDs (nil = allow all)
  """
  @spec handle_update(map(), keyword()) :: :ok | {:error, term()}
  def handle_update(update, opts \\ [])

  def handle_update(
        %{callback_query: %{data: data, message: %{chat: %{id: chat_id}}} = query},
        opts
      ) do
    if chat_allowed?(chat_id, opts) do
      safe_answer_callback_query(query.id)
      emit(:received, %{chat_id: chat_id, kind: :callback, data: data})

      case InputAdapter.translate_callback(data) do
        nil -> :ok
        event -> SessionRouter.route(chat_id, event)
      end
    else
      emit(:denied, %{chat_id: chat_id, kind: :callback})
      :ok
    end
  end

  def handle_update(%{message: %{text: text, chat: %{id: chat_id}}}, opts) when is_binary(text) do
    if chat_allowed?(chat_id, opts) do
      emit(:received, %{chat_id: chat_id, kind: :message, byte_size: byte_size(text)})

      case InputAdapter.translate_text(text) do
        {:command, "start"} ->
          SessionRouter.start_session(chat_id)
          :ok

        {:command, "stop"} ->
          SessionRouter.stop_session(chat_id)
          :ok

        {:command, _} ->
          :ok

        nil ->
          :ok

        event ->
          SessionRouter.route(chat_id, event)
      end
    else
      emit(:denied, %{chat_id: chat_id, kind: :message})
      :ok
    end
  end

  def handle_update(_, _opts), do: :ok

  defp emit(event, metadata) do
    :telemetry.execute(
      [:raxol_telegram, :bot, event],
      %{system_time: System.system_time()},
      metadata
    )
  end

  # Telegex may raise (e.g., Finch not started in tests). The callback ack
  # is best-effort -- a missed ack only means the in-chat "loading" spinner
  # keeps spinning briefly. Never let it crash the update handler.
  defp safe_answer_callback_query(query_id) do
    if Code.ensure_loaded?(Telegex) do
      try do
        Telegex.answer_callback_query(query_id)
      rescue
        e ->
          Logger.warning("Telegex.answer_callback_query failed: #{Exception.message(e)}")
      catch
        kind, reason ->
          Logger.warning("Telegex.answer_callback_query exited with #{inspect({kind, reason})}")
      end
    end
  end

  defp chat_allowed?(chat_id, opts) do
    case Keyword.get(opts, :allowed_chat_ids) do
      nil ->
        true

      ids when is_list(ids) ->
        Enum.member?(ids, chat_id)

      other ->
        Logger.warning(
          "Raxol.Telegram.Bot: :allowed_chat_ids must be a list or nil, got #{inspect(other)}. Denying request from chat #{chat_id}."
        )

        false
    end
  end
end
