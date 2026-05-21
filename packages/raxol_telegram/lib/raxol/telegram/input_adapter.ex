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
end
