defmodule Raxol.CLI.NewTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.CLI.New

  describe "run/1 validation" do
    test "rejects a missing name" do
      message = capture_io(:stderr, fn -> assert New.run([]) == 1 end)
      assert message =~ "usage:"
      assert message =~ "requires local Elixir/Mix"
    end

    test "rejects a non-snake_case name" do
      assert capture_io(:stderr, fn -> assert New.run(["MyApp"]) == 1 end) =~ "invalid app name"
    end

    test "refuses to overwrite an existing path" do
      dir = Path.join(System.tmp_dir!(), "raxol_cli_exists_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      cwd = File.cwd!()
      File.cd!(Path.dirname(dir))
      on_exit(fn -> File.cd!(cwd) end)

      name = Path.basename(dir)
      assert capture_io(:stderr, fn -> assert New.run([name]) == 1 end) =~ "already exists"
    end
  end

  describe "run/1 generation" do
    test "scaffolds a runnable app skeleton" do
      base = Path.join(System.tmp_dir!(), "raxol_cli_gen_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      cwd = File.cwd!()
      File.cd!(base)
      on_exit(fn -> File.cd!(cwd) end)

      output = capture_io(fn -> assert New.run(["my_app"]) == 0 end)

      assert File.exists?(Path.join([base, "my_app", "mix.exs"]))
      assert File.exists?(Path.join([base, "my_app", "lib", "my_app.ex"]))
      assert File.read!(Path.join([base, "my_app", "lib", "my_app.ex"])) =~ "defmodule MyApp"

      assert output =~ "Next (requires local Elixir/Mix):"

      assert File.read!(Path.join([base, "my_app", "README.md"])) =~
               "Requires local Elixir/Mix"
    end
  end
end
