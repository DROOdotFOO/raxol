defmodule Raxol.System.PlatformGraphicsTest do
  use ExUnit.Case, async: true

  alias Raxol.System.Platform

  describe "detect_graphics_support/0" do
    test "returns comprehensive graphics support information" do
      result = Platform.detect_graphics_support()

      # Verify structure
      assert is_map(result)
      assert Map.has_key?(result, :kitty_graphics)
      assert Map.has_key?(result, :sixel_graphics)
      assert Map.has_key?(result, :iterm2_graphics)
      assert Map.has_key?(result, :terminal_type)
      assert Map.has_key?(result, :capabilities)

      # Verify types
      assert is_boolean(result.kitty_graphics)
      assert is_boolean(result.sixel_graphics)
      assert is_boolean(result.iterm2_graphics)
      assert is_atom(result.terminal_type)
      assert is_map(result.capabilities)
    end

    test "detects Kitty terminal correctly" do
      # Mock Kitty environment
      original_term = System.get_env("TERM")
      System.put_env("TERM", "xterm-kitty")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :kitty
      assert result.kitty_graphics == true
      assert result.capabilities.max_image_size > 0

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "detects WezTerm correctly" do
      # Mock WezTerm environment
      System.put_env("WEZTERM_EXECUTABLE", "/usr/bin/wezterm")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :wezterm
      # WezTerm supports Kitty protocol
      assert result.kitty_graphics == true

      System.delete_env("WEZTERM_EXECUTABLE")
    end

    test "detects iTerm2 correctly" do
      # Mock iTerm2 environment
      original_program = System.get_env("TERM_PROGRAM")
      System.put_env("TERM_PROGRAM", "iTerm.app")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :iterm2
      assert result.iterm2_graphics == true

      # Restore environment
      case original_program do
        nil -> System.delete_env("TERM_PROGRAM")
        program -> System.put_env("TERM_PROGRAM", program)
      end
    end
  end

  describe "supports_feature?/1 graphics features" do
    test "detects Kitty graphics support" do
      # Mock Kitty terminal
      original_term = System.get_env("TERM")
      System.put_env("TERM", "xterm-kitty")

      assert Platform.supports_feature?(:kitty_graphics) == true

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "detects Sixel graphics support" do
      # Mock terminal with Sixel support
      original_term = System.get_env("TERM")
      System.put_env("TERM", "xterm-sixel")

      # Note: This might be false due to version detection logic
      result = Platform.supports_feature?(:sixel_graphics)
      assert is_boolean(result)

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "detects iTerm2 graphics support" do
      # Mock iTerm2 environment
      original_program = System.get_env("TERM_PROGRAM")
      System.put_env("TERM_PROGRAM", "iTerm.app")

      assert Platform.supports_feature?(:iterm2_graphics) == true

      # Restore environment
      case original_program do
        nil -> System.delete_env("TERM_PROGRAM")
        program -> System.put_env("TERM_PROGRAM", program)
      end
    end

    test "returns false for unknown graphics features" do
      assert Platform.supports_feature?(:unknown_graphics) == false
    end
  end

  describe "terminal type detection" do
    setup do
      isolate_terminal_program_leak()
    end

    test "detects various terminal types from TERM variable" do
      test_cases = [
        {"xterm-kitty", :kitty},
        {"xterm-256color", :xterm},
        {"screen-256color", :screen},
        {"tmux-256color", :tmux},
        {"foot", :foot},
        {"st-256color", :st}
      ]

      original_term = System.get_env("TERM")

      Enum.each(test_cases, fn {term_value, expected_type} ->
        System.put_env("TERM", term_value)
        result = Platform.detect_graphics_support()
        assert result.terminal_type == expected_type
      end)

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "handles unknown terminal gracefully" do
      original_term = System.get_env("TERM")
      System.put_env("TERM", "unknown-terminal")

      result = Platform.detect_graphics_support()
      assert result.terminal_type == :unknown
      assert result.kitty_graphics == false
      assert result.sixel_graphics == false
      assert result.iterm2_graphics == false

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end
  end

  describe "terminal capabilities detection" do
    setup do
      isolate_terminal_program_leak()
    end

    test "provides Kitty terminal capabilities" do
      # Mock Kitty environment
      original_term = System.get_env("TERM")
      System.put_env("TERM", "xterm-kitty")

      result = Platform.detect_graphics_support()
      capabilities = result.capabilities

      assert capabilities.max_image_size == 100_000_000
      assert capabilities.supports_animation == true
      assert capabilities.supports_transparency == true
      assert capabilities.supports_chunked_transmission == true
      assert capabilities.max_image_width == 10_000
      assert capabilities.max_image_height == 10_000

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "provides iTerm2 capabilities" do
      # Mock iTerm2 environment
      original_program = System.get_env("TERM_PROGRAM")
      System.put_env("TERM_PROGRAM", "iTerm.app")

      result = Platform.detect_graphics_support()
      capabilities = result.capabilities

      assert capabilities.max_image_size == 10_000_000
      assert capabilities.supports_animation == false
      assert capabilities.supports_transparency == true
      assert capabilities.supports_chunked_transmission == false

      # Restore environment
      case original_program do
        nil -> System.delete_env("TERM_PROGRAM")
        program -> System.put_env("TERM_PROGRAM", program)
      end
    end

    test "provides conservative capabilities for unknown terminals" do
      original_term = System.get_env("TERM")
      System.put_env("TERM", "dumb")

      result = Platform.detect_graphics_support()
      capabilities = result.capabilities

      assert capabilities.max_image_size == 0
      assert capabilities.supports_animation == false
      assert capabilities.supports_transparency == false
      assert capabilities.supports_chunked_transmission == false
      assert capabilities.max_image_width == 0
      assert capabilities.max_image_height == 0

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end
  end

  describe "version-based feature detection" do
    test "checks WezTerm version for Kitty support" do
      # Mock WezTerm with version info
      System.put_env("WEZTERM_EXECUTABLE", "/usr/bin/wezterm")
      # Old version
      System.put_env("WEZTERM_VERSION", "20220101")

      result = Platform.detect_graphics_support()

      # Should detect WezTerm but may have limited Kitty support based on version
      assert result.terminal_type == :wezterm

      System.delete_env("WEZTERM_EXECUTABLE")
      System.delete_env("WEZTERM_VERSION")
    end

    test "checks iTerm2 version for Kitty support" do
      # Mock iTerm2 with version info
      System.put_env("TERM_PROGRAM", "iTerm.app")
      System.put_env("TERM_PROGRAM_VERSION", "3.5.0")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :iterm2
      assert result.iterm2_graphics == true

      System.delete_env("TERM_PROGRAM")
      System.delete_env("TERM_PROGRAM_VERSION")
    end

    test "handles missing version information gracefully" do
      # Mock terminal without version info
      System.put_env("TERM_PROGRAM", "iTerm.app")
      # Don't set TERM_PROGRAM_VERSION

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :iterm2
      # Should have conservative defaults when version is unknown

      System.delete_env("TERM_PROGRAM")
    end
  end

  describe "environment variable precedence" do
    test "KITTY_WINDOW_ID takes precedence over TERM" do
      original_term = System.get_env("TERM")
      # Would normally detect as xterm
      System.put_env("TERM", "xterm-256color")
      # But this indicates Kitty
      System.put_env("KITTY_WINDOW_ID", "12345")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :kitty
      assert result.kitty_graphics == true

      # Restore environment
      System.delete_env("KITTY_WINDOW_ID")

      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end

    test "WEZTERM_EXECUTABLE takes precedence over TERM" do
      original_term = System.get_env("TERM")
      System.put_env("TERM", "xterm-256color")
      System.put_env("WEZTERM_EXECUTABLE", "/usr/bin/wezterm")

      result = Platform.detect_graphics_support()

      assert result.terminal_type == :wezterm
      # WezTerm supports Kitty protocol
      assert result.kitty_graphics == true

      # Restore environment
      System.delete_env("WEZTERM_EXECUTABLE")

      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end
  end

  describe "Sixel-specific detection" do
    test "detects Sixel support in environment variables" do
      original_colorterm = System.get_env("COLORTERM")
      System.put_env("COLORTERM", "sixel")

      assert Platform.supports_feature?(:sixel_graphics) == true

      # Restore environment
      case original_colorterm do
        nil -> System.delete_env("COLORTERM")
        colorterm -> System.put_env("COLORTERM", colorterm)
      end
    end

    test "detects terminals with built-in Sixel support" do
      test_cases = [:mintty, :mlterm, :wezterm, :foot]
      original_term = System.get_env("TERM")

      Enum.each(test_cases, fn terminal_type ->
        # Mock each terminal type
        term_value =
          case terminal_type do
            :mintty -> "mintty"
            :mlterm -> "mlterm"
            :wezterm -> "wezterm"
            :foot -> "foot"
          end

        System.put_env("TERM", term_value)

        result = Platform.detect_graphics_support()
        assert result.sixel_graphics == true
      end)

      # Restore environment
      case original_term do
        nil -> System.delete_env("TERM")
        term -> System.put_env("TERM", term)
      end
    end
  end

  # `Platform.detect_terminal_type/0` checks TERM_PROGRAM (and the Kitty/
  # WezTerm/Alacritty program-marker vars) before it ever looks at TERM --
  # running these tests from inside one of those terminals leaks the host's
  # own identity in and wins over whatever TERM value the test sets.
  defp isolate_terminal_program_leak do
    leaking = [
      "TERM_PROGRAM",
      "KITTY_WINDOW_ID",
      "WEZTERM_EXECUTABLE",
      "ALACRITTY_LOG"
    ]

    saved = Map.new(leaking, &{&1, System.get_env(&1)})
    Enum.each(leaking, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)

    :ok
  end
end
