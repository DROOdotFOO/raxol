defmodule Raxol.Terminal.Commands.OSCHandlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Clipboard
  alias Raxol.Terminal.Commands.OSCHandler

  defp emulator(overrides \\ %{}) do
    Map.merge(
      %{
        clipboard: Clipboard.Manager.new(),
        output_buffer: nil,
        notification: nil,
        progress: nil,
        pointer_shape: nil
      },
      overrides
    )
  end

  describe "OSC 9 notification" do
    test "stores a plain notification message" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "Build finished")
      assert result.notification == "Build finished"
    end

    test "leaves clipboard state untouched" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "hello")
      assert result.clipboard == Clipboard.Manager.new()
    end
  end

  describe "OSC 9;4 progress" do
    test "parses set state with a value" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "4;1;42")
      assert result.progress == %{state: :set, value: 42}
    end

    test "parses remove state, defaulting value to 0" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "4;0")
      assert result.progress == %{state: :remove, value: 0}
    end

    test "parses error state" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "4;2;100")
      assert result.progress == %{state: :error, value: 100}
    end

    test "parses indeterminate state" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "4;3;0")
      assert result.progress == %{state: :indeterminate, value: 0}
    end

    test "parses warning state" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "4;4;75")
      assert result.progress == %{state: :warning, value: 75}
    end

    test "rejects an unknown state code without crashing" do
      assert {:error, :invalid_progress, _emulator} =
               OSCHandler.handle(emulator(), 9, "4;9;10")
    end

    test "rejects an out-of-range progress value without crashing" do
      assert {:error, :invalid_progress, _emulator} =
               OSCHandler.handle(emulator(), 9, "4;1;101")
    end

    test "rejects a negative progress value without crashing" do
      assert {:error, :invalid_progress, _emulator} =
               OSCHandler.handle(emulator(), 9, "4;1;-5")
    end

    test "rejects non-numeric input without crashing" do
      assert {:error, :invalid_progress, _emulator} =
               OSCHandler.handle(emulator(), 9, "4;abc;def")
    end

    test "rejects an empty progress payload without crashing" do
      assert {:error, :invalid_progress, _emulator} =
               OSCHandler.handle(emulator(), 9, "4;")
    end
  end

  describe "OSC 22 pointer shape" do
    test "sets a named pointer shape" do
      {:ok, result} = OSCHandler.handle(emulator(), 22, "pointer")
      assert result.pointer_shape == "pointer"
    end

    test "accepts the default shape" do
      {:ok, result} = OSCHandler.handle(emulator(), 22, "default")
      assert result.pointer_shape == "default"
    end

    test "accepts arbitrary CSS-style cursor keywords" do
      {:ok, result} = OSCHandler.handle(emulator(), 22, "crosshair")
      assert result.pointer_shape == "crosshair"
    end

    test "rejects an empty shape without crashing" do
      assert {:error, :invalid_pointer_shape, _emulator} =
               OSCHandler.handle(emulator(), 22, "")
    end
  end

  describe "OSC 52 clipboard (regression)" do
    test "sets clipboard content from base64" do
      {:ok, result} = OSCHandler.handle(emulator(), 52, "c;SGVsbG8=")
      assert Clipboard.get_content(result.clipboard) == "Hello"
    end

    test "queries clipboard content" do
      {:ok, seeded} = Clipboard.set_content(Clipboard.Manager.new(), "Hi")

      {:ok, result} =
        OSCHandler.handle(emulator(%{clipboard: seeded}), 52, "c;?")

      assert result.output_buffer == "\e]52;c;#{Base.encode64("Hi")}\e\\"
    end

    test "sets selection content from base64" do
      {:ok, result} = OSCHandler.handle(emulator(), 52, "s;U2VsZWN0ZWQ=")
      assert {:ok, "Selected"} = Clipboard.get_selection(result.clipboard)
    end

    test "rejects a malformed command without crashing" do
      assert {:error, :invalid_clipboard_command, _emulator} =
               OSCHandler.handle(emulator(), 52, "bogus")
    end
  end

  describe "OSC 9 no longer mis-routes to clipboard" do
    test "clipboard-shaped payloads on OSC 9 are treated as notification text" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "c;SGVsbG8=")
      assert result.clipboard == Clipboard.Manager.new()
      assert result.notification == "c;SGVsbG8="
    end
  end
end
