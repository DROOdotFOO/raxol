#!/usr/bin/env elixir
#
# Mechanical proof for move/split PRs.
#
# Every false claim in the #1008-#1011 PR bodies was confident prose: "no
# behaviour change", "twelve helpers became public" (it was thirty), "132/80
# now reach StandardHandler" (that was the bug). All three were checkable
# from the diff, and none had been checked. This script does the checking, so
# a refactor PR pastes output instead of an adjective.
#
# It answers exactly two questions about `git diff <base>...HEAD`:
#
#   1. WIDENINGS -- which functions were `defp` before and `def` after. That
#      is the boundary cost of a split: each one is new public surface, even
#      when marked `@doc false`. Two shapes count, and only these two:
#      widened in place (private then public in the SAME file), and widened
#      on the way out (private in a file it no longer appears in, public
#      somewhere else). An unrelated new `def helper/1` alongside an
#      untouched `defp helper/1` elsewhere is NOT a widening, and reporting
#      it as one -- which keying on name/arity alone does -- would put a
#      wrong number in a PR body.
#   2. CLAUSE DRIFT -- for every function that exists on both sides (in any
#      file, so a move between modules is followed), whether its clauses
#      still say the same thing. A clause is compared as the PAIR of its
#      head and its body, in source order, because in Elixir the head
#      (patterns and `when` guards) and the ORDER of clauses are as
#      load-bearing as the body: deleting `when is_admin(u)`, swapping two
#      patterns, or hoisting a catch-all above a restrictive clause are all
#      behaviour changes, and a tool that called them "identical" would be
#      worse than no tool.
#
#      The comparison is blind to exactly three things, all of which a move
#      changes and none of which is behaviour:
#        * comments and whitespace (the parser drops them),
#        * line numbers and other AST metadata (stripped),
#        * a qualifier naming one of the modules DEFINED IN THE CHANGED SET
#          (`App.notice(m, t)` and `notice(m, t)` compare equal, because a
#          moved body must call its former siblings through the module it
#          left). Every other qualifier is compared as written, so
#          `Map.get(m, k)` and `Keyword.get(m, k)` DIFFER, and so does a
#          call redirected to a module outside the diff.
#      Variable and function names are NOT normalized: renaming a variable
#      is a real edit and should show up.
#
# What it deliberately does not do: judge. A clause that differs may be an
# intended fix; the point is that the PR body names it instead of claiming
# "no behaviour change" over the top of it.
#
# Known limitations, stated rather than hidden:
#   * Functions are keyed by name/arity across the whole changed set, so
#     several files defining the same name/arity (`handle_mode_change/3` in
#     four handlers) are pooled into one entry. The comparison stays sound
#     (it compares the ordered clause sequence, file by file), and the
#     report prints the per-file clause counts rather than a pooled sum.
#   * `defmacro`, `defguard` and `defdelegate` are out of scope: a move PR
#     that changes those is not what this script claims to check.
#   * Module-level directives (`alias`, `import`, `use`) are not compared,
#     so a moved file that re-points an existing alias to another module is
#     not detected. Qualifiers OUTSIDE the changed set are compared as
#     written, which is what makes this a gap rather than a hole.
#
# Usage:
#   elixir scripts/check_refactor_move.exs [base]     # default base: master
#   elixir scripts/check_refactor_move.exs master --strict
#   elixir scripts/check_refactor_move.exs --help
#
# Exit codes:
#   0  report produced
#   1  --strict and at least one clause differs
#   2  a git command, a read, or a parse failed -- never a silent "clean"
#
# Exit 2 is deliberate and load-bearing: a base side that cannot be read
# looks exactly like a base side with nothing in it, and the second reads as
# "no widenings, no drift". Every read failure is an error here, and only a
# path that git reports as genuinely absent at that rev is treated as empty.

defmodule RefactorMove do
  @default_base "master"

  def main(argv) do
    case parse_args(argv) do
      :help ->
        print_usage()
        finish(0)

      {base, strict?} ->
        run(base, strict?)
    end
  end

  defp run(base, strict?) do
    merge_base = merge_base!(base)
    {new_files, base_files} = changed_elixir_files!(merge_base)

    if new_files == [] and base_files == [] do
      IO.puts("No .ex files changed against #{base} (#{short(merge_base)}).")
      finish(0)
    end

    owned =
      module_names(base_files, &file_at!(merge_base, &1)) ++
        module_names(new_files, &read_worktree!/1)

    before = collect(base_files, &file_at!(merge_base, &1), owned)
    now = collect(new_files, &read_worktree!/1, owned)

    widenings = widenings(before, now)
    {identical, drifted, added, removed} = compare(before, now)

    report(
      base,
      merge_base,
      new_files,
      base_files,
      widenings,
      identical,
      drifted,
      added,
      removed
    )

    if strict? and drifted != [], do: finish(1), else: finish(0)
  end

  # -- argv ------------------------------------------------------------------

  defp parse_args(argv) do
    cond do
      "--help" in argv or "-h" in argv ->
        :help

      true ->
        {flags, positional} =
          Enum.split_with(argv, &String.starts_with?(&1, "-"))

        unknown = flags -- ["--strict"]

        if unknown != [] do
          die(
            "unknown option(s): #{Enum.join(unknown, ", ")}\n\n" <> usage_text()
          )
        end

        if length(positional) > 1 do
          die(
            "expected at most one base ref, got: #{Enum.join(positional, ", ")}"
          )
        end

        {List.first(positional) || @default_base, "--strict" in flags}
    end
  end

  defp usage_text do
    """
    Usage:
      elixir scripts/check_refactor_move.exs [base]     # default base: #{@default_base}
      elixir scripts/check_refactor_move.exs master --strict
      elixir scripts/check_refactor_move.exs --help

    Exit codes:
      0  report produced
      1  --strict and at least one clause differs
      2  a git command, a read, or a parse failed
    """
  end

  defp print_usage, do: IO.puts(usage_text())

  # -- git -------------------------------------------------------------------

  defp merge_base!(base) do
    case git(["merge-base", base, "HEAD"]) do
      {:ok, out} ->
        case String.split(String.trim(out), "\n") do
          [sha] ->
            sha

          many ->
            die("git merge-base #{base} HEAD is ambiguous: #{inspect(many)}")
        end

      {:error, status, out} ->
        die("git merge-base #{base} HEAD failed (#{status}): #{out}")
    end
  end

  # `-z --name-status -M` for three reasons the plain `--name-only` form got
  # wrong: NUL-delimited records need no unquoting (`core.quotePath` would
  # otherwise hand back `"lib/caf\303\251.ex"`, which no `.ex` suffix test
  # matches, silently narrowing the change set); the status letter tells a
  # deletion from an addition; and `R` records carry BOTH paths, so a renamed
  # module is read from its OLD path on the base side instead of coming back
  # empty -- which is the single most important case this script exists for.
  defp changed_elixir_files!(merge_base) do
    case git([
           "diff",
           "-z",
           "--name-status",
           "-M",
           "--find-copies",
           merge_base <> "...HEAD"
         ]) do
      {:ok, out} ->
        {new_files, base_files} =
          parse_name_status(String.split(out, <<0>>, trim: true))

        {elixir_only(new_files), elixir_only(base_files)}

      {:error, status, out} ->
        die("git diff failed (#{status}): #{out}")
    end
  end

  # Records are `STATUS\0path\0` except for R/C, which are
  # `STATUS\0old\0new\0`.
  defp parse_name_status(fields), do: parse_name_status(fields, [], [])

  defp parse_name_status([], new_acc, base_acc),
    do: {Enum.sort(Enum.uniq(new_acc)), Enum.sort(Enum.uniq(base_acc))}

  defp parse_name_status([status, old, new | rest], new_acc, base_acc)
       when binary_part(status, 0, 1) in ["R", "C"] do
    parse_name_status(rest, [new | new_acc], [old | base_acc])
  end

  defp parse_name_status(["D", path | rest], new_acc, base_acc) do
    parse_name_status(rest, new_acc, [path | base_acc])
  end

  defp parse_name_status(["A", path | rest], new_acc, base_acc) do
    parse_name_status(rest, [path | new_acc], base_acc)
  end

  defp parse_name_status([_status, path | rest], new_acc, base_acc) do
    parse_name_status(rest, [path | new_acc], [path | base_acc])
  end

  defp parse_name_status([odd], _new_acc, _base_acc) do
    die("git diff -z produced a trailing field with no path: #{inspect(odd)}")
  end

  defp elixir_only(paths), do: Enum.filter(paths, &String.ends_with?(&1, ".ex"))

  # A path genuinely absent at `rev` reads as empty; anything else -- a
  # corrupt object, a shallow clone that lacks the blob, a permissions error
  # -- is an error. `git cat-file -e` is the existence question asked
  # separately from the read, so the two answers cannot be confused.
  defp file_at!(rev, path) do
    case git(["cat-file", "-e", "#{rev}:#{path}"]) do
      {:ok, _} ->
        case git(["show", "#{rev}:#{path}"]) do
          {:ok, contents} ->
            contents

          {:error, status, out} ->
            die("git show #{rev}:#{path} failed (#{status}): #{out}")
        end

      {:error, _status, _out} ->
        ""
    end
  end

  defp read_worktree!(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents

      {:error, :enoent} ->
        ""

      {:error, reason} ->
        die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, status} -> {:error, status, String.trim(out)}
    end
  end

  # -- collection ------------------------------------------------------------

  # Every module defined on either side of the diff. These are the only
  # qualifiers `normalize/2` erases, so a call that moves between them
  # compares equal while `Map.get` vs `Keyword.get` does not.
  defp module_names(files, source) do
    Enum.flat_map(files, fn file ->
      file
      |> source.()
      |> parse!(file)
      |> collect_modules()
    end)
  end

  defp collect_modules(ast) do
    {_ast, modules} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [{:__aliases__, _am, parts} | _rest]} = node, acc ->
          {node, [parts | acc]}

        node, acc ->
          {node, acc}
      end)

    modules
  end

  # %{{name, arity} => [%{file: path, kind: :def | :defp, head: ast, body: ast}]}
  # in file order, then definition order within a file: the sequence a clause
  # reordering changes.
  defp collect(files, source, owned) do
    Enum.reduce(files, %{}, fn file, acc ->
      file
      |> source.()
      |> parse!(file)
      |> definitions(file, owned)
      |> Enum.reduce(acc, fn {key, clause}, inner ->
        Map.update(inner, key, [clause], &(&1 ++ [clause]))
      end)
    end)
  end

  defp parse!("", _file), do: {:__block__, [], []}

  defp parse!(contents, file) do
    case Code.string_to_quoted(contents) do
      {:ok, ast} -> ast
      {:error, reason} -> die("cannot parse #{file}: #{inspect(reason)}")
    end
  end

  defp definitions(ast, file, owned) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          case signature(head) do
            nil ->
              {node, acc}

            key ->
              clause = %{
                file: file,
                kind: kind,
                head: normalize(head, owned),
                body: normalize(body, owned)
              }

              {node, [{key, clause} | acc]}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(defs)
  end

  defp signature({:when, _meta, [head | _guards]}), do: signature(head)
  defp signature({name, _meta, nil}) when is_atom(name), do: {name, 0}

  defp signature({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp signature(_other), do: nil

  # Metadata out (line numbers move with every edit); a qualifier naming a
  # module defined in the changed set out (a moved body calls its former
  # siblings through the module it left); everything else -- including which
  # OTHER module a call targets -- kept as written.
  defp normalize(ast, owned) do
    Macro.prewalk(ast, fn
      {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, fun]}, _meta, args}
      when is_atom(fun) and is_list(args) ->
        if owns?(owned, parts),
          do: {fun, [], args},
          else: {{:., [], [{:__aliases__, [], parts}, fun]}, [], args}

      {form, _meta, args} ->
        {form, [], args}

      other ->
        other
    end)
  end

  # `App.notice/2` inside `Raxol.Agent.Code.App` is written `App.notice(...)`
  # after an alias, so the alias parts are a SUFFIX of the defining module's
  # parts. Match on the suffix rather than on equality, and only for modules
  # the diff actually defines.
  defp owns?(owned, parts) do
    Enum.any?(owned, fn module_parts ->
      module_parts == parts or List.last(module_parts) == List.last(parts)
    end)
  end

  # -- comparison ------------------------------------------------------------

  # Two shapes, so that pooling by name/arity cannot invent a widening (see
  # the header): widened in place, or widened on the way out of a file it no
  # longer appears in.
  defp widenings(before, now) do
    before
    |> Enum.flat_map(fn {key, old_clauses} ->
      new_clauses = Map.get(now, key, [])
      private_files = files_with(old_clauses, :defp)
      new_public_files = files_with(new_clauses, :def)
      new_private_files = files_with(new_clauses, :defp)
      new_files = Enum.map(new_clauses, & &1.file) |> Enum.uniq()

      in_place = MapSet.intersection(private_files, new_public_files)

      moved_out =
        private_files
        |> MapSet.difference(MapSet.new(new_files))
        |> then(fn gone ->
          if MapSet.size(gone) > 0 and MapSet.size(new_public_files) > 0,
            do: gone,
            else: MapSet.new()
        end)

      cond do
        MapSet.size(in_place) > 0 ->
          [
            {key, Enum.sort(MapSet.to_list(in_place)),
             Enum.sort(MapSet.to_list(new_public_files))}
          ]

        MapSet.size(moved_out) > 0 and MapSet.size(new_private_files) == 0 ->
          [
            {key, Enum.sort(MapSet.to_list(moved_out)),
             Enum.sort(MapSet.to_list(new_public_files))}
          ]

        true ->
          []
      end
    end)
    |> Enum.sort()
  end

  defp files_with(clauses, kind) do
    clauses
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(& &1.file)
    |> MapSet.new()
  end

  defp compare(before, now) do
    keys = (Map.keys(before) ++ Map.keys(now)) |> Enum.uniq() |> Enum.sort()

    {same, drift, added, removed} =
      Enum.reduce(keys, {[], [], [], []}, fn key,
                                             {same, drift, added, removed} ->
        case {Map.get(before, key), Map.get(now, key)} do
          {nil, new} when is_list(new) ->
            {same, drift, [{key, counts(new)} | added], removed}

          {old, nil} when is_list(old) ->
            {same, drift, added, [{key, counts(old)} | removed]}

          {old, new} ->
            if clause_sequence(old) == clause_sequence(new) do
              {[{key, counts(old), counts(new)} | same], drift, added, removed}
            else
              {same,
               [{key, counts(old), counts(new), diff_note(old, new)} | drift],
               added, removed}
            end
        end
      end)

    {Enum.reverse(same), Enum.reverse(drift), Enum.reverse(added),
     Enum.reverse(removed)}
  end

  # Head AND body, in order. Order matters: hoisting a catch-all above a
  # restrictive clause changes dispatch and must never read as identical.
  defp clause_sequence(clauses), do: Enum.map(clauses, &{&1.head, &1.body})

  # Per-file clause counts, not a pooled sum: "2 clauses -> 20" on a pooled
  # entry read as one 2-clause function when it was one clause in each of two
  # files.
  defp counts(clauses) do
    clauses
    |> Enum.group_by(& &1.file)
    |> Enum.map(fn {file, cs} -> {file, length(cs)} end)
    |> Enum.sort()
  end

  # The cheapest honest description of HOW the sequence drifted, so the
  # reader knows which part of the clause to look at in the diff.
  defp diff_note(old, new) do
    heads_differ? = Enum.map(old, & &1.head) != Enum.map(new, & &1.head)
    bodies_differ? = Enum.map(old, & &1.body) != Enum.map(new, & &1.body)

    cond do
      length(old) != length(new) ->
        "clause count #{length(old)} -> #{length(new)}"

      # Same clauses, different order: dispatch changed even though every
      # clause is byte-identical. Checked first, because a reorder shows up
      # as both heads and bodies "differing" position by position.
      MapSet.new(clause_sequence(old)) == MapSet.new(clause_sequence(new)) ->
        "clauses reordered"

      heads_differ? and bodies_differ? ->
        "heads and bodies differ"

      heads_differ? ->
        "heads differ (patterns or guards)"

      true ->
        "bodies differ"
    end
  end

  # -- report ----------------------------------------------------------------

  defp report(
         base,
         merge_base,
         new_files,
         base_files,
         widenings,
         identical,
         drifted,
         added,
         removed
       ) do
    IO.puts("refactor-move report: HEAD vs #{base} (#{short(merge_base)})")

    IO.puts(
      "#{length(new_files)} .ex file(s) on this side, " <>
        "#{length(base_files)} on the base side (renames read from both)\n"
    )

    IO.puts("defp -> def widenings: #{length(widenings)}")

    Enum.each(widenings, fn {{name, arity}, from, to} ->
      IO.puts(
        "  #{name}/#{arity}  #{Enum.join(from, ", ")} -> #{Enum.join(to, ", ")}"
      )
    end)

    IO.puts(
      "\nfunctions present on both sides: #{length(identical) + length(drifted)}"
    )

    IO.puts(
      "  clause sequences identical (comments/whitespace/own-module qualifiers normalized): " <>
        "#{length(identical)}"
    )

    IO.puts("  clause sequences DIFFER: #{length(drifted)}")

    Enum.each(drifted, fn {{name, arity}, old_counts, new_counts, note} ->
      IO.puts(
        "  #{name}/#{arity}  #{render_counts(old_counts)} -> #{render_counts(new_counts)}  (#{note})"
      )
    end)

    IO.puts("\nfunctions only after: #{length(added)}")
    Enum.each(added, &print_one_sided/1)

    IO.puts("functions only before: #{length(removed)}")
    Enum.each(removed, &print_one_sided/1)
  end

  defp print_one_sided({{name, arity}, counts}) do
    IO.puts("  #{name}/#{arity}  #{render_counts(counts)}")
  end

  defp render_counts(counts) do
    Enum.map_join(counts, ", ", fn {file, count} -> "#{file} (#{count})" end)
  end

  defp short(sha), do: String.slice(sha, 0, 9)

  # -- exits -----------------------------------------------------------------

  defp die(message) do
    IO.puts(:stderr, "check_refactor_move: #{message}")
    finish(2)
  end

  # `System.stop/1` rather than `System.halt/1`: halt tears the VM down
  # without flushing the group leader, which for a tool whose output is meant
  # to be pasted into a PR body (`> report.txt`) is the worst failure mode.
  defp finish(0), do: :ok

  defp finish(code) do
    System.stop(code)
    Process.sleep(:infinity)
  end
end

RefactorMove.main(System.argv())
