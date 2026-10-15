# Guard against packages reaching across the dependency graph.
#
#   elixir scripts/check_package_boundaries.exs               # check the tree
#   elixir scripts/check_package_boundaries.exs --base REF    # ... and that the
#                                                              # allowlist did not
#                                                              # grow since REF
#
# docs/PACKAGES.md declares `raxol --> raxol_core, raxol_terminal, ...` and
# never the reverse. Every package in CI compiles standalone with
# `--warnings-as-errors`, so a call into a module the package's mix.exs does
# not pull in is a compile error -- unless the file silences it with
# `@compile {:no_warn_undefined, Mod}`, or names the module in a way the
# compiler does not check (`apply/3`, a module held in a variable, an atom).
# That is how four call sites in raxol_terminal came to raise
# `UndefinedFunctionError` the moment the package was used without main raxol
# on the code path: the comment next to each said "guarded at runtime", and
# nothing was.
#
# This check parses every `packages/*/lib/**/*.ex` with
# `Code.string_to_quoted/2`, resolves `alias`/`require ..., as:` per lexical
# scope, and collects every module the file names: remote calls and captures,
# every form of `@compile no_warn_undefined` (tuple, keyword, wrapped list,
# `{M, f, a}` entries, an `@attr` holding any of those), `apply/3` with a
# literal module, `:"Elixir.X"` atoms, literal `Module.concat/1,2` and
# `String.to_atom("Elixir.X")`, `use`/`import`/`require`/`@behaviour`, and
# modules used as plain values. Each is resolved to the tree that defines it
# (main `lib/`, or `packages/<name>/lib`; every `defmodule`, `defprotocol` and
# `defimpl` there, nested ones included). A module owned by a tree the package
# does not declare is a violation. A `Raxol.*` module defined nowhere in the
# repo is reported as `undefined`: the reference is then either dead or
# pointing at a name that was renamed out from under it. Modules from Hex
# dependencies (Jason, Req, ...) are someone else's concern and not checked.
#
# "Declares" is read from the AST of the package's mix.exs, starting at the
# `deps:` entry of `project/0` and following the local functions it calls:
# `{:name, ...}` tuples and the `raxol_dep(:name, ...)` helper. A dependency
# whose `only:` leaves out :prod is not on the code path in production and
# does not count; text in a comment does not exist for the parser. Optional
# dependencies count: the package has opted into guarding them. The relation is
# transitive (a package that depends on `raxol` sees raxol_core too). A
# package directory without a mix.exs, or a file that does not parse, fails
# the check rather than being skipped.
#
# Existing offenders are listed in scripts/.package-boundaries-allowlist as
# `file<TAB>module<TAB>owning tree`. It only shrinks: an entry that no longer
# matches fails the check so the list cannot rot, and with `--base REF` (CI
# passes the pull request's base commit) an entry that REF's allowlist does
# not have fails too. Fix a new report by moving the module into the package
# that owns the concept, by reading the implementation from application config
# with an in-package default, or by deleting the dead call. Do NOT add
# `Code.ensure_loaded?/1`: that is the guard that hid the originals.
#
# Needs only `elixir`: no compiled app, no fetched deps, no git (except for
# `--base`).

defmodule PackageBoundaries do
  @allowlist "scripts/.package-boundaries-allowlist"
  @typespec_attrs [:spec, :type, :typep, :opaque, :callback, :macrocallback]
  @sticky_kinds [:compile, :typespec]

  def main(argv) do
    File.cd!(Path.expand("..", __DIR__))

    base =
      case OptionParser.parse(argv, strict: [base: :string]) do
        {opts, [], []} ->
          opts[:base]

        _ ->
          fatal([
            "usage: elixir scripts/check_package_boundaries.exs [--base REF]"
          ])
      end

    trees = trees()
    sources = Map.new(trees, &{&1, sources_of(&1)})

    if Enum.all?(trees -- ["raxol"], &(sources[&1] == [])) do
      fatal(["no package sources found under packages/*/lib"])
    end

    parsed =
      for {tree, files} <- sources, file <- files do
        {tree, file, parse(file)}
      end

    case for({_, _, {:error, msg}} <- parsed, do: msg) do
      [] -> :ok
      errors -> fatal(["cannot parse, refusing to guess:" | errors])
    end

    scanned =
      for {tree, file, {:ok, ast}} <- parsed do
        {tree, file, scan(ast)}
      end

    owners =
      Enum.reduce(scanned, %{}, fn {tree, _file, %{defs: defs}}, acc ->
        Enum.reduce(defs, acc, fn mod, acc ->
          Map.update(acc, mod, MapSet.new([tree]), &MapSet.put(&1, tree))
        end)
      end)

    direct = Map.new(trees, &{&1, direct_deps(&1, trees)})

    found =
      for {tree, file, %{refs: refs}} <- scanned,
          tree != "raxol",
          visible = declared(tree, direct),
          {mod, line, kind} <- refs,
          owner <- violations(mod, kind, owners, visible),
          reduce: %{} do
        acc ->
          Map.update(
            acc,
            {file, mod, owner},
            [{line, kind}],
            &[{line, kind} | &1]
          )
      end

    allowed = read_allowlist()
    found_keys = found |> Map.keys() |> MapSet.new()

    new =
      found
      |> Enum.reject(fn {key, _} -> MapSet.member?(allowed, key) end)
      |> Enum.sort()

    stale = allowed |> MapSet.difference(found_keys) |> Enum.sort()
    grown = if base, do: grown_since(base, allowed), else: []

    report_new(new)
    report_stale(stale)
    report_grown(grown, base)

    if new == [] and stale == [] and grown == [] do
      IO.puts(
        "OK: package boundaries hold (#{MapSet.size(found_keys)} grandfathered cross-package references)"
      )
    else
      exit({:shutdown, 1})
    end
  end

  ## Trees, sources, parsing

  defp trees do
    packages =
      "packages/*"
      |> Path.wildcard()
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&Path.basename/1)

    case Enum.reject(packages, &File.regular?(mixfile(&1))) do
      [] -> :ok
      missing -> fatal(Enum.map(missing, &"packages/#{&1} has no mix.exs"))
    end

    Enum.sort(["raxol" | packages])
  end

  defp mixfile("raxol"), do: "mix.exs"
  defp mixfile(pkg), do: "packages/#{pkg}/mix.exs"

  defp sources_of("raxol"), do: Path.wildcard("lib/**/*.ex") |> Enum.sort()

  defp sources_of(pkg),
    do: Path.wildcard("packages/#{pkg}/lib/**/*.ex") |> Enum.sort()

  defp parse(file) do
    with {:ok, src} <- File.read(file),
         {:ok, ast} <-
           Code.string_to_quoted(src, file: file, emit_warnings: false) do
      {:ok, ast}
    else
      {:error, {meta, message, token}} ->
        {:error, "  #{file}:#{meta[:line]}: #{format_message(message)}#{token}"}

      {:error, reason} ->
        {:error, "  #{file}: #{:file.format_error(reason)}"}
    end
  end

  defp format_message({prefix, suffix}), do: "#{prefix}#{suffix} "
  defp format_message(message), do: "#{message} "

  ## Dependencies declared in mix.exs

  defp direct_deps(tree, trees) do
    file = mixfile(tree)

    ast =
      case parse(file) do
        {:ok, ast} -> ast
        {:error, msg} -> fatal(["cannot parse, refusing to guess:", msg])
      end

    funs = mix_functions(ast)

    deps_expr =
      with [_ | _] = clauses <- Map.get(funs, {:project, 0}),
           [expr | _] <-
             for(body <- clauses, expr <- keyword_values(body, :deps), do: expr) do
        expr
      else
        _ -> fatal(["#{file}: no `deps:` entry in project/0"])
      end

    deps_expr
    |> dep_entries(funs, MapSet.new(), file)
    |> Enum.map(fn {name, opts} -> {Atom.to_string(name), opts} end)
    |> Enum.filter(fn {name, opts} ->
      name in trees and prod?(opts, file, name)
    end)
    |> Enum.map(&elem(&1, 0))
    |> MapSet.new()
  end

  # {name, arity} => [body] for every def/defp in the mix.exs module.
  defp mix_functions(ast) do
    {_, funs} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [{:do, body} | _]]} = node, acc
        when kind in [:def, :defp] ->
          {name, args} =
            case head do
              {:when, _, [{name, _, args} | _]} -> {name, args}
              {name, _, args} -> {name, args}
            end

          arity = if is_list(args), do: length(args), else: 0
          {node, Map.update(acc, {name, arity}, [body], &(&1 ++ [body]))}

        node, acc ->
          {node, acc}
      end)

    funs
  end

  defp keyword_values(ast, key) do
    {_, acc} =
      Macro.prewalk(ast, [], fn
        {^key, value} = node, acc -> {node, [value | acc]}
        node, acc -> {node, acc}
      end)

    Enum.reverse(acc)
  end

  # Every `{:name, ...}` / `raxol_dep(:name, ...)` reachable from `ast`,
  # following calls to local functions. Returns [{name, opts_ast}].
  defp dep_entries(ast, funs, seen, file) do
    case ast do
      {:raxol_dep, _, [name | rest]} when is_atom(name) ->
        [{name, rest |> List.last() |> keyword_or_empty()}]

      {name, req_or_opts} when is_atom(name) and name not in [:do, :else] ->
        [{name, keyword_or_empty(req_or_opts)}]

      {:{}, _, [name, _req, opts]} when is_atom(name) ->
        [{name, keyword_or_empty(opts)}]

      {fun, _, args} when is_atom(fun) and is_list(args) ->
        key = {fun, length(args)}
        local = Map.get(funs, key, [])

        from_local =
          if local != [] and not MapSet.member?(seen, key) do
            Enum.flat_map(
              local,
              &dep_entries(&1, funs, MapSet.put(seen, key), file)
            )
          else
            []
          end

        from_local ++ Enum.flat_map(args, &dep_entries(&1, funs, seen, file))

      {form, _, args} when is_list(args) ->
        dep_entries(form, funs, seen, file) ++
          Enum.flat_map(args, &dep_entries(&1, funs, seen, file))

      {left, right} ->
        dep_entries(left, funs, seen, file) ++
          dep_entries(right, funs, seen, file)

      list when is_list(list) ->
        Enum.flat_map(list, &dep_entries(&1, funs, seen, file))

      _ ->
        []
    end
  end

  defp keyword_or_empty(list) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)),
      do: list,
      else: []
  end

  defp keyword_or_empty(_), do: []

  defp prod?(opts, file, name) do
    case Keyword.fetch(opts, :only) do
      :error ->
        true

      {:ok, env} when is_atom(env) ->
        env == :prod

      {:ok, envs} when is_list(envs) ->
        if Enum.all?(envs, &is_atom/1),
          do: :prod in envs,
          else: fatal(["#{file}: cannot read `only:` of #{inspect(name)}"])

      {:ok, _} ->
        fatal(["#{file}: cannot read `only:` of #{inspect(name)}"])
    end
  end

  defp declared(tree, direct), do: closure([tree], direct, MapSet.new())

  defp closure([], _direct, seen), do: seen

  defp closure([tree | rest], direct, seen) do
    if MapSet.member?(seen, tree) do
      closure(rest, direct, seen)
    else
      closure(
        MapSet.to_list(Map.get(direct, tree, MapSet.new())) ++ rest,
        direct,
        MapSet.put(seen, tree)
      )
    end
  end

  # A Raxol.* name that no tree defines is only a module reference when code
  # calls or compiles against it; as a plain value it is usually a process
  # name (`name: Raxol.Agent.Registry`), which is not a module at all.
  defp violations(mod, kind, owners, visible) do
    case Map.fetch(owners, mod) do
      {:ok, trees} ->
        if MapSet.disjoint?(trees, visible), do: Enum.sort(trees), else: []

      :error ->
        if String.starts_with?(mod, "Raxol.") and
             kind in [:call, :apply, :compile, :directive, :concat],
           do: ["undefined"],
           else: []
    end
  end

  ## Source scan: module definitions and references

  # Returns %{defs: [module], refs: [{module, line, kind}]}, module names as
  # strings without the "Elixir." prefix.
  def scan(ast) do
    env = %{module: nil, aliases: %{}, attrs: %{}, kind: :value, line: nil}
    {_env, acc} = walk(ast, env, %{defs: [], refs: []})
    acc
  end

  defp walk({:__block__, _, stmts}, env, acc) when is_list(stmts) do
    {_, acc} =
      Enum.reduce(stmts, {env, acc}, fn stmt, {env, acc} ->
        walk(stmt, env, acc)
      end)

    {env, acc}
  end

  defp walk({def, meta, [name, kw]}, env, acc)
       when def in [:defmodule, :defprotocol] and is_list(kw) do
    case expand_module_name(name, env) do
      {:ok, full, alias_entry} ->
        acc = %{acc | defs: [join(full) | acc.defs]}
        inner = %{env | module: full, attrs: %{}, kind: :value}
        {_, acc} = walk(kw, inner, acc)
        {add_alias(env, alias_entry), acc}

      :error ->
        walk_children({def, meta, [name, kw]}, env, acc)
    end
  end

  defp walk({:defimpl, meta, [proto | rest]} = node, env, acc) do
    kw = List.first(rest, [])
    {protos, acc} = names_and_refs(proto, env, acc, meta)

    {fors, acc} =
      case Keyword.fetch(List.wrap(kw), :for) do
        {:ok, targets} -> names_and_refs(targets, env, acc, meta)
        :error when env.module != nil -> {[env.module], acc}
        :error -> {[], acc}
      end

    impls = for p <- protos, f <- fors, do: p ++ f

    case impls do
      [] ->
        walk_children(node, env, acc)

      [first | _] ->
        acc = %{acc | defs: Enum.map(impls, &join/1) ++ acc.defs}
        body = Keyword.take(List.wrap(kw), [:do])

        {_, acc} =
          walk(body, %{env | module: first, attrs: %{}, kind: :value}, acc)

        {env, acc}
    end
  end

  defp walk({:alias, meta, [target | opts]}, env, acc) do
    as = opts |> List.first([]) |> keyword_or_empty() |> Keyword.get(:as)

    case alias_entries(target, as, env) do
      {:ok, entries} -> {Enum.reduce(entries, env, &add_alias(&2, &1)), acc}
      :error -> walk_children({:alias, meta, [target | opts]}, env, acc)
    end
  end

  defp walk({directive, _meta, [target | opts]}, env, acc)
       when directive in [:require, :import, :use] do
    {_, acc} = walk(target, %{env | kind: :directive}, acc)
    {_, acc} = walk(opts, env, acc)
    as = opts |> List.first([]) |> keyword_or_empty() |> Keyword.get(:as)

    env =
      with :require <- directive,
           {:__aliases__, _, [_ | _]} <- as,
           {:ok, entries} <- alias_entries(target, as, env) do
        Enum.reduce(entries, env, &add_alias(&2, &1))
      else
        _ -> env
      end

    {env, acc}
  end

  # Module attribute definition: `@name value`.
  defp walk({:@, meta, [{name, _, [value]}]}, env, acc) when is_atom(name) do
    env = at(env, meta)

    kind =
      cond do
        name == :compile -> :compile
        name in @typespec_attrs -> :typespec
        name == :behaviour -> :directive
        true -> env.kind
      end

    {_, acc} = walk(value, %{env | kind: kind}, acc)
    {%{env | attrs: Map.put(env.attrs, name, {value, env})}, acc}
  end

  # Module attribute read inside @compile, a call receiver or apply/3: walk
  # the value it was given, so `@mods [X]; @compile {:no_warn_undefined, @mods}`
  # reports X at the @compile line too.
  defp walk({:@, meta, [{name, _, ctx}]}, env, acc)
       when is_atom(name) and is_atom(ctx) do
    case Map.fetch(env.attrs, name) do
      {:ok, {value, def_env}} when env.kind in [:compile, :call, :apply] ->
        {_, acc} = walk(relocate(value, meta), %{def_env | kind: env.kind}, acc)
        {env, acc}

      _ ->
        {env, acc}
    end
  end

  defp walk({:apply, _, [mod, fun, args]}, env, acc) do
    {_, acc} = walk(mod, sub(env, :apply), acc)
    {_, acc} = walk([fun, args], env, acc)
    {env, acc}
  end

  # Remote call or capture: the receiver is a module reference. Kernel.apply/3
  # and :erlang.apply/3 are apply/3; Module.concat/1,2 and String.to_atom/1 &
  # co. over literals name a module too.
  defp walk({{:., _, [recv, fun]}, meta, args} = node, env, acc)
       when is_atom(fun) and is_list(args) do
    cond do
      remote?(recv, [:Kernel, :erlang], fun, [:apply]) and length(args) == 3 ->
        walk({:apply, meta, args}, env, acc)

      remote?(recv, [:Module], fun, [:concat, :safe_concat]) ->
        # Aliases here are namespace segments (`Module.concat([Raxol, Plugins,
        # name])`), not references; only a fully literal result names a module.
        {_, acc} =
          walk(
            Enum.reject(List.flatten(args), &match?({:__aliases__, _, _}, &1)),
            env,
            acc
          )

        case literal_concat(args, env) do
          {:ok, mod} -> {env, record(acc, mod, meta, :concat)}
          :error -> {env, acc}
        end

      remote?(recv, [:String], fun, [:to_atom, :to_existing_atom]) or
          remote?(recv, [:erlang], fun, [
            :binary_to_atom,
            :binary_to_existing_atom
          ]) ->
        {_, acc} = walk_children(node, env, acc)

        case args do
          ["Elixir." <> mod | _] -> {env, record(acc, mod, meta, :atom)}
          _ -> {env, acc}
        end

      true ->
        {_, acc} = walk(recv, sub(at(env, meta), :call), acc)
        {_, acc} = walk(args, at(env, meta), acc)
        {env, acc}
    end
  end

  defp walk({:__aliases__, meta, parts} = node, env, acc) when is_list(parts) do
    case expand(parts, env) do
      {:ok, full} -> {env, record(acc, join(full), meta, env.kind)}
      :error -> walk_children(node, env, acc)
    end
  end

  defp walk(atom, env, acc) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> mod -> {env, record(acc, mod, [line: env.line], :atom)}
      _ -> {env, acc}
    end
  end

  defp walk(node, env, acc), do: walk_children(node, env, acc)

  defp walk_children({form, meta, args}, env, acc) do
    env = at(env, meta)
    {_, acc} = if is_atom(form), do: {env, acc}, else: walk(form, env, acc)
    {_, acc} = if is_list(args), do: walk(args, env, acc), else: {env, acc}
    {env, acc}
  end

  defp walk_children({left, right}, env, acc) do
    {_, acc} = walk(left, env, acc)
    {_, acc} = walk(right, env, acc)
    {env, acc}
  end

  defp walk_children(list, env, acc) when is_list(list) do
    {_, acc} =
      Enum.reduce(list, {env, acc}, fn item, {_, acc} ->
        walk(item, env, acc)
      end)

    {env, acc}
  end

  defp walk_children(_literal, env, acc), do: {env, acc}

  defp sub(%{kind: kind} = env, _new) when kind in @sticky_kinds, do: env
  defp sub(env, new), do: %{env | kind: new}

  # Atoms carry no line of their own; they get the nearest enclosing one.
  defp at(env, meta) when is_list(meta),
    do: %{env | line: meta[:line] || env.line}

  defp at(env, _meta), do: env

  defp remote?({:__aliases__, _, [mod]}, mods, fun, funs),
    do: mod in mods and fun in funs

  defp remote?(mod, mods, fun, funs) when is_atom(mod),
    do: mod in mods and fun in funs

  defp remote?(_recv, _mods, _fun, _funs), do: false

  # Atoms carry no line; give a resolved attribute value the line of its use.
  defp relocate(ast, meta) do
    Macro.prewalk(ast, fn
      {form, m, args} when is_list(m) ->
        {form, Keyword.put(m, :line, meta[:line]), args}

      other ->
        other
    end)
  end

  defp record(acc, mod, meta, kind) do
    %{acc | refs: [{mod, meta[:line], kind} | acc.refs]}
  end

  ## Alias resolution

  defp expand([{:__MODULE__, _, ctx} | rest], %{module: mod})
       when is_atom(ctx) and mod != nil,
       do: {:ok, mod ++ rest}

  defp expand([:"Elixir" | rest], _env) when rest != [], do: {:ok, rest}

  defp expand([head | rest], env) when is_atom(head) do
    if Enum.all?(rest, &is_atom/1),
      do: {:ok, Map.get(env.aliases, head, [head]) ++ rest},
      else: :error
  end

  defp expand(_parts, _env), do: :error

  defp add_alias(env, nil), do: env

  defp add_alias(env, {short, full}),
    do: %{env | aliases: Map.put(env.aliases, short, full)}

  # Name of a defmodule/defprotocol: nested ones are prefixed with the parent
  # unless their first segment is an existing alias, and alias their first
  # segment in the enclosing scope, as Elixir does.
  defp expand_module_name({:__aliases__, _, [head | _] = parts}, env)
       when is_atom(head) do
    with {:ok, full} <- expand(parts, env) do
      cond do
        env.module == nil or Map.has_key?(env.aliases, head) or
            head == :"Elixir" ->
          {:ok, full, nil}

        true ->
          {:ok, env.module ++ parts, {head, env.module ++ [head]}}
      end
    end
  end

  defp expand_module_name({:__aliases__, _, _} = name, env) do
    with {:ok, full} <- expand(elem(name, 2), env), do: {:ok, full, nil}
  end

  defp expand_module_name(atom, _env) when is_atom(atom) do
    case Atom.to_string(atom) do
      "Elixir." <> mod ->
        {:ok, Enum.map(String.split(mod, "."), &String.to_atom/1), nil}

      _ ->
        :error
    end
  end

  defp expand_module_name(_, _env), do: :error

  defp alias_entries({{:., _, [base, :{}]}, _, children}, nil, env) do
    with {:__aliases__, _, base_parts} <- base,
         {:ok, base_full} <- expand(base_parts, env) do
      Enum.reduce_while(children, {:ok, []}, fn
        {:__aliases__, _, parts}, {:ok, acc} ->
          if Enum.all?(parts, &is_atom/1),
            do: {:cont, {:ok, [{List.last(parts), base_full ++ parts} | acc]}},
            else: {:halt, :error}

        _, _ ->
          {:halt, :error}
      end)
    else
      _ -> :error
    end
  end

  defp alias_entries({:__aliases__, _, parts}, as, env) do
    with {:ok, full} <- expand(parts, env) do
      case as do
        nil -> {:ok, [{List.last(full), full}]}
        {:__aliases__, _, [short]} -> {:ok, [{short, full}]}
        _ -> :error
      end
    end
  end

  defp alias_entries(_target, _as, _env), do: :error

  defp names_and_refs(ast, env, acc, meta) do
    Enum.reduce(List.wrap(ast), {[], acc}, fn
      {:__aliases__, _, parts}, {names, acc} ->
        case expand(parts, env) do
          {:ok, full} ->
            {names ++ [full], record(acc, join(full), meta, :value)}

          :error ->
            {names, acc}
        end

      _, {names, acc} ->
        {names, acc}
    end)
  end

  defp literal_concat([list], env) when is_list(list),
    do: literal_concat(list, env)

  defp literal_concat(args, env) do
    Enum.reduce_while(args, {:ok, []}, fn
      {:__aliases__, _, parts}, {:ok, acc} ->
        case expand(parts, env) do
          {:ok, full} -> {:cont, {:ok, acc ++ full}}
          :error -> {:halt, :error}
        end

      bin, {:ok, acc} when is_binary(bin) ->
        segments = bin |> String.trim_leading("Elixir.") |> String.split(".")
        {:cont, {:ok, acc ++ Enum.map(segments, &String.to_atom/1)}}

      atom, {:ok, acc} when is_atom(atom) and atom not in [nil, true, false] ->
        {:cont,
         {:ok,
          acc ++
            [
              atom
              |> Atom.to_string()
              |> String.trim_leading("Elixir.")
              |> String.to_atom()
            ]}}

      _, _ ->
        {:halt, :error}
    end)
    |> case do
      {:ok, [_ | _] = full} -> {:ok, join(full)}
      _ -> :error
    end
  end

  defp join(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

  ## Allowlist

  defp read_allowlist do
    case File.read(@allowlist) do
      {:ok, text} ->
        parse_allowlist(text, @allowlist)

      {:error, reason} ->
        fatal(["cannot read #{@allowlist}: #{:file.format_error(reason)}"])
    end
  end

  defp parse_allowlist(text, source) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _} ->
      String.trim(line) == "" or
        String.starts_with?(String.trim_leading(line), "#")
    end)
    |> Enum.map(fn {line, n} ->
      case String.split(line, "\t") do
        [file, mod, tree] ->
          {file, mod, tree}

        _ ->
          fatal([
            "#{source}:#{n}: expected `file<TAB>module<TAB>tree`, got #{inspect(line)}"
          ])
      end
    end)
    |> MapSet.new()
  end

  defp grown_since(base, allowed) do
    case System.cmd("git", ["show", "#{base}:#{@allowlist}"],
           stderr_to_stdout: true
         ) do
      {text, 0} ->
        allowed
        |> MapSet.difference(parse_allowlist(text, "#{base}:#{@allowlist}"))
        |> Enum.sort()

      {out, _} ->
        if out =~ "does not exist in" or out =~ "exists on disk, but not in" do
          IO.puts(
            "note: #{base} has no #{@allowlist}; nothing to compare it against"
          )

          []
        else
          fatal(["git show #{base}:#{@allowlist} failed:", String.trim(out)])
        end
    end
  end

  ## Reporting

  defp report_new([]), do: :ok

  defp report_new(new) do
    err(
      "ERROR: package references a module outside its declared dependencies:\n"
    )

    for {{file, mod, tree}, sites} <- new do
      line =
        sites
        |> Enum.map(&elem(&1, 0))
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end)

      kinds =
        sites
        |> Enum.map(&elem(&1, 1))
        |> Enum.uniq()
        |> Enum.sort()
        |> Enum.join(", ")

      where = if line, do: "#{file}:#{line}", else: file

      err(
        "  #{String.pad_trailing(where, 75)} #{String.pad_trailing(mod, 50)} owned by #{tree} (#{kinds})"
      )
    end

    err("""

    Used standalone, the package fails there: UndefinedFunctionError for a
    call, a missing process, struct or type for the rest.
    Move the module into the package that owns the concept, read the
    implementation from application config with an in-package default, or
    delete the reference. See docs/PACKAGES.md ("Boundary rule").\
    """)
  end

  defp report_stale([]), do: :ok

  defp report_stale(stale) do
    err("ERROR: allowlist entries no longer match any reference:\n")

    for {file, mod, tree} <- stale,
        do: err("  #{String.pad_trailing(file, 75)} #{mod}\t#{tree}")

    err("\nRemove them from #{@allowlist}.")
  end

  defp report_grown([], _base), do: :ok

  defp report_grown(grown, base) do
    err(
      "ERROR: #{@allowlist} only shrinks; these entries are not in #{base}:\n"
    )

    for {file, mod, tree} <- grown,
        do: err("  #{String.pad_trailing(file, 75)} #{mod}\t#{tree}")

    err("\nFix the reference instead of listing it.")
  end

  defp err(line), do: IO.puts(:stderr, line)

  defp fatal(lines) do
    Enum.each(lines, &err/1)
    exit({:shutdown, 2})
  end
end

PackageBoundaries.main(System.argv())
