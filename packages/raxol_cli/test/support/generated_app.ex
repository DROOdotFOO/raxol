defmodule Raxol.Test.GeneratedApp do
  @moduledoc """
  Checks the app `raxol new` generates the way a user meets it: compiled,
  then drawn, and held to `mix format`.

  A generated project fetches raxol from Hex. Compiling its files here, against
  the raxol in this build, is the same compile without the fetch.

  A copy of the checks the root suite runs on `mix raxol.new`'s output: a Hex
  package ships no test support, so this package cannot compile the root's.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Raxol.Headless

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

        flunk("#{inspect(files)} compiled with warnings:\n" <> messages(warnings))

      {:error, errors, warnings} ->
        flunk("#{inspect(files)} failed to compile:\n" <> messages(warnings, errors))
    end
  end

  @doc """
  Starts `app` in a headless session (subscriptions unarmed) and returns the
  text of its frame, which must contain `marker`.

  With `keys:`, presses those keys first, in order.
  """
  @spec render!(module(), String.t(), keyword()) :: String.t()
  def render!(app, marker, opts \\ []) do
    _ =
      if is_nil(Process.whereis(Headless)),
        do: start_supervised!({Headless, [name: Headless]})

    id = "generated_app_#{System.unique_integer([:positive])}"

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
    frame_with!(inspect(id), marker, screenshot!(id))
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

  defp frame_with!(label, marker, text) do
    if String.contains?(text, marker),
      do: text,
      else: flunk("#{label} did not render #{inspect(marker)}; frame:\n#{text}")
  end

  defp press(id, keys) do
    for key <- keys, do: assert(:ok = Headless.send_key(id, key))
  end

  defp screenshot!(id) do
    _ = assert {:ok, text} = Headless.screenshot(id)
    text
  end

  # The frame from the render's own reply: a cast the engine takes between
  # drawing and a separate `:get_buffer` (the dispatcher's `{:update_size, _}`

  defp eval_formatter(path) do
    {opts, _binding} = Code.eval_file(path)
    opts
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
