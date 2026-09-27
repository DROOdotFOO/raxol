defmodule Raxol.Test.GeneratedApp do
  @moduledoc """
  Checks app source that Raxol hands to users the way a user meets it:
  compiled, then drawn, or started as the application it generates, and held
  to `mix format`. That covers what `raxol new` and `mix raxol.new` generate,
  and the fixtures shown alongside them.

  A generated project fetches raxol from Hex. Compiling its files here, against
  the raxol in this build, is the same compile without the fetch.

  Shared with packages/raxol_cli, whose test paths include this directory.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Raxol.Headless
  alias Raxol.Headless.TextCapture

  # Under ExUnit's 60 s default, so a VM that never exits fails with its
  # output instead of a bare test timeout.
  @run_application_timeout_ms 45_000

  @doc """
  Compiles `files` together and returns the modules they define, purging them
  when the test exits.

  Fails on any error or warning, since generated CI compiles with
  `--warnings-as-errors`. Before compiling, fails on any top-level expression
  other than `defmodule`: compiling a file runs such code, so a file under
  `lib/` that holds some would run it inside `mix compile`.
  """
  @spec compile!([Path.t()]) :: [module()]
  def compile!(files) do
    Enum.each(files, &refute_top_level_code/1)

    case Kernel.ParallelCompiler.compile(files, return_diagnostics: true) do
      {:ok, modules, %{compile_warnings: [], runtime_warnings: []}} ->
        on_exit(fn -> purge(modules) end)
        modules

      {:ok, modules, warnings} ->
        purge(modules)

        flunk(
          "#{inspect(files)} compiled with warnings:\n" <> messages(warnings)
        )

      {:error, errors, warnings} ->
        flunk(
          "#{inspect(files)} failed to compile:\n" <> messages(warnings, errors)
        )
    end
  end

  @doc """
  Starts `app` in a headless session (subscriptions unarmed) and returns the
  text of its first rendered frame that contains `marker`.

  With `keys:`, presses those keys first, in order.
  """
  @spec render!(module(), String.t(), keyword()) :: String.t()
  def render!(app, marker, opts \\ []) do
    _ =
      if is_nil(Process.whereis(Headless)),
        do: start_supervised!({Headless, [name: Headless]})

    id = :"generated_app_#{System.unique_integer([:positive])}"

    _ =
      assert {:ok, ^id} =
               Headless.start(app,
                 id: id,
                 width: 80,
                 height: 24,
                 subscriptions: false
               )

    on_exit(fn -> if Process.whereis(Headless), do: Headless.stop(id) end)

    press(id, Keyword.get(opts, :keys, []))
    capture_until(inspect(id), marker, fn -> screenshot!(id) end)
  end

  @doc """
  Returns the text of the first frame containing `marker` that the TUI running
  under `lifecycle`, a pid `Raxol.start_link/2` returned, renders.
  """
  @spec frame!(pid(), String.t()) :: String.t()
  def frame!(lifecycle, marker) do
    %{rendering_engine_pid: engine} =
      GenServer.call(lifecycle, :get_full_state)

    capture_until(inspect(lifecycle), marker, fn -> capture!(engine) end)
  end

  @doc """
  Starts the application of the generated project at `project` the way
  `mix run` and `mix test` start it: through the callback its `mix.exs`
  names, with its `config/config.exs` read for the test env. `overrides`
  (`[{key, keyword}]`) is merged into the project's application env on top.

  Returns the top supervisor. When the test exits it is stopped, and the
  application env restored.

  `lib/` must already be compiled (see `compile!/1`).
  """
  @spec start_application!(Path.t(), keyword()) :: pid()
  def start_application!(project, overrides \\ []) do
    {app, mod} = mix_application(project)

    {callback, args} =
      mod ||
        flunk(
          "#{project}/mix.exs names no application callback (`mod:`), " <>
            "so starting its application runs nothing"
        )

    put_config(project, app, overrides)

    _ = assert {:ok, sup} = callback.start(:normal, args)
    Process.unlink(sup)
    on_exit(fn -> stop_supervisor(sup) end)

    sup
  end

  @doc """
  Applies the generated project's `config/config.exs`, read for the test env,
  with `overrides` merged into its own application's env, as `mix test` would.
  Restored when the test exits. For a project with no application to start.
  """
  @spec put_config!(Path.t(), keyword()) :: :ok
  def put_config!(project, overrides \\ []) do
    {app, _mod} = mix_application(project)
    put_config(project, app, overrides)
    :ok
  end

  @doc """
  Starts the application of the generated project at `project` in a VM of its
  own, evaluates `code` there with `app` bound to the application's name, and
  returns that VM's output and exit status.

  For what a test's own VM could not survive, such as an application that
  stops the VM. The new VM is `mix run` of this build, compiles the project's
  `lib/` itself, and reads its `config/config.exs` for the test env, with
  `overrides` merged in as `start_application!/2` does.

  A VM that has not exited within #{div(@run_application_timeout_ms, 1000)} s is
  killed and the test fails with everything it printed, which a test timeout
  (the VM still running under `System.cmd/3`) would throw away.
  """
  @spec run_application(Path.t(), String.t(), keyword()) ::
          {String.t(), non_neg_integer()}
  def run_application(project, code, overrides \\ []) do
    {app, mod} = mix_application(project)
    mod || flunk("#{project}/mix.exs names no application callback (`mod:`)")

    script = """
    app = #{inspect(app)}
    lib = Path.wildcard(#{inspect(Path.join(project, "lib/**/*.ex"))})
    {:ok, modules, _warnings} = Kernel.ParallelCompiler.compile(lib)

    #{inspect(Path.join(project, "config/config.exs"))}
    |> Config.Reader.read!(env: :test)
    |> Config.Reader.merge([{app, #{inspect(overrides)}}])
    |> Application.put_all_env()

    spec = [
      description: ~c"generated",
      vsn: ~c"0.1.0",
      modules: modules,
      applications: [:kernel, :stdlib, :elixir, :logger],
      mod: #{inspect(mod)}
    ]

    :ok = :application.load({:application, app, spec})
    {:ok, _started} = Application.ensure_all_started(app)
    """

    # HOME as this VM booted with: a test that repoints HOME and does not
    # restore it would leave `mix` without the Hex under ~/.mix, and the VM
    # waiting on Hex's install prompt.
    {:ok, [[home]]} = :init.get_argument(:home)

    run_bounded(
      System.find_executable("mix"),
      ["run", "--no-compile", "--no-deps-check", "-e", script <> code],
      [{~c"MIX_ENV", ~c"test"}, {~c"HOME", home}]
    )
  end

  defp run_bounded(executable, args, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: env
      ])

    deadline = System.monotonic_time(:millisecond) + @run_application_timeout_ms
    collect_output(port, [], deadline)
  end

  # The bound is on the whole run, not the gap between two writes, so a VM
  # that hangs while still logging is killed too.
  defp collect_output(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_output(port, [acc, data], deadline)

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(acc), status}
    after
      remaining ->
        {:os_pid, os_pid} = Port.info(port, :os_pid)
        _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)])

        flunk("""
        The application's VM had not exited after \
        #{div(@run_application_timeout_ms, 1000)} s and was killed. It printed:

        #{IO.iodata_to_binary(acc)}
        """)
    end
  end

  @doc """
  Runs `mix format --check-formatted` in the generated project at `project`,
  under the `.formatter.exs` it generated, and fails naming every file the
  formatter would change.

  That file imports no deps, so the check needs no `deps.get`.
  """
  @spec assert_formatted!(Path.t()) :: :ok
  def assert_formatted!(project) do
    formatter_opts = project |> Path.join(".formatter.exs") |> eval_formatter()
    refute Keyword.has_key?(formatter_opts, :import_deps)

    File.cd!(project, fn -> Mix.Tasks.Format.run(["--check-formatted"]) end)
    :ok
  rescue
    error in Mix.Error ->
      flunk("#{project} is not `mix format` clean:\n" <> error.message)
  end

  # The first capture after `start` can land before the frame's cells reach
  # the buffer. Each capture re-renders synchronously, so a bounded retry
  # converges without sleeping, and an app that never draws `marker` fails at
  # the bound with what it did draw.
  defp capture_until(label, marker, capture, attempts \\ 50, last \\ "")

  defp capture_until(label, marker, _capture, 0, last) do
    flunk("#{label} never rendered #{inspect(marker)}; last frame:\n#{last}")
  end

  defp capture_until(label, marker, capture, attempts, _last) do
    text = capture.()

    if String.contains?(text, marker),
      do: text,
      else: capture_until(label, marker, capture, attempts - 1, text)
  end

  defp press(_id, []), do: :ok

  # Keys reach update/2 asynchronously. A message sent after them waits for
  # update/2 to take it, and the app's queue takes them in order, so by then
  # every key has been handled.
  defp press(id, keys) do
    for key <- keys, do: assert(:ok = Headless.send_key(id, key))
    assert :ok = Headless.send_message(id, :generated_app_keys_pressed)
  end

  defp screenshot!(id) do
    _ = assert {:ok, text} = Headless.screenshot(id)
    text
  end

  defp capture!(engine) do
    GenServer.call(engine, :render_frame_sync)

    case GenServer.call(engine, :get_buffer) do
      {:ok, nil} -> ""
      {:ok, buffer} -> TextCapture.capture(buffer)
    end
  end

  defp mix_application(project) do
    name = project |> Path.basename() |> String.to_atom()

    Mix.Project.in_project(name, project, fn mix_project ->
      on_exit(fn -> purge([mix_project]) end)
      {mix_project.project()[:app], mix_project.application()[:mod]}
    end)
  end

  defp eval_formatter(path) do
    {opts, _binding} = Code.eval_file(path)
    opts
  end

  defp put_config(project, app, overrides) do
    config =
      project
      |> Path.join("config/config.exs")
      |> Config.Reader.read!(env: :test)
      |> Config.Reader.merge([{app, overrides}])

    for {config_app, pairs} <- config,
        {key, value} <- pairs,
        do: put_env(config_app, key, value)

    :ok
  end

  # A test that quits the app has already taken the supervisor down, and it
  # can go between the check and the stop.
  defp stop_supervisor(sup) do
    if Process.alive?(sup), do: Supervisor.stop(sup)
  catch
    :exit, :noproc -> :ok
    :exit, {:noproc, _call} -> :ok
  end

  defp put_env(app, key, value) do
    previous = Application.fetch_env(app, key)
    Application.put_env(app, key, value)

    on_exit(fn ->
      case previous do
        {:ok, previous} -> Application.put_env(app, key, previous)
        :error -> Application.delete_env(app, key)
      end
    end)
  end

  defp refute_top_level_code(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    code =
      ast
      |> case do
        {:__block__, _, exprs} -> exprs
        expr -> [expr]
      end
      |> Enum.reject(&match?({:defmodule, _, _}, &1))

    assert code == [],
           "#{file} runs code when compiled:\n\n" <>
             Enum.map_join(code, "\n", &Macro.to_string/1)
  end

  defp messages(warnings, errors \\ []) do
    %{compile_warnings: compile, runtime_warnings: runtime} = warnings

    Enum.map_join(errors ++ compile ++ runtime, "\n", fn diagnostic ->
      "  #{diagnostic.file}:#{inspect(diagnostic.position)}: #{diagnostic.message}"
    end)
  end

  defp purge(modules) do
    Enum.each(modules, fn module ->
      _ = :code.purge(module)
      _ = :code.delete(module)
    end)
  end
end
