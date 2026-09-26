defmodule Mix.Tasks.Raxol.NewTest do
  # Generates every template, with and without --sup, and holds each project to
  # what its README promises: lib/ compiles and the app draws. Not async: the
  # setup below changes the VM-wide environment the generator's git reads.
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  import ExUnit.CaptureIO

  alias Raxol.Test.GeneratedApp

  # Lines each template's first frame draws. More than one where the view has
  # more than one child, so a container that keeps only its last child fails.
  @first_frames %{
    "blank" => ["-- edit this view!"],
    "counter" => ["Count: 0", "'q' to quit."],
    "todo" => ["Todo List", "No todos yet. Press 'a' to add one.", "a:add"],
    "dashboard" => ["System Info", "Uptime: 0s", "q:quit"]
  }

  # The generator commits the new project under the caller's git config, and a
  # config that signs commits can stop on a signing prompt. Without the global
  # and system files the commit asks nothing; whether it lands does not matter
  # here.
  @git_without_config [
    {"GIT_CONFIG_GLOBAL", "/dev/null"},
    {"GIT_CONFIG_NOSYSTEM", "1"}
  ]

  setup do
    for {key, value} <- @git_without_config do
      previous = System.get_env(key)
      System.put_env(key, value)

      on_exit(fn ->
        if previous,
          do: System.put_env(key, previous),
          else: System.delete_env(key)
      end)
    end

    tmp = Path.join(System.tmp_dir!(), "raxol_new_#{System.unique_integer()}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    %{tmp: tmp}
  end

  for {template, lines} <- @first_frames, sup? <- [false, true] do
    flags = ["--template", template] ++ if(sup?, do: ["--sup"], else: [])

    test "#{Enum.join(flags, " ")} generates an app that compiles and renders",
         %{tmp: tmp} do
      {project, module} = generate(tmp, unquote(flags))
      app = if unquote(sup?), do: Module.concat(module, App), else: module

      assert app in GeneratedApp.compile!(lib_files(project))

      [first | _] = lines = unquote(lines)
      frame = GeneratedApp.render!(app, first)
      for line <- lines, do: assert(frame =~ line)
    end
  end

  # `mix new`'s rule, which `raxol new` keeps too: a project whose module
  # already exists would redefine it (`enum` would compile `Enum`). A name
  # with a trailing newline is not a name at all.
  for {name, flags} <- [
        {"agent", []},
        {"enum", []},
        {"gen\n", []},
        {"gen_enum", ["--module", "Enum"]}
      ] do
    test "#{inspect(Enum.join([name | flags], " "))} fails before creating anything",
         %{tmp: tmp} do
      project = Path.join(tmp, unquote(name))
      args = [project, "--template", "counter" | unquote(flags)]

      assert_raise Mix.Error, fn ->
        capture_io(fn -> Mix.Tasks.Raxol.New.run(args) end)
      end

      refute File.exists?(project)
    end
  end

  test "--ssh and --liveview modules compile with the app", %{tmp: tmp} do
    flags = ["--template", "counter", "--sup", "--ssh", "--liveview"]
    {project, module} = generate(tmp, flags)

    modules = GeneratedApp.compile!(lib_files(project))

    for part <- [Application, App, SSH, Live] do
      assert Module.concat(module, part) in modules
    end
  end

  test "counter binds the keys its hint names", %{tmp: tmp} do
    {project, module} = generate(tmp, ["--template", "counter"])
    assert module in GeneratedApp.compile!(lib_files(project))

    assert GeneratedApp.render!(module, "Count: 0") =~
             "Press '+'/'-' or click buttons. 'q' to quit."

    # "=" is "+" without Shift, so it counts up as well.
    assert GeneratedApp.render!(module, "Count: 2", keys: ["+", "=", "+", "-"])
  end

  # `mix run --no-halt`, which a --sup app's README and the generator's
  # instructions give as the way to run it, only starts the application.
  test "--sup starts the TUI with its application", %{tmp: tmp} do
    {project, _module} = generate(tmp, ["--template", "counter", "--sup"])
    GeneratedApp.compile!(lib_files(project))

    tui = :"#{Path.basename(project)}_tui"
    GeneratedApp.start_application!(project, raxol: [name: tui])

    assert GeneratedApp.frame!(Process.whereis(tui), "Count: 0") =~
             "'q' to quit."
  end

  # Once the TUI is gone, `--no-halt` would keep the VM running with nothing
  # in it, so the application stops the VM. That is only right when the TUI
  # ended: a test that stops the application must not end the test run. The
  # application runs in a VM of its own, since it stops that VM.
  for {ending, ends_tui, status} <- [
        {"quits", "Raxol.Core.Runtime.Lifecycle.stop_application(tui)", 0},
        {"fails", "Process.exit(tui, :crash)", 1}
      ] do
    test "--sup stops the VM with status #{status} when its TUI #{ending}, " <>
           "not when its application stops",
         %{tmp: tmp} do
      {project, module} = generate(tmp, ["--template", "counter", "--sup"])

      {output, exit_status} =
        GeneratedApp.run_application(
          project,
          """
          stopping? = fn -> match?({:stopping, _}, :init.get_status()) end

          :ok = Application.stop(app)
          IO.puts("stopping after Application.stop: \#{stopping?.()}")
          {:ok, _started} = Application.ensure_all_started(app)

          [{_id, runner, _type, _modules}] =
            Supervisor.which_children(#{inspect(Module.concat(module, Supervisor))})

          ref = Process.monitor(runner)
          tui = Process.whereis(:generated_tui)
          #{unquote(ends_tui)}
          receive do: ({:DOWN, ^ref, _, _, _} -> :ok)

          # Nothing stopped the VM: say so rather than wait forever.
          unless stopping?.(), do: System.halt(2)
          Process.sleep(:infinity)
          """,
          raxol: [name: :generated_tui]
        )

      assert output =~ "stopping after Application.stop: false"
      assert exit_status == unquote(status)
    end
  end

  # IEx reads the same terminal: a TUI started under `iex -S mix` would pass
  # every key typed into it to IEx as well, which evaluates them.
  test "--sup does not start the TUI under IEx", %{tmp: tmp} do
    {project, _module} = generate(tmp, ["--template", "counter", "--sup"])
    GeneratedApp.compile!(lib_files(project))

    {:ok, started} = Application.ensure_all_started(:iex)
    on_exit(fn -> Enum.each(started, &Application.stop/1) end)

    {sup, output} =
      with_io(fn -> GeneratedApp.start_application!(project) end)

    assert Supervisor.which_children(sup) == []
    assert output =~ "mix run --no-halt"
  end

  test "--sup --ssh serves the app over SSH when its application starts",
       %{tmp: tmp} do
    flags = ["--template", "counter", "--sup", "--ssh"]
    {project, _module} = generate(tmp, flags)
    GeneratedApp.compile!(lib_files(project))

    sup = GeneratedApp.start_application!(project)

    assert [{Raxol.SSH.Server, server, :worker, _modules}] =
             Supervisor.which_children(sup)

    assert Raxol.SSH.Server.port(server) > 0

    # `mix test` keeps the server's host key in the project, not in the
    # developer's ~/.raxol/ssh_keys.
    assert File.exists?(
             Path.join(project, "_build/test/ssh/ssh_host_ed25519_key")
           )
  end

  test "--ssh serves without authentication in dev only", %{tmp: tmp} do
    {project, _module} = generate(tmp, ["--template", "counter", "--ssh"])
    app = project |> Path.basename() |> String.to_atom()

    anonymous? = fn env ->
      config =
        Config.Reader.read!(Path.join(project, "config/config.exs"), env: env)

      get_in(config, [app, :ssh, :allow_anonymous]) == true
    end

    assert anonymous?.(:dev)
    refute anonymous?.(:test)
    refute anonymous?.(:prod)
  end

  # Without --sup nothing starts the server: the generator's instructions run
  # `<Module>.SSH.start()`, which has to find its settings in the config.
  test "--ssh generates an SSH.start/0 that serves the app", %{tmp: tmp} do
    {project, module} = generate(tmp, ["--template", "counter", "--ssh"])
    ssh = Module.concat(module, SSH)
    assert ssh in GeneratedApp.compile!(lib_files(project))

    GeneratedApp.put_config!(project)

    assert {:ok, server} = ssh.start()
    Process.unlink(server)
    on_exit(fn -> stop(server) end)

    assert Raxol.SSH.Server.port(server) > 0
  end

  # The module name goes into every generated file, which the generator
  # formats, so a name that does not parse would fail with files written.
  test "--module that is not an alias fails before creating anything",
       %{tmp: tmp} do
    project = Path.join(tmp, "bad_module")

    assert_raise Mix.Error, fn ->
      capture_io(fn ->
        Mix.Tasks.Raxol.New.run([
          project,
          "--template",
          "counter",
          "--module",
          "My App"
        ])
      end)
    end

    refute File.exists?(project)
  end

  # The generated --ci workflow runs `mix format --check-formatted`, so every
  # combination of the flags that shape generated Elixir has to pass it as
  # generated.
  for template <- Map.keys(@first_frames),
      sup <- [[], ["--sup"]],
      ssh <- [[], ["--ssh"]],
      liveview <- [[], ["--liveview"]] do
    flags = ["--template", template, "--ci"] ++ sup ++ ssh ++ liveview

    test "#{Enum.join(flags, " ")} generates a mix format-clean project",
         %{tmp: tmp} do
      {project, _module} = generate(tmp, unquote(flags))
      GeneratedApp.assert_formatted!(project)
    end
  end

  defp generate(tmp, flags) do
    name = "gen_#{System.unique_integer([:positive])}"
    project = Path.join(tmp, name)
    capture_io(fn -> Mix.Tasks.Raxol.New.run([project | flags]) end)

    {project, Module.concat([Macro.camelize(name)])}
  end

  # The server can exit between the check and the stop.
  defp stop(server) do
    if Process.alive?(server), do: GenServer.stop(server)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp lib_files(project),
    do: Path.wildcard(Path.join([project, "lib", "**", "*.ex"]))
end
