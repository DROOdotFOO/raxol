defmodule Raxol.Speech.InputAdapterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Speech.InputAdapter

  @default_keys InputAdapter.default_commands() |> Map.keys()

  describe "default command map" do
    property "every default phrase produces a :key event" do
      check all phrase <- member_of(@default_keys) do
        event = InputAdapter.translate(phrase)
        assert event.type == :key
      end
    end

    property "case-insensitive: upper-case forms match the lower-case command" do
      check all phrase <- member_of(@default_keys) do
        lower = InputAdapter.translate(phrase)
        upper = InputAdapter.translate(String.upcase(phrase))
        assert lower.type == upper.type
        assert lower.data == upper.data
      end
    end

    property "leading/trailing whitespace is ignored" do
      check all phrase <- member_of(@default_keys),
                pad_left <- string([?\s, ?\t], max_length: 5),
                pad_right <- string([?\s, ?\t], max_length: 5) do
        bare = InputAdapter.translate(phrase)
        padded = InputAdapter.translate(pad_left <> phrase <> pad_right)
        assert bare.type == padded.type
        assert bare.data == padded.data
      end
    end
  end

  describe "fallback to paste" do
    property "phrases not in the command map become :paste events with the trimmed text" do
      check all text <- string(:alphanumeric, min_length: 1, max_length: 30),
                lower = text |> String.trim() |> String.downcase(),
                lower not in @default_keys,
                lower != "" do
        event = InputAdapter.translate(text)
        assert event.type == :paste
        assert event.data.text == String.trim(text)
      end
    end

    property "empty / whitespace-only inputs return nil" do
      check all ws <- string([?\s, ?\t, ?\n], max_length: 10) do
        assert InputAdapter.translate(ws) == nil
      end
    end
  end

  describe "merge semantics" do
    property "custom keys not in defaults produce events from the custom map" do
      check all phrase <- string(:alphanumeric, min_length: 1, max_length: 12),
                normalized = phrase |> String.trim() |> String.downcase(),
                normalized not in @default_keys,
                normalized != "",
                char <- string(:alphanumeric, length: 1) do
        custom = %{normalized => {:key, %{key: :char, char: char}}}
        event = InputAdapter.translate(phrase, commands: custom)
        assert event.type == :key
        assert event.data.char == char
      end
    end

    property "default phrases are preserved when not overridden" do
      check all phrase <- member_of(@default_keys),
                other_phrase <- string(:alphanumeric, min_length: 1, max_length: 12),
                other_phrase != phrase do
        custom = %{other_phrase => {:key, %{key: :enter}}}
        bare = InputAdapter.translate(phrase)
        merged = InputAdapter.translate(phrase, commands: custom)
        assert bare.type == merged.type
        assert bare.data == merged.data
      end
    end

    property "malformed :commands option falls back to defaults" do
      check all malformed <- one_of([
                  constant(nil),
                  integer(),
                  string(:alphanumeric),
                  list_of(atom(:alphanumeric))
                ]) do
        event = InputAdapter.translate("quit", commands: malformed)
        assert event.type == :key
        assert event.data.char == "q"
      end
    end
  end
end
