defmodule Raxol.Gateway.Adapter.Discord do
  @moduledoc """
  `Raxol.Gateway.Adapter` implementation for Discord.

  Owns only platform I/O and translation: `MESSAGE_CREATE` dispatches
  normalize to the gateway's `%{text: binary}` event shape (what
  `Raxol.Gateway.Handler.Agent` consumes), and rendered replies go out as
  plain-text `POST /channels/:id/messages` REST calls.

  Deliberately out of scope here:

    * Event feeding: pair with
      `Raxol.Gateway.Adapter.Discord.GatewaySocket`, whose `:on_event`
      passes raw dispatch frames to `normalize_event/1`.
    * Authorization: `normalize_event/1` is a pure translator; check
      `Raxol.Gateway.Pairing.authorize/2` in the feed loop before routing.
    * Non-text dispatches (embeds, attachments, reactions, threads):
      `:ignore` for now.

  ## Connection

  `connect/1` requires `:bot_token` and accepts `:api_base` (default
  `https://discord.com/api/v10`), `:timeout`, and `:post_fn` (a 2-arity
  `(url, req_opts) -> {:ok, %{status:, body:}} | {:error, term}` override
  for tests or alternative HTTP clients, the same shape
  `Raxol.Telegram.HTTP` uses; the default uses the optional `Req`
  dependency). The connection is stateless HTTP; the returned handle is
  the validated option list.

  ## Inbound

  Frames authored by bots (including this one) are ignored, so an agent
  can never be goaded into a bot-to-bot reply loop. Messages with a
  `guild_id` route as `chat_type: :guild`, the rest as `:dm`; `chat_id`
  is the channel id either way, which is exactly where the reply goes.

  ## Outbound

  Replies are chunked against Discord's 2000-character message limit,
  which counts Unicode code points - not UTF-16 units (Telegram) and not
  graphemes. Chunking is grapheme-safe. Empty or whitespace-only replies
  are a no-op. Failures emit `[:raxol_gateway, :discord_adapter, :error]`
  telemetry with the classified reason; the bot token travels in an
  Authorization header and is never part of a URL or log line.
  """

  @behaviour Raxol.Gateway.Adapter

  @compile {:no_warn_undefined, [Req]}

  alias Raxol.Gateway.Route

  @default_api_base "https://discord.com/api/v10"
  @default_timeout 10_000
  @max_message_codepoints 2000

  @impl true
  @spec connect(keyword() | map()) ::
          {:ok, keyword()} | {:error, :no_bot_token | :invalid_config}
  def connect(config) when is_list(config) do
    if Keyword.keyword?(config) do
      validate_conn(config)
    else
      {:error, :invalid_config}
    end
  end

  def connect(config) when is_map(config) do
    if Enum.all?(Map.keys(config), &is_atom/1) do
      config |> Keyword.new() |> validate_conn()
    else
      {:error, :invalid_config}
    end
  end

  def connect(_config), do: {:error, :invalid_config}

  defp validate_conn(opts) do
    case Keyword.get(opts, :bot_token) do
      token when is_binary(token) and token != "" -> {:ok, opts}
      _other -> {:error, :no_bot_token}
    end
  end

  @impl true
  @spec disconnect(keyword()) :: :ok
  def disconnect(_conn), do: :ok

  @impl true
  @spec platform() :: :discord
  def platform, do: :discord

  @impl true
  @spec normalize_event(term()) ::
          {:ok, Route.t(), %{text: String.t()}} | :ignore
  def normalize_event(%{
        "t" => "MESSAGE_CREATE",
        "d" =>
          %{
            "content" => content,
            "channel_id" => channel_id,
            "author" => %{"id" => user_id} = author
          } = message
      })
      when is_binary(content) and content != "" do
    if author["bot"] == true do
      :ignore
    else
      route =
        Route.new(%{
          platform: :discord,
          chat_type: chat_type(message),
          chat_id: channel_id,
          user_id: user_id
        })

      {:ok, route, %{text: content}}
    end
  end

  def normalize_event(_raw), do: :ignore

  @impl true
  @spec send_message(keyword(), Route.t() | map(), term()) ::
          :ok | {:error, term()}
  def send_message(conn, %{chat_id: channel_id}, rendered)
      when is_binary(rendered) do
    cond do
      not String.valid?(rendered) ->
        {:error, :invalid_encoding}

      String.trim(rendered) == "" ->
        :ok

      true ->
        rendered
        |> chunk_text(@max_message_codepoints)
        |> send_chunks(conn, channel_id)
    end
  end

  def send_message(_conn, _route, _rendered),
    do: {:error, :unsupported_rendered}

  defp send_chunks(chunks, conn, channel_id) do
    Enum.reduce_while(chunks, :ok, fn chunk, :ok ->
      send_chunk(chunk, conn, channel_id)
    end)
  end

  # Discord rejects empty content with a 400 that would halt the remaining
  # chunks; a boundary landing inside a whitespace run is skipped.
  defp send_chunk(chunk, conn, channel_id) do
    if String.trim(chunk) == "" do
      {:cont, :ok}
    else
      case post_message(conn, channel_id, chunk) do
        {:ok, _result} ->
          {:cont, :ok}

        {:error, reason} ->
          emit_error("create_message", reason)
          {:halt, {:error, reason}}
      end
    end
  end

  defp post_message(conn, channel_id, content) do
    token = Keyword.fetch!(conn, :bot_token)
    base = Keyword.get(conn, :api_base, @default_api_base)
    timeout = Keyword.get(conn, :timeout, @default_timeout)
    post_fn = Keyword.get(conn, :post_fn, &default_post/2)

    url = "#{base}/channels/#{channel_id}/messages"

    url
    |> post_fn.(
      json: %{content: content},
      headers: [{"authorization", "Bot " <> token}],
      receive_timeout: timeout
    )
    |> classify()
  end

  defp classify({:ok, %{status: status, body: body}})
       when status in 200..299,
       do: {:ok, body}

  defp classify({:ok, %{status: status, body: body}}),
    do: {:error, {:discord_api_error, status, body}}

  defp classify({:error, :req_not_available}), do: {:error, :req_not_available}
  defp classify({:error, reason}), do: {:error, {:http_error, reason}}

  defp default_post(url, req_opts) do
    if Code.ensure_loaded?(Req) do
      Req.post(url, req_opts)
    else
      {:error, :req_not_available}
    end
  end

  defp chat_type(%{"guild_id" => guild_id}) when is_binary(guild_id), do: :guild
  defp chat_type(_message), do: :dm

  # Discord counts Unicode code points; a grapheme is never split, a
  # message at the code-point budget always. The one exception: a single
  # pathological grapheme cluster larger than the whole budget (combining
  # mark floods) is pre-split at code-point level so no chunk can exceed it.
  defp chunk_text(text, max_codepoints) do
    {chunks, last, _count} =
      text
      |> String.graphemes()
      |> Enum.flat_map(&split_oversized(&1, max_codepoints))
      |> Enum.reduce({[], [], 0}, &accumulate_grapheme(&1, &2, max_codepoints))

    [finish_chunk(last) | chunks] |> Enum.reverse()
  end

  defp accumulate_grapheme(grapheme, {chunks, current, count}, max_codepoints) do
    grapheme_count = codepoint_count(grapheme)

    if count + grapheme_count > max_codepoints and current != [] do
      {[finish_chunk(current) | chunks], [grapheme], grapheme_count}
    else
      {chunks, [grapheme | current], count + grapheme_count}
    end
  end

  defp split_oversized(grapheme, max_codepoints) do
    if codepoint_count(grapheme) > max_codepoints do
      String.codepoints(grapheme)
    else
      [grapheme]
    end
  end

  defp finish_chunk(reversed_graphemes) do
    reversed_graphemes |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp codepoint_count(grapheme), do: length(String.codepoints(grapheme))

  defp emit_error(method, reason) do
    :telemetry.execute(
      [:raxol_gateway, :discord_adapter, :error],
      %{count: 1},
      %{method: method, reason: reason}
    )
  end
end
