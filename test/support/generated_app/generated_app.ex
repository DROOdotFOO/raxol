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

    assert {:ok, sup} = callback.start(:normal, args)
    Process.unlink(sup)
    on_exit(fn -> stop_supervisor(sup) end)

    sup
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
    assert {:ok, text} = Headless.screenshot(id)
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
