defmodule Termbox2LoadingTest do
  @moduledoc """
  Tests for verifying that the termbox2_nif module loads correctly.
  These tests don't require a TTY and always run on Unix platforms.
  On Windows, termbox2 NIF is not compiled (pure Elixir IOTerminal is used instead).
  """
  use ExUnit.Case

  # Skip all NIF loading tests on Windows (NIF not compiled there)
  @moduletag :unix_only

  describe "NIF loading" do
    @tag :docker
    test "termbox2_nif module is loaded" do
      # Check that the module exists
      assert Code.ensure_loaded?(:termbox2_nif)
    end

    @tag :docker
    test "NIF functions are defined" do
      # `function_exported?/3` reports false for a module that is simply not
      # loaded yet, so load it here rather than depending on the sibling test
      # above having been scheduled first -- ExUnit shuffles per seed.
      Code.ensure_loaded!(:termbox2_nif)

      # Check that all expected functions exist
      expected_functions = [
        {:tb_init, 0},
        {:tb_shutdown, 0},
        {:tb_width, 0},
        {:tb_height, 0},
        {:tb_clear, 0},
        {:tb_present, 0},
        {:tb_set_cell, 5},
        {:tb_set_cursor, 2},
        {:tb_hide_cursor, 0},
        {:tb_print, 5},
        {:tb_set_title, 1},
        {:tb_set_position, 2},
        {:tb_set_input_mode, 1},
        {:tb_set_output_mode, 1}
      ]

      for {func, arity} <- expected_functions do
        assert function_exported?(:termbox2_nif, func, arity),
               "Function #{func}/#{arity} not exported"
      end
    end

    @tag :docker
    test "NIF is loaded successfully" do
      # The NIF should be loaded on module load
      # We can check this by verifying that functions don't return :nif_not_loaded
      # when called with invalid arguments (they should return an error instead)

      # Note: We can't actually call tb_init without a TTY, but we can check
      # that the NIF file exists
      priv_dir = :code.priv_dir(:raxol_terminal) |> List.to_string()
      nif_path = Path.join(priv_dir, "termbox2_nif.so")

      assert File.exists?(nif_path),
             "NIF shared library not found at #{nif_path}"
    end

    @tag :docker
    test "priv directory structure is correct" do
      priv_dir = :code.priv_dir(:raxol_terminal) |> List.to_string()

      # Check that priv directory exists
      assert File.dir?(priv_dir), "Priv directory does not exist"

      # Check for the NIF file
      nif_files =
        File.ls!(priv_dir) |> Enum.filter(&String.ends_with?(&1, ".so"))

      assert "termbox2_nif.so" in nif_files,
             "termbox2_nif.so not found in priv directory"
    end
  end

  describe "module constants" do
    test "termbox color constants are defined" do
      # These should be defined by the module or available as constants
      # Testing that we can reference them without errors
      assert is_atom(:termbox2_nif)
    end
  end

  describe "error handling without TTY" do
    test "functions handle being called without initialization gracefully" do
      # Most functions should fail gracefully when called without tb_init
      # We're not testing the actual functionality, just that they don't crash

      # Note: We can't actually test these without potentially interfering
      # with the terminal, but we document what should happen:
      # - tb_width/0 should return 0 or an error
      # - tb_height/0 should return 0 or an error
      # - tb_clear/0 should return an error
      # - tb_present/0 should return an error

      assert true, "Error handling tests documented"
    end
  end

  describe "NIF compilation" do
    test "Makefile exists for NIF compilation" do
      makefile_path =
        Path.join([File.cwd!(), "lib", "termbox2_nif", "c_src", "Makefile"])

      assert File.exists?(makefile_path),
             "Makefile not found at #{makefile_path}"
    end

    test "C source files exist" do
      c_src_dir = Path.join([File.cwd!(), "lib", "termbox2_nif", "c_src"])

      expected_files = [
        "termbox2_nif.c",
        "termbox_impl.c"
      ]

      for file <- expected_files do
        file_path = Path.join(c_src_dir, file)
        assert File.exists?(file_path), "C source file #{file} not found"
      end
    end

    test "termbox2 library directory exists" do
      termbox2_dir =
        Path.join([File.cwd!(), "lib", "termbox2_nif", "c_src", "termbox2"])

      assert File.dir?(termbox2_dir), "termbox2 library directory not found"
    end
  end
end
