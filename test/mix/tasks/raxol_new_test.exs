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
  test "--sup starts the TUI with its application, and quitting ends both",
       %{tmp: tmp} do
    {project, _module} = generate(tmp, ["--template", "counter", "--sup"])
    GeneratedApp.compile!(lib_files(project))

    sup = GeneratedApp.start_application!(project)

    assert [{_id, tui, :worker, _modules}] = Supervisor.which_children(sup)
    assert GeneratedApp.frame!(tui, "Count: 0") =~ "'q' to quit."

    # Quitting ends the TUI normally. Restarting it would bring back an app
    # the user just quit, so the supervisor has to shut down instead.
    ref = Process.monitor(sup)
    Raxol.Core.Runtime.Lifecycle.stop_application(tui)
    assert_receive {:DOWN, ^ref, :process, ^sup, :shutdown}, 5_000
  end

  test "--sup --ssh serves the app over SSH when its application starts",
       %{tmp: tmp} do
    flags = ["--template", "counter", "--sup", "--ssh"]
    {project, _module} = generate(tmp, flags)
    GeneratedApp.compile!(lib_files(project))

    keys_dir = Path.join(tmp, "ssh_host_keys")

    sup =
      GeneratedApp.start_application!(project, ssh: [host_keys_dir: keys_dir])

    assert [{Raxol.SSH.Server, server, :worker, _modules}] =
             Supervisor.which_children(sup)

    assert Raxol.SSH.Server.port(server) > 0
  end

  # Without --sup nothing starts the server: the generator's instructions run
  # `<Module>.SSH.start()`, which has to find its settings in the config.
  test "--ssh generates an SSH.start/0 that serves the app", %{tmp: tmp} do
    {project, module} = generate(tmp, ["--template", "counter", "--ssh"])
    ssh = Module.concat(module, SSH)
    assert ssh in GeneratedApp.compile!(lib_files(project))

    keys_dir = Path.join(tmp, "ssh_host_keys")
    GeneratedApp.put_config!(project, ssh: [host_keys_dir: keys_dir])

    assert {:ok, server} = ssh.start()
    Process.unlink(server)
    on_exit(fn -> stop(server) end)

    assert Raxol.SSH.Server.port(server) > 0
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
