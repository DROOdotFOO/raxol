defmodule Raxol.Test.GeneratedApp do
  @moduledoc """
  Checks app source that Raxol hands to users the way a user meets it:
  compiled, then drawn. That covers what `raxol new` and `mix raxol.new`
  generate, and the fixtures shown alongside them.

  A generated project fetches raxol from Hex. Compiling its files here, against
  the raxol in this build, is the same compile without the fetch.

  Shared with packages/raxol_cli, whose test paths include this directory.
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
  """
  @spec render!(module(), String.t()) :: String.t()
  def render!(app, marker) do
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

    screenshot_until(id, marker, 50, "")
  end

  # The first screenshot after `start` can land before the frame's cells reach
  # the buffer. Each screenshot re-renders synchronously, so a bounded retry
  # converges without sleeping, and an app that never draws `marker` fails at
  # the bound with what it did draw.
  defp screenshot_until(id, marker, 0, last) do
    flunk(
      "#{inspect(id)} never rendered #{inspect(marker)}; last frame:\n#{last}"
    )
  end

  defp screenshot_until(id, marker, attempts, _last) do
    _ = assert {:ok, text} = Headless.screenshot(id)

    if String.contains?(text, marker),
      do: text,
      else: screenshot_until(id, marker, attempts - 1, text)
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
