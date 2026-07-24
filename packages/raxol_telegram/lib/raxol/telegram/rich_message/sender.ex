defmodule Raxol.Telegram.RichMessage.Sender do
  @moduledoc """
  HTTP sender for Bot API 10.1 `sendRichMessage`.

  Telegex 1.8 predates Bot API 10.1, so this module calls the API directly
  via the optional `:req` dependency. When `:req` is absent and no
  `:post_fn` is provided, `send/3` returns `{:error, :req_not_available}`.

  ## Configuration

      config :raxol_telegram,
        bot_token: System.get_env("TELEGRAM_BOT_TOKEN"),
        api_base: "https://api.telegram.org"

  Per-call options override config. Pass a self-hosted Bot API base via
  `:api_base` for high-volume deployments (see
  [gramiojs/telegram-bot-api](https://github.com/gramiojs/telegram-bot-api)).

  ## Telemetry

  Emits `[:raxol_telegram, :rich_message, :sent]` on success and
  `[:raxol_telegram, :rich_message, :error]` on failure. Both carry
  `chat_id`, `byte_size` (of the encoded payload), and `chunked?` metadata.
  """

  alias Raxol.Telegram.{HTTP, RichMessage}

  @type send_opts :: [
          bot_token: String.t(),
          api_base: String.t(),
          timeout: pos_integer(),
          reply_markup: map(),
          disable_notification: boolean(),
          reply_to_message_id: integer(),
          chunk: boolean(),
          chunk_opts: keyword(),
          post_fn: (String.t(), keyword() -> {:ok, map()} | {:error, term()})
        ]

  @doc """
  Sends a rich message via `sendRichMessage`.

  Applies Show More chunking by default. Disable with `chunk: false`.

  ## Options

    * `:bot_token`: bot token (defaults to `:raxol_telegram` app env)
    * `:api_base`: Bot API base URL (defaults to config or telegram.org)
    * `:timeout`: request timeout in ms (default 10,000)
    * `:reply_markup`: inline keyboard map
    * `:disable_notification`: bool
    * `:reply_to_message_id`: integer
    * `:chunk`: bool, default `true`
    * `:chunk_opts`: keyword passed to `RichMessage.chunk/2`
    * `:post_fn`: 2-arity `(url, req_opts) -> {:ok, %{status, body}} | {:error, _}`
      override for tests or alternative HTTP clients
  """
  @spec send(integer() | String.t(), RichMessage.rich_message(), send_opts()) ::
          {:ok, map()} | {:error, term()}
  def send(chat_id, rich_message, opts \\ []) do
    with {:ok, prepared, chunked?} <- maybe_chunk(rich_message, opts) do
      payload = RichMessage.to_payload(chat_id, prepared, opts)
      result = HTTP.post("sendRichMessage", payload, opts)
      emit_result(result, chat_id, payload, chunked?)
      result
    end
  end

  defp maybe_chunk(rich_message, opts) do
    if Keyword.get(opts, :chunk, true) do
      case RichMessage.chunk(rich_message, Keyword.get(opts, :chunk_opts, [])) do
        {:ok, ^rich_message} -> {:ok, rich_message, false}
        {:ok, chunked} -> {:ok, chunked, true}
        {:error, _} = err -> err
      end
    else
      {:ok, rich_message, false}
    end
  end

  defp emit_result({:ok, _}, chat_id, payload, chunked?),
    do: emit_sent(chat_id, payload, chunked?)

  defp emit_result({:error, reason}, chat_id, payload, chunked?),
    do: emit_error(chat_id, payload, chunked?, reason)

  defp emit_sent(chat_id, payload, chunked?) do
    :telemetry.execute(
      [:raxol_telegram, :rich_message, :sent],
      %{system_time: System.system_time(), byte_size: payload_bytes(payload)},
      %{chat_id: chat_id, chunked?: chunked?}
    )
  end

  defp emit_error(chat_id, payload, chunked?, reason) do
    :telemetry.execute(
      [:raxol_telegram, :rich_message, :error],
      %{system_time: System.system_time(), byte_size: payload_bytes(payload)},
      %{chat_id: chat_id, chunked?: chunked?, reason: reason}
    )
  end

  defp payload_bytes(payload) do
    case Jason.encode(payload) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _} -> 0
    end
  end
end
