defmodule Raxol.CLI.NewTest do
  # Serial: these tests change the working directory, which is global to the VM.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Raxol.CLI.New
  alias Raxol.Headless

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

    test "rejects names that would not compile, creating nothing" do
      base =
        Path.join(System.tmp_dir!(), "raxol_cli_badname_#{System.unique_integer([:positive])}")

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      # A trailing newline, a stdlib module, and the dependency itself.
      for name <- ["trail\n", "enum", "raxol"] do
        capture_io(:stderr, fn -> assert File.cd!(base, fn -> New.run([name]) end) == 1 end)
      end

      assert File.ls!(base) == []
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

    # The skeleton test above proves the files exist. This compiles the app
    # against the raxol this CLI depends on and draws its first frame, which
    # is what `mix deps.get && mix run` in the new project will attempt.
    test "scaffolds an app that compiles and renders" do
      base = Path.join(System.tmp_dir!(), "raxol_cli_app_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      name = "counter_#{System.unique_integer([:positive])}"
      capture_io(fn -> assert File.cd!(base, fn -> New.run([name]) end) == 0 end)

      app = Module.concat([Macro.camelize(name)])
      assert compile!(Path.join([base, name, "lib", "#{name}.ex"])) == [app]

      frame = frame!(app, [])
      assert frame =~ "Count: 0"
      assert frame =~ "+/- to change, q to quit"
      assert frame!(app, ["+", "+", "-"]) =~ "Count: 1"

      ctrl_c = %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "c", ctrl: true}}
      assert {_model, [quit]} = app.update(ctrl_c, app.init(%{}))
      assert quit == Raxol.Core.Runtime.Directive.stop()
    end

    test "scaffolds a mix format-clean project" do
      base = Path.join(System.tmp_dir!(), "raxol_cli_fmt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)

      name = "counter_#{System.unique_integer([:positive])}"
      capture_io(fn -> assert File.cd!(base, fn -> New.run([name]) end) == 0 end)

      project = Path.join(base, name)

      try do
        File.cd!(project, fn -> Mix.Tasks.Format.run(["--check-formatted"]) end)
      rescue
        error in Mix.Error -> flunk("#{project} is not `mix format` clean:\n" <> error.message)
      end
    end
  end

  # Compiled with no warning, since generated CI compiles with
  # `--warnings-as-errors`.
  defp compile!(file) do
    assert {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} =
             Kernel.ParallelCompiler.compile([file], return_diagnostics: true)

    on_exit(fn -> Enum.each(modules, &purge/1) end)
    modules
  end

  defp purge(module) do
    :code.purge(module)
    :code.delete(module)
  end

  # The app's frame in a headless session, after `keys`.
  defp frame!(app, keys) do
    if is_nil(Process.whereis(Headless)), do: start_supervised!({Headless, [name: Headless]})

    id = "raxol_new_#{System.unique_integer([:positive])}"
    assert {:ok, ^id} = Headless.start(app, id: id, width: 80, height: 24, subscriptions: false)
    on_exit(fn -> if Process.whereis(Headless), do: Headless.stop(id) end)

    Enum.each(keys, fn key -> assert :ok = Headless.send_key(id, key) end)
    assert {:ok, frame} = Headless.screenshot(id)
    frame
  end
end
