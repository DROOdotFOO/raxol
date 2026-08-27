[path] = System.argv()

try do
  {opts, _bindings} = Code.eval_file(path)
  import_deps = Keyword.get(opts, :import_deps, [])
  plugins = Keyword.get(opts, :plugins, [])

  cond do
    import_deps != [] ->
      IO.puts(
        :stderr,
        "sets import_deps: #{inspect(import_deps)}, which makes mix format load those deps. " <>
          "This check does not fetch them. Either drop it, or move this package into the " <>
          "package-tests matrix where deps are available."
      )

      System.halt(1)

    plugins != [] ->
      IO.puts(
        :stderr,
        "sets plugins: #{inspect(plugins)}, which makes mix format load compiled plugin " <>
          "modules. This check does not fetch or compile them. Drop the plugins, or move " <>
          "this package into the package-tests matrix where deps are available."
      )

      System.halt(1)

    true ->
      :ok
  end
rescue
  error ->
    IO.puts(
      :stderr,
      "has an unreadable .formatter.exs: #{Exception.message(error)}"
    )

    System.halt(1)
end
