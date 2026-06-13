defmodule Raxol.Telegram.InputAdapter do
  @moduledoc """
  Translates Telegram input (callback queries and text messages)
  into Raxol Event structs for the TEA update cycle.
  """

  alias Raxol.Core.Events.Event

  @special_keys %{
    "up" => :up,
    "down" => :down,
    "left" => :left,
    "right" => :right,
    "enter" => :enter,
    "tab" => :tab,
    "space" => :space,
    "backspace" => :backspace,
    "escape" => :escape
  }

  @doc """
  Translates a Telegram inline keyboard callback_data string to an Event.

  ## Formats

    * `"key:<name>"` -- key event (char or special key)
    * `"btn:<component_id>"` -- button click (mapped to :click event)

  ## Examples

      translate_callback("key:q")     #=> Event with char "q"
      translate_callback("key:up")    #=> Event with key :up
      translate_callback("btn:submit") #=> Event{type: :click, data: %{component_id: "submit"}}
  """
  @spec translate_callback(String.t()) :: Event.t() | nil
  def translate_callback("key:" <> key_name) do
    case Map.get(@special_keys, key_name) do
      nil when byte_size(key_name) == 1 ->
        Event.new(:key, %{key: :char, char: key_name})

      nil ->
        nil

      :space ->
        Event.new(:key, %{key: :char, char: " "})

      special ->
        Event.new(:key, %{key: special})
    end
  end

  def translate_callback("btn:" <> component_id) do
    Event.new(:click, %{component_id: component_id})
  end

  def translate_callback(_), do: nil

  @doc """
  Translates a Telegram text message to an Event.

  Single characters become key events. Commands (starting with `/`)
  are returned as `{:command, name}` tuples for the Bot to handle.
  Multi-character text becomes a paste event.

  ## Examples

      translate_text("q")       #=> Event with char "q"
      translate_text("/start")  #=> {:command, "start"}
      translate_text("hello")   #=> Event with type :paste
  """
  @spec translate_text(String.t()) :: Event.t() | {:command, String.t()} | nil
  def translate_text("/" <> command) do
    cmd = command |> String.split(" ", parts: 2) |> hd() |> String.trim()
    {:command, cmd}
  end

  def translate_text(text) when is_binary(text) do
    trimmed = String.trim(text)

    case String.graphemes(trimmed) do
      [] ->
        nil

      [char] ->
        Event.new(:key, %{key: :char, char: char})

      _ ->
        Event.new(:paste, %{text: trimmed})
    end
  end

  def translate_text(_), do: nil

  @doc """
  Translates a Telegram `chat_join_request` update payload into the
  applicant map shape consumed by `Raxol.Telegram.Guardian.screen/1`.

  Accepts either a `Telegex.Type.ChatJoinRequest` struct or a raw map
  with atom or string keys. Returns `nil` for malformed input.

  ## Example

      iex> req = %{from: %{id: 99, username: "alice"}, chat: %{id: 42}, bio: "hi"}
      iex> Raxol.Telegram.InputAdapter.translate_join_request(req)
      %{
        user_id: 99,
        chat_id: 42,
        query_id: nil,
        username: "alice",
        first_name: nil,
        last_name: nil,
        bio: "hi",
        invite_link: nil
      }
  """
  @spec translate_join_request(map()) :: map() | nil
  def translate_join_request(%{from: %{id: user_id} = from, chat: %{id: chat_id}} = req)
      when is_integer(user_id) and is_integer(chat_id) do
    %{
      user_id: user_id,
      chat_id: chat_id,
      query_id: lookup(req, :query_id),
      username: lookup(from, :username),
      first_name: lookup(from, :first_name),
      last_name: lookup(from, :last_name),
      bio: lookup(req, :bio),
      invite_link: extract_invite_link(req)
    }
  end

  def translate_join_request(
        %{"from" => %{"id" => user_id} = from, "chat" => %{"id" => chat_id}} = req
      )
      when is_integer(user_id) and is_integer(chat_id) do
    %{
      user_id: user_id,
      chat_id: chat_id,
      query_id: lookup(req, "query_id"),
      username: lookup(from, "username"),
      first_name: lookup(from, "first_name"),
      last_name: lookup(from, "last_name"),
      bio: lookup(req, "bio"),
      invite_link: extract_invite_link(req)
    }
  end

  def translate_join_request(_), do: nil

  defp lookup(map, key) when is_map(map), do: Map.get(map, key)

  defp extract_invite_link(req) when is_map(req) do
    case lookup(req, :invite_link) || lookup(req, "invite_link") do
      %{invite_link: link} -> link
      %{"invite_link" => link} -> link
      link when is_binary(link) -> link
      _ -> nil
    end
  end
end
