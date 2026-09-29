defmodule Raxol.Terminal.Commands.OSCHandlerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Terminal.Clipboard
  alias Raxol.Terminal.Commands.{Executor, OSCHandler}
  alias Raxol.Terminal.Input.ControlSequenceHandler

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

  describe "OSC 52 clipboard" do
    test "a query is never answered, so output cannot read the clipboard" do
      {:ok, seeded} = Clipboard.set_content(Clipboard.Manager.new(), "Hi")

      for target <- ["c", "s"] do
        {:ok, result} =
          OSCHandler.handle(emulator(%{clipboard: seeded}), 52, "#{target};?")

        assert result.output_buffer == nil
      end
    end

    test "a set leaves the clipboard alone" do
      {:ok, result} = OSCHandler.handle(emulator(), 52, "c;SGVsbG8=")
      assert result == emulator()
    end
  end

  describe "terminal control logging" do
    test "redacts OSC 52 clipboard payloads" do
      encoded_secret = Base.encode64("private clipboard value")

      log =
        capture_log([level: :debug], fn ->
          result = Executor.execute_osc_command(emulator(), "52;c;#{encoded_secret}")
          assert result == emulator()
        end)

      assert log =~ "Executing OSC command code=52, payload=[REDACTED]"
      refute log =~ encoded_secret
      refute log =~ "private clipboard value"
    end

    test "escapes PM control input instead of emitting terminal controls" do
      command = "\e]52"
      data = "\e[31mprivate\e[0m"

      log =
        capture_log([level: :debug], fn ->
          emulator = emulator()
          assert ControlSequenceHandler.handle_pm_sequence(emulator, command, data) == emulator
        end)

      refute log =~ command
      refute log =~ "\e[31mprivate"
      assert log =~ ~S(command="\e]52")
      assert log =~ ~S(data="\e[31mprivate\e[0m")
    end

    test "escapes unsupported OSC command bytes" do
      command = "\e]unsupported"

      log =
        capture_log([level: :warning], fn ->
          assert {:error, :unsupported_command, _emulator} =
                   OSCHandler.handle(emulator(), command, "ignored")
        end)

      refute log =~ command
      assert log =~ ~S(Unsupported OSC command: "\e]unsupported")
    end
  end

  describe "OSC 9 no longer mis-routes to clipboard" do
    test "clipboard-shaped payloads on OSC 9 are treated as notification text" do
      {:ok, result} = OSCHandler.handle(emulator(), 9, "c;SGVsbG8=")
      assert result.clipboard == Clipboard.Manager.new()
      assert result.notification == "c;SGVsbG8="
    end
  end

  describe "ColorParser.parse/1 hex" do
    test "parses a 6-digit hex" do
      assert OSCHandler.ColorParser.parse("#ff8800") == {:ok, {255, 136, 0}}
    end

    test "parses a 3-digit hex with nibble expansion" do
      assert OSCHandler.ColorParser.parse("#f80") == {:ok, {255, 136, 0}}
    end

    test "invalid hex digits at valid length" do
      assert OSCHandler.ColorParser.parse("#gg0000") ==
               {:error, :invalid_hex_format}
    end

    test "invalid length" do
      assert OSCHandler.ColorParser.parse("#12345") ==
               {:error, :invalid_hex_length}

      assert OSCHandler.ColorParser.parse("#1234567") ==
               {:error, :invalid_hex_length}
    end
  end
end
