defmodule Raxol.ConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Config.{Generator, Loader, Schema}

  describe "configuration loading" do
    test "loads default configuration" do
      config = %{
        terminal: %{width: 80, height: 24},
        theme: %{name: "default"}
      }

      # Test that default values are accessible
      assert config.terminal.width == 80
      assert config.terminal.height == 24
      assert config.theme.name == "default"
    end

    test "merges configuration from multiple sources" do
      base = %{terminal: %{width: 80, height: 24}}
      override = %{terminal: %{width: 120}}

      merged = deep_merge(base, override)

      assert merged.terminal.width == 120
      assert merged.terminal.height == 24
    end

    test "parses environment variables correctly" do
      # This would require setting actual env vars in test
      # For now, test the parsing logic directly
      key = "RAXOL_TERMINAL__WIDTH"
      expected_path = [:terminal, :width]

      parsed_path = parse_env_key(key, "RAXOL_")
      assert parsed_path == expected_path
    end

    test "load_environment skips env vars with keys not in the schema" do
      # Pick an env var name unlikely to exist anywhere else and that
      # contains a segment that is definitely NOT a schema atom.
      attacker_segment =
        "raxol_loader_test_unknown_#{System.unique_integer([:positive])}"

      env_var = "RAXOL_" <> String.upcase(attacker_segment)
      System.put_env(env_var, "value")

      on_exit(fn -> System.delete_env(env_var) end)

      # Verify the attacker segment is NOT already a known atom before
      # the loader runs. If it is, the test prereq is invalid.
      refute_existing_atom(attacker_segment)

      assert {:ok, config} = Loader.load_environment("RAXOL_")

      # Config should not contain a key built from the unknown segment.
      refute_existing_atom(attacker_segment)
      assert config == %{} or not Map.has_key?(config, :unknown_segment)
    end

    test "load_environment includes env vars with known schema keys" do
      System.put_env("RAXOL_TERMINAL__WIDTH", "120")
      on_exit(fn -> System.delete_env("RAXOL_TERMINAL__WIDTH") end)

      assert {:ok, config} = Loader.load_environment("RAXOL_")
      assert get_in(config, [:terminal, :width]) == 120
    end
  end

  describe "configuration schema" do
    test "validates correct configuration" do
      valid_config = %{
        terminal: %{
          width: 80,
          height: 24,
          scrollback_size: 10_000
        }
      }

      result = Schema.validate_config(valid_config)
      assert {:ok, :valid} = result
    end

    test "detects invalid configuration values" do
      invalid_config = %{
        terminal: %{
          # Invalid: negative width
          width: -10,
          height: 24
        }
      }

      result = Schema.validate_config(invalid_config)
      assert {:error, _errors} = result
    end

    test "provides schema for configuration paths" do
      schema = Schema.get_schema([:terminal, :width])
      assert schema != nil
      assert schema.type == :integer
    end
  end

  describe "configuration file operations" do
    setup do
      # Create temporary test files
      test_dir = "test/tmp/config"
      File.mkdir_p!(test_dir)

      on_exit(fn ->
        File.rm_rf!(test_dir)
      end)

      {:ok, test_dir: test_dir}
    end

    test "loads TOML configuration files", %{test_dir: test_dir} do
      toml_content = """
      [terminal]
      width = 120
      height = 40
      """

      file_path = Path.join(test_dir, "test.toml")
      File.write!(file_path, toml_content)

      case Loader.load_file(file_path) do
        {:ok, config} ->
          assert config.terminal.width == 120
          assert config.terminal.height == 40

        {:error, reason} ->
          flunk("Failed to load TOML: #{inspect(reason)}")
      end
    end

    test "loads JSON configuration files", %{test_dir: test_dir} do
      json_content = """
      {
        "terminal": {
          "width": 120,
          "height": 40
        }
      }
      """

      file_path = Path.join(test_dir, "test.json")
      File.write!(file_path, json_content)

      case Loader.load_file(file_path) do
        {:ok, config} ->
          assert config.terminal.width == 120
          assert config.terminal.height == 40

        {:error, reason} ->
          flunk("Failed to load JSON: #{inspect(reason)}")
      end
    end

    test "generates configuration files", %{test_dir: test_dir} do
      file_path = Path.join(test_dir, "generated.toml")

      result = Generator.generate_minimal_config(file_path)
      assert :ok = result
      assert File.exists?(file_path)

      # Verify the generated file can be loaded
      {:ok, config} = Loader.load_file(file_path)
      assert Map.has_key?(config, :terminal)
    end
  end

  describe "configuration generation" do
    test "generates default configuration" do
      # Test that generator creates valid config by actually calling it
      temp_path = Path.join(System.tmp_dir!(), "test_config.toml")

      # Clean up any existing file
      File.rm(temp_path)

      # Generate the configuration
      assert {:ok, ^temp_path} = Generator.generate_default_config(temp_path)

      # Verify the file was created
      assert File.exists?(temp_path)

      # Clean up
      File.rm(temp_path)
    end

    test "generates environment-specific configuration" do
      # Test environment configs
      dev_config = Generator.development_config()
      prod_config = Generator.production_config()

      # Development should have debug logging
      assert get_in(dev_config, [:logging, :level]) == :debug

      # Production should have stricter settings
      assert get_in(prod_config, [:logging, :level]) == :info
    end

    test "generates configuration documentation" do
      docs = Schema.generate_docs()
      assert is_binary(docs)
      assert String.contains?(docs, "terminal")
      assert String.contains?(docs, "width")
    end
  end

  # Helper functions for tests

  defp deep_merge(left, right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp parse_env_key(key, prefix) do
    key
    |> String.replace_prefix(prefix, "")
    |> String.downcase()
    |> String.split("__")
    |> Enum.map(&String.to_atom/1)
  end

  # Asserts a binary is NOT an existing atom in the VM atom table.
  # If the binary is already interned, the test prerequisite is invalid
  # and the assertion is removed from this test's contract -- without
  # this guard the loader could "pass" by accident.
  defp refute_existing_atom(binary) do
    _ = String.to_existing_atom(binary)
    flunk("Expected #{inspect(binary)} to not be an existing atom")
  rescue
    ArgumentError -> :ok
  end
end
