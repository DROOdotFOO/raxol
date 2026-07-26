# Compiled only when the optional :raxol_gateway dependency is present: the
# @behaviour needs Raxol.Gateway.Adapter at compile time. A consumer adding
# raxol_gateway later must `mix deps.compile raxol_telegram --force`.
if Code.ensure_loaded?(Raxol.Gateway.Adapter) do
  defmodule Raxol.Telegram.GatewayAdapter do
    @moduledoc """
    `Raxol.Gateway.Adapter` implementation for Telegram.

    Owns only platform I/O and translation: text messages normalize to the
    gateway's `%{text: binary}` event shape (what `Raxol.Gateway.Handler.Agent`
    consumes), voice notes to `%{media: %{kind: :voice, ref: file_id, ...}}`
    (what `Raxol.Gateway.Pipeline.Transcribe` consumes, with `fetch_media/2`
    as its `:fetch_fn`), and rendered replies go out as plain-text
    `sendMessage` calls through `Raxol.Telegram.HTTP`.

    Deliberately out of scope here:

      * Update feeding: pair with `Raxol.Telegram.UpdatePoller` (long polling)
        or a webhook that passes raw updates to `normalize_event/1`.
      * Authorization: `normalize_event/1` is a pure translator; check
        `allowed_chat_ids` / `Raxol.Gateway.Pairing.authorize/2` in the feed
        loop before routing.
      * Transcription: a voice note normalizes to an opaque media reference;
        turning it into text is `Raxol.Gateway.Pipeline.Transcribe`'s job in
        the feed loop.
      * Other non-text updates (callbacks, photos, join requests): `:ignore`
        for now; commands pass through as ordinary text.

    ## Connection

    `connect/1` takes the same options `Raxol.Telegram.HTTP.post/3` accepts
    (`:bot_token`, `:api_base`, `:post_fn`, ...) and fails fast without a
    token. The connection is stateless HTTP; the returned handle is the
    validated option list.

    ## Outbound

    Replies are chunked against Telegram's 4096 UTF-16-code-unit message
    limit (grapheme-safe). Empty or whitespace-only replies are a no-op.
    Failures emit `[:raxol_telegram, :gateway_adapter, :error]` telemetry
    with the method and classified reason only (never the URL, which embeds
    the bot token).
    """

    @behaviour Raxol.Gateway.Adapter

    alias Raxol.Gateway.Route
    alias Raxol.Telegram.HTTP

    @chat_types %{
      "private" => :private,
      "group" => :group,
      "supergroup" => :supergroup,
      "channel" => :channel
    }

    @max_message_utf16_units 4096

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
      with {:ok, _token} <- HTTP.fetch_token(opts) do
        {:ok, opts}
      end
    end

    @impl true
    @spec disconnect(keyword()) :: :ok
    def disconnect(_conn), do: :ok

    @impl true
    @spec platform() :: :telegram
    def platform, do: :telegram

    @impl true
    @spec normalize_event(term()) ::
            {:ok, Route.t(), %{text: String.t()} | %{media: map()}} | :ignore
    def normalize_event(%{message: %{text: text, chat: %{id: chat_id, type: type}} = msg})
        when is_binary(text) and text != "" do
      build_event(%{text: text}, chat_id, type, atom_user_id(msg))
    end

    def normalize_event(%{
          "message" => %{"text" => text, "chat" => %{"id" => chat_id, "type" => type}} = msg
        })
        when is_binary(text) and text != "" do
      build_event(%{text: text}, chat_id, type, string_user_id(msg))
    end

    def normalize_event(%{
          message: %{voice: %{file_id: file_id} = voice, chat: %{id: chat_id, type: type}} = msg
        })
        when is_binary(file_id) and file_id != "" do
      build_event(%{media: voice_media(voice)}, chat_id, type, atom_user_id(msg))
    end

    def normalize_event(%{
          "message" =>
            %{
              "voice" => %{"file_id" => file_id} = voice,
              "chat" => %{"id" => chat_id, "type" => type}
            } =
              msg
        })
        when is_binary(file_id) and file_id != "" do
      build_event(%{media: voice_media(voice)}, chat_id, type, string_user_id(msg))
    end

    def normalize_event(_raw), do: :ignore

    @doc """
    Downloads the audio behind a normalized voice event's media `:ref`.

    Wire it as `Raxol.Gateway.Pipeline.Transcribe`'s `:fetch_fn`:

        fetch_fn: fn media -> Raxol.Telegram.GatewayAdapter.fetch_media(conn, media) end
    """
    @spec fetch_media(keyword(), map()) :: {:ok, binary()} | {:error, term()}
    def fetch_media(conn, %{ref: file_id}) when is_binary(file_id),
      do: HTTP.download_file(file_id, conn)

    def fetch_media(_conn, _media), do: {:error, :unsupported_media}

    @impl true
    @spec send_message(keyword(), Route.t() | map(), term()) :: :ok | {:error, term()}
    def send_message(conn, %{chat_id: chat_id}, rendered) when is_binary(rendered) do
      cond do
        not String.valid?(rendered) -> {:error, :invalid_encoding}
        String.trim(rendered) == "" -> :ok
        true -> rendered |> chunk_text(@max_message_utf16_units) |> send_chunks(conn, chat_id)
      end
    end

    def send_message(_conn, _route, _rendered), do: {:error, :unsupported_rendered}

    defp send_chunks(chunks, conn, chat_id) do
      Enum.reduce_while(chunks, :ok, fn chunk, :ok -> send_chunk(chunk, conn, chat_id) end)
    end

    # Telegram rejects whitespace-only messages with a 400 that would halt the
    # remaining chunks; a boundary landing inside a whitespace run is skipped.
    defp send_chunk(chunk, conn, chat_id) do
      if String.trim(chunk) == "" do
        {:cont, :ok}
      else
        case HTTP.post("sendMessage", %{chat_id: chat_id, text: chunk}, conn) do
          {:ok, _result} ->
            {:cont, :ok}

          {:error, reason} ->
            emit_error("sendMessage", reason)
            {:halt, {:error, reason}}
        end
      end
    end

    defp build_event(event, chat_id, type, user_id) do
      case Map.fetch(@chat_types, type) do
        {:ok, chat_type} ->
          route =
            Route.new(%{
              platform: :telegram,
              chat_type: chat_type,
              chat_id: chat_id,
              user_id: user_id
            })

          {:ok, route, event}

        :error ->
          :ignore
      end
    end

    # Map.get (not Access, which raises on Telegex structs) returns nil for
    # the other key style, so one helper serves both update shapes.
    defp voice_media(voice) do
      %{
        kind: :voice,
        ref: Map.get(voice, :file_id) || Map.get(voice, "file_id"),
        mime: Map.get(voice, :mime_type) || Map.get(voice, "mime_type"),
        duration_s: Map.get(voice, :duration) || Map.get(voice, "duration"),
        size_bytes: Map.get(voice, :file_size) || Map.get(voice, "file_size")
      }
    end

    defp atom_user_id(%{from: %{id: id}}), do: id
    defp atom_user_id(_msg), do: nil

    defp string_user_id(%{"from" => %{"id" => id}}), do: id
    defp string_user_id(_msg), do: nil

    # Telegram counts UTF-16 code units, not graphemes; a grapheme is split
    # never, a message at the unit budget always. The one exception: a single
    # pathological grapheme cluster larger than the whole budget (combining
    # mark floods) is pre-split at codepoint level so no chunk can exceed it.
    defp chunk_text(text, max_units) do
      {chunks, last, _units} =
        text
        |> String.graphemes()
        |> Enum.flat_map(&split_oversized(&1, max_units))
        |> Enum.reduce({[], [], 0}, &accumulate_grapheme(&1, &2, max_units))

      [finish_chunk(last) | chunks] |> Enum.reverse()
    end

    defp accumulate_grapheme(grapheme, {chunks, current, units}, max_units) do
      grapheme_units = utf16_units(grapheme)

      if units + grapheme_units > max_units and current != [] do
        {[finish_chunk(current) | chunks], [grapheme], grapheme_units}
      else
        {chunks, [grapheme | current], units + grapheme_units}
      end
    end

    defp split_oversized(grapheme, max_units) do
      if utf16_units(grapheme) > max_units do
        String.codepoints(grapheme)
      else
        [grapheme]
      end
    end

    defp finish_chunk(reversed_graphemes) do
      reversed_graphemes |> Enum.reverse() |> IO.iodata_to_binary()
    end

    defp utf16_units(grapheme) do
      grapheme
      |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
      |> byte_size()
      |> div(2)
    end

    defp emit_error(method, reason) do
      :telemetry.execute(
        [:raxol_telegram, :gateway_adapter, :error],
        %{count: 1},
        %{method: method, reason: reason}
      )
    end
  end
end
