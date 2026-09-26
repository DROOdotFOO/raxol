defmodule Mix.Raxol.Generator do
  @moduledoc """
  File creation orchestration for `mix raxol.new`.

  Handles directory scaffolding, file writing, git init,
  optional dependency installation, and post-generation output.
  """

  alias Mix.Raxol.{AppTemplates, Content}

  @compile {:no_warn_undefined, [Mix.Raxol.AppTemplates, Mix.Raxol.Content]}

  @doc "Generates the full project structure at `path` with the given opts."
  def generate(name, opts, raxol_version) do
    path = Path.expand(name)
    app = validate_app_name!(Path.basename(path))

    if File.exists?(path) do
      Mix.raise("Directory #{path} already exists")
    end

    bindings = build_bindings(app, opts, raxol_version)
    install? = Keyword.get(opts, :install, false)
    skip_test = Keyword.get(opts, :no_test, false)

    Mix.shell().info([:green, "* creating ", :reset, name])

    create_directories(path, skip_test)
    write_core_files(path, bindings)
    write_app_modules(path, bindings)
    write_optional_files(path, bindings, skip_test)

    git_init(path)
    Mix.shell().info("")

    if install?, do: install_and_verify(path)

    print_instructions(bindings, name, install?)
  end

  defp build_bindings(app, opts, raxol_version) do
    %{
      app: app,
      module: opts[:module] || Macro.camelize(app),
      template: Keyword.get(opts, :template, "counter"),
      sup: Keyword.get(opts, :sup, false),
      ssh: Keyword.get(opts, :ssh, false),
      liveview: Keyword.get(opts, :liveview, false),
      ci: Keyword.get(opts, :ci, false),
      version: raxol_version
    }
  end

  defp create_directories(path, skip_test) do
    File.mkdir_p!(path)
    File.mkdir_p!(Path.join(path, "lib"))
    File.mkdir_p!(Path.join(path, "config"))
    unless skip_test, do: File.mkdir_p!(Path.join(path, "test"))
  end

  defp write_core_files(path, bindings) do
    write_file(path, "mix.exs", Content.mix_exs(bindings))
    write_file(path, "config/config.exs", Content.config_exs(bindings))
    write_file(path, ".formatter.exs", Content.formatter())
    write_file(path, ".gitignore", Content.gitignore())
    write_file(path, "README.md", Content.readme(bindings))
    write_file(path, ".mise.toml", Content.mise_toml())
  end

  defp write_app_modules(path, %{sup: true, app: app} = bindings) do
    write_file(path, "lib/#{app}.ex", Content.app_module_sup(bindings))

    write_file(
      path,
      "lib/#{app}/application.ex",
      Content.application_module(bindings)
    )

    write_file(path, "lib/#{app}/app.ex", Content.tea_module(bindings))
  end

  defp write_app_modules(path, %{app: app} = bindings) do
    write_file(path, "lib/#{app}.ex", Content.tea_module_standalone(bindings))
  end

  defp write_optional_files(path, %{app: app} = bindings, skip_test) do
    if bindings.ssh,
      do: write_file(path, "lib/#{app}/ssh.ex", Content.ssh_module(bindings))

    if bindings.liveview,
      do:
        write_file(
          path,
          "lib/#{app}/live.ex",
          Content.liveview_module(bindings)
        )

    unless skip_test do
      write_file(path, "test/test_helper.exs", Content.test_helper())
      write_file(path, "test/#{app}_test.exs", Content.app_test(bindings))
    end

    if bindings.ci,
      do:
        write_file(
          path,
          ".github/workflows/ci.yml",
          Content.ci_workflow(bindings)
        )
  end

  # --- Private ---

  defp validate_app_name!(name) do
    unless name =~ ~r/^[a-z][a-z0-9_]*$/ do
      Mix.raise(
        "App name must start with a lowercase letter and contain only " <>
          "lowercase letters, numbers, and underscores. Got: #{name}"
      )
    end

    if name in ~w(raxol elixir mix test lib config) do
      Mix.raise("App name #{name} is reserved")
    end

    name
  end

  defp write_file(path, filename, content) do
    filepath = Path.join(path, filename)
    filepath |> Path.dirname() |> File.mkdir_p!()
    File.write!(filepath, content)
    Mix.shell().info(["  ", :green, "* creating ", :reset, filename])
  end

  defp git_init(path) do
    case System.cmd("git", ["init"], cd: path, stderr_to_stdout: true) do
      {_, 0} ->
        _ = System.cmd("git", ["add", "."], cd: path, stderr_to_stdout: true)

        _ =
          System.cmd(
            "git",
            ["commit", "-m", "Initial commit from mix raxol.new"],
            cd: path,
            stderr_to_stdout: true
          )

        Mix.shell().info([
          "  ",
          :green,
          "* initialized ",
          :reset,
          "git repo with initial commit"
        ])

      _ ->
        Mix.shell().info([
          "  ",
          :yellow,
          "* skipping ",
          :reset,
          "git init (git not available)"
        ])
    end
  end

  defp install_and_verify(path) do
    Mix.shell().info([:cyan, "Fetching dependencies...", :reset])

    case System.cmd("mix", ["deps.get"], cd: path, stderr_to_stdout: true) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info([:green, "Dependencies installed.", :reset])
        compile_and_test(path)

      {output, _} ->
        Mix.shell().info(output)

        Mix.shell().error(
          "Failed to install dependencies. Run `mix deps.get` manually."
        )
    end
  end

  defp compile_and_test(path) do
    Mix.shell().info([:cyan, "Compiling...", :reset])

    case System.cmd("mix", ["compile", "--warnings-as-errors"],
           cd: path,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info([:green, "Compilation succeeded.", :reset])
        run_tests(path)

      {output, _} ->
        Mix.shell().info(output)
        Mix.shell().error("Compilation failed.")
    end
  end

  defp run_tests(path) do
    Mix.shell().info([:cyan, "Running tests...", :reset])

    case System.cmd("mix", ["test"],
           cd: path,
           env: [{"MIX_ENV", "test"}],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Mix.shell().info(output)
        Mix.shell().info([:green, "All tests passed.", :reset])

      {output, _} ->
        Mix.shell().info(output)
        Mix.shell().error("Some tests failed.")
    end
  end

  defp print_instructions(bindings, name, installed?) do
    Mix.shell().info([:green, :bright, "Your Raxol app is ready!", :reset])
    Mix.shell().info("")

    print_setup_commands(bindings, name, installed?)
    print_template_hint(bindings)
    print_ssh_hint(bindings)

    Mix.shell().info("")
  end

  defp print_setup_commands(bindings, name, installed?) do
    unless installed? do
      Mix.shell().info(["    ", :cyan, "cd #{name}", :reset])
      Mix.shell().info(["    ", :cyan, "mix deps.get", :reset])
    end

    run_command = AppTemplates.run_command(bindings)
    Mix.shell().info(["    ", :cyan, run_command, :reset])
    Mix.shell().info("")
  end

  defp print_template_hint(%{template: "counter"}),
    do: Mix.shell().info("Press '+'/'-' or click buttons. 'q' to quit.")

  defp print_template_hint(%{template: "todo"}),
    do: Mix.shell().info("Type to add todos, Enter to confirm, 'q' to quit.")

  defp print_template_hint(%{template: "dashboard"}),
    do: Mix.shell().info("Press Tab to cycle panels, 'q' to quit.")

  defp print_template_hint(%{template: "blank", app: app}),
    do: Mix.shell().info("Edit lib/#{app}.ex to build your app.")

  defp print_template_hint(_bindings), do: :ok

  defp print_ssh_hint(%{ssh: true}) do
    Mix.shell().info("")
    Mix.shell().info([:yellow, "SSH server:", :reset, " mix run --no-halt"])

    Mix.shell().info([
      "Then connect: ",
      :cyan,
      "ssh localhost -p 2222",
      :reset
    ])
  end

  defp print_ssh_hint(_bindings), do: :ok
end
