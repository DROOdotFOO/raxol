defmodule Raxol.Test.Platform.PlatformDetectionTest do
  use ExUnit.Case, async: true

  alias Raxol.System.Platform

  describe "platform detection" do
    setup do
      # No specific setup needed for these tests
      :ok
    end

    test ~c"identifies current platform" do
      platform = Platform.get_current_platform()

      # Ensure platform is detected
      assert platform in [:macos, :linux, :windows]

      # Ensure platform matches OS type
      case :os.type() do
        {:unix, :darwin} -> assert platform == :macos
        {:unix, _} -> assert platform == :linux
        {:win32, _} -> assert platform == :windows
        _ -> flunk("Unknown OS type: #{inspect(:os.type())}")
      end
    end

    test ~c"provides platform-specific information" do
      platform_info = Platform.get_platform_info()

      # All platforms should have these basic fields
      assert is_map(platform_info)
      assert Map.has_key?(platform_info, :name)
      assert Map.has_key?(platform_info, :version)
      assert Map.has_key?(platform_info, :architecture)
      assert Map.has_key?(platform_info, :terminal)
    end

    test ~c"detects environment variables correctly" do
      # This is a simplified version of the original test
      env_vars = System.get_env()

      # Common environment variables that should exist on all platforms
      # Windows uses case-insensitive env vars, may be "PATH" or "Path"
      path_exists =
        Map.has_key?(env_vars, "PATH") ||
          Map.has_key?(env_vars, "Path")

      assert path_exists

      # At least one of these should exist
      assert Map.has_key?(env_vars, "HOME") ||
               Map.has_key?(env_vars, "USERPROFILE")
    end

    test ~c"detects system capabilities" do
      # Get terminal capabilities
      capabilities = Raxol.System.TerminalPlatform.get_terminal_capabilities()

      # Check for required fields in a more flexible way
      assert is_map(capabilities)
      assert is_list(capabilities.features)
    end

    test ~c"returns correct file extension for current platform" do
      extension = Platform.get_platform_extension()

      case Platform.get_current_platform() do
        :windows -> assert extension == "zip"
        _ -> assert extension == "tar.gz"
      end
    end

    test ~c"provides executable name for current platform" do
      executable = Platform.get_executable_name()

      case Platform.get_current_platform() do
        :windows -> assert executable == "raxol.exe"
        _ -> assert executable == "raxol"
      end
    end

    test ~c"detects terminal capabilities" do
      terminal_features =
        Raxol.System.TerminalPlatform.get_terminal_capabilities()

      # Check structure in a more flexible way
      assert is_map(terminal_features)
      assert Map.has_key?(terminal_features, :colors)
      assert Map.has_key?(terminal_features, :unicode)
      assert Map.has_key?(terminal_features, :input)
      assert Map.has_key?(terminal_features, :output)
      assert Map.has_key?(terminal_features, :features)

      # Check that colors map has expected structure
      assert is_map(terminal_features.colors)
      assert Map.has_key?(terminal_features.colors, :true_color)

      # Check unicode support property
      assert is_map(terminal_features.unicode)
      assert Map.has_key?(terminal_features.unicode, :support)
    end
  end
end
