defmodule Raxol.Telegram.InputAdapterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Telegram.InputAdapter

  @special_key_names ~w(up down left right enter tab backspace escape)

  describe "translate_callback/1" do
    property "key:<special> always produces a special-key Event" do
      check all(name <- member_of(@special_key_names)) do
        event = InputAdapter.translate_callback("key:" <> name)
        assert event.type == :key
        assert event.data.key == String.to_atom(name)
      end
    end

    property "key:<single-char> always produces a char Event" do
      check all(char <- string(:alphanumeric, length: 1)) do
        event = InputAdapter.translate_callback("key:" <> char)
        assert event.type == :key
        assert event.data.char == char
      end
    end

    property "key:<unknown multi-char> always returns nil" do
      check all(
              multi <- string(:alphanumeric, min_length: 2, max_length: 10),
              multi not in @special_key_names
            ) do
        assert InputAdapter.translate_callback("key:" <> multi) == nil
      end
    end

    property "btn:<id> always produces a :click Event with component_id" do
      check all(id <- string(:alphanumeric, min_length: 1, max_length: 30)) do
        event = InputAdapter.translate_callback("btn:" <> id)
        assert event.type == :click
        assert event.data.component_id == id
      end
    end

    property "callback data without a recognized prefix returns nil" do
      check all(
              data <- string(:alphanumeric, min_length: 1, max_length: 20),
              not String.starts_with?(data, "key:"),
              not String.starts_with?(data, "btn:")
            ) do
        assert InputAdapter.translate_callback(data) == nil
      end
    end
  end

  describe "translate_text/1" do
    property "single-char text always becomes a :key char Event" do
      check all(char <- string(:alphanumeric, length: 1)) do
        event = InputAdapter.translate_text(char)
        assert event.type == :key
        assert event.data.char == char
      end
    end

    property "multi-char text always becomes a :paste Event with trimmed content" do
      check all(text <- string(:alphanumeric, min_length: 2, max_length: 30)) do
        event = InputAdapter.translate_text(text)
        assert event.type == :paste
        assert event.data.text == text
      end
    end

    property "/command always returns {:command, name} with the first word only" do
      check all(
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              rest <- string(:alphanumeric, max_length: 20)
            ) do
        input =
          if rest == "" do
            "/" <> name
          else
            "/" <> name <> " " <> rest
          end

        assert {:command, ^name} = InputAdapter.translate_text(input)
      end
    end

    property "leading/trailing whitespace doesn't change the classification" do
      check all(
              text <- string(:alphanumeric, min_length: 1, max_length: 20),
              pad_left <- string([?\s, ?\t], max_length: 5),
              pad_right <- string([?\s, ?\t], max_length: 5)
            ) do
        bare = InputAdapter.translate_text(text)
        padded = InputAdapter.translate_text(pad_left <> text <> pad_right)
        assert bare.type == padded.type
      end
    end

    property "all-whitespace input returns nil" do
      check all(ws <- string([?\s, ?\t, ?\n], max_length: 10)) do
        assert InputAdapter.translate_text(ws) == nil
      end
    end
  end
end
