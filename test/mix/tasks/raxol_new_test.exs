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

  defp generate(tmp, flags) do
    name = "gen_#{System.unique_integer([:positive])}"
    project = Path.join(tmp, name)
    capture_io(fn -> Mix.Tasks.Raxol.New.run([project | flags]) end)

    {project, Module.concat([Macro.camelize(name)])}
  end

  defp lib_files(project),
    do: Path.wildcard(Path.join([project, "lib", "**", "*.ex"]))
end
