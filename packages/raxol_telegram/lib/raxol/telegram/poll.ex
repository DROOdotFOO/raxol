defmodule Raxol.Telegram.Poll do
  @moduledoc """
  Builders and Bot API client for Telegram polls, including hyperlinks in
  poll options.

  Telegram's June 2026 release surfaced hyperlinks in poll options as a
  first-class UX (`telegram.org/blog/watch-apps-and-more`). The underlying
  Bot API has supported `text_entities` on `InputPollOption` since earlier;
  this module gives it a typed Elixir-side surface.

  HTTP transport uses `Raxol.Telegram.HTTP` (raw `Req` via the optional dep).
  Telegex 1.8 covers `sendPoll`, but routing through `HTTP` keeps token /
  base / `post_fn` injection consistent with the rest of the package.

  ## Example

      import Raxol.Telegram.Poll

      send_poll(chat_id, "Which doc?",
        [
          "Plain text option",
          link_option("Read ADR-0014", "https://github.com/example/adr/0014"),
          %{
            text: "See the source",
            entities: [link_entity(4, 3, "https://github.com/example")]
          }
        ],
        is_anonymous: false,
        allows_multiple_answers: true,
        bot_token: token
      )

  ## Option shapes

    * `String.t()`: plain option, no entities
    * `{:link, label, url}`: convenience for an option whose entire text
      is a single hyperlink
    * `%{text: t, entities: [entity, ...]}`: pre-built option with any
      combination of entities

  Option count is validated client-side (Telegram requires 2-10).
  """

  alias Raxol.Telegram.HTTP

  @min_options 2
  @max_options 10

  @poll_opts ~w(is_anonymous type allows_multiple_answers correct_option_id
                explanation explanation_parse_mode explanation_entities
                open_period close_date is_closed disable_notification
                reply_to_message_id reply_markup message_thread_id
                business_connection_id question_parse_mode question_entities)a

  @type option ::
          String.t()
          | {:link, label :: String.t(), url :: String.t()}
          | %{required(:text) => String.t(), optional(:entities) => [map()]}

  @doc """
  Builds a `text_link` MessageEntity at the given UTF-16 code-unit offset
  and length, pointing at `url`.

  Telegram counts entity offsets in UTF-16 code units, not graphemes. For
  ASCII text the count matches `String.length/1`. For BMP characters the
  count usually matches; supplementary-plane (emoji) characters count as
  two code units each. When in doubt, prefer `link_option/2` (entity spans
  the whole text and counts are computed automatically).
  """
  @spec link_entity(non_neg_integer(), non_neg_integer(), String.t()) :: map()
  def link_entity(offset, length, url)
      when is_integer(offset) and offset >= 0 and
             is_integer(length) and length > 0 and
             is_binary(url) do
    %{type: "text_link", offset: offset, length: length, url: url}
  end

  @doc """
  Convenience constructor for an option whose entire text is one hyperlink.

  Returns a `{:link, label, url}` tuple consumed by
  `to_input_poll_option/1`.
  """
  @spec link_option(String.t(), String.t()) :: {:link, String.t(), String.t()}
  def link_option(label, url) when is_binary(label) and is_binary(url),
    do: {:link, label, url}

  @doc """
  Translates an `option/0` value into the `InputPollOption` JSON map.

  Use `Enum.map/2` over your options list when building the body manually;
  `send_poll/4` calls this for you.
  """
  @spec to_input_poll_option(option()) :: map()
  def to_input_poll_option(text) when is_binary(text), do: %{text: text}

  def to_input_poll_option({:link, label, url})
      when is_binary(label) and is_binary(url) do
    %{
      text: label,
      text_entities: [link_entity(0, String.length(label), url)]
    }
  end

  def to_input_poll_option(%{text: text} = opt) when is_binary(text) do
    case Map.get(opt, :entities) do
      nil -> %{text: text}
      [] -> %{text: text}
      entities when is_list(entities) -> %{text: text, text_entities: entities}
    end
  end

  @doc """
  Sends a poll via Bot API `sendPoll`.

  Validates option count (2-10) before the API call.

  ## Options

  Recognized Telegram poll options (forwarded to the API body):
  `:is_anonymous`, `:type`, `:allows_multiple_answers`, `:correct_option_id`,
  `:explanation`, `:explanation_parse_mode`, `:explanation_entities`,
  `:open_period`, `:close_date`, `:is_closed`, `:disable_notification`,
  `:reply_to_message_id`, `:reply_markup`, `:message_thread_id`,
  `:business_connection_id`, `:question_parse_mode`, `:question_entities`.

  HTTP-layer options (forwarded to `Raxol.Telegram.HTTP.post/3`):
  `:bot_token`, `:api_base`, `:timeout`, `:post_fn`.

  Unrecognized opts are dropped silently.
  """
  @spec send_poll(integer() | String.t(), String.t(), [option()], keyword()) ::
          {:ok, term()} | {:error, term()}
  def send_poll(chat_id, question, options, opts \\ [])
      when is_binary(question) and is_list(options) do
    with :ok <- validate_options(options) do
      body = build_body(chat_id, question, options, opts)
      HTTP.post("sendPoll", body, opts)
    end
  end

  @doc "Returns `{min, max}` for the allowed option count range."
  @spec option_count_range() :: {pos_integer(), pos_integer()}
  def option_count_range, do: {@min_options, @max_options}

  # --- Private ---

  defp build_body(chat_id, question, options, opts) do
    opts
    |> Enum.filter(fn {k, _} -> k in @poll_opts end)
    |> Map.new()
    |> Map.put(:chat_id, chat_id)
    |> Map.put(:question, question)
    |> Map.put(:options, Enum.map(options, &to_input_poll_option/1))
  end

  defp validate_options(options) do
    count = length(options)

    cond do
      count < @min_options -> {:error, {:poll_validation, :too_few_options, count}}
      count > @max_options -> {:error, {:poll_validation, :too_many_options, count}}
      true -> :ok
    end
  end
end
