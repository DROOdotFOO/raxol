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
#      when marked `@doc false`.
#   2. BODY DRIFT -- for every function that exists on both sides (in any
#      file, so a move between modules is followed), whether its body still
#      says the same thing. Bodies are compared as normalized ASTs, which
#      makes the comparison blind to exactly the things a move changes and
#      nothing else:
#        * comments and whitespace (the parser drops them),
#        * line numbers and other AST metadata (stripped),
#        * module-qualifier prefixes (`App.notice(m, t)` and `notice(m, t)`
#          compare equal -- a moved body must call its former siblings
#          through the module it left).
#      Variable and function names are NOT normalized: renaming a variable
#      is a real edit and should show up.
#
# What it deliberately does not do: judge. A body that differs may be an
# intended fix; the point is that the PR body names it instead of claiming
# "no behaviour change" over the top of it.
#
# Usage:
#   elixir scripts/check_refactor_move.exs [base]     # default base: master
#   elixir scripts/check_refactor_move.exs master --strict
#
# Exit codes: 0 report produced; 1 with --strict and at least one body
# differs; 2 the git commands or the parse failed (never silently "clean").

defmodule RefactorMove do
  @default_base "master"

  def main(argv) do
    {base, strict?} = parse_args(argv)
    merge_base = merge_base!(base)
    files = changed_elixir_files!(merge_base)

    if files == [] do
      IO.puts("No .ex files changed against #{base} (#{short(merge_base)}).")
      halt(0)
    end

    before = collect(files, fn file -> file_at(merge_base, file) end)
    now = collect(files, &read_worktree/1)

    widenings = widenings(before, now)
    {identical, drifted, added, removed} = compare_bodies(before, now)

    report(base, merge_base, files, widenings, identical, drifted, added, removed)

    cond do
      strict? and drifted != [] -> halt(1)
      true -> halt(0)
    end
  end

  # -- argv ------------------------------------------------------------------

  defp parse_args(argv) do
    {flags, positional} = Enum.split_with(argv, &String.starts_with?(&1, "--"))

    unknown = flags -- ["--strict"]

    if unknown != [] do
      die("unknown option(s): #{Enum.join(unknown, ", ")}")
    end

    {List.first(positional) || @default_base, "--strict" in flags}
  end

  # -- git -------------------------------------------------------------------

  defp merge_base!(base) do
    case System.cmd("git", ["merge-base", base, "HEAD"], stderr_to_stdout: true) do
      {out, 0} ->
        String.trim(out)

      {out, status} ->
        die("git merge-base #{base} HEAD failed (#{status}): #{String.trim(out)}")
    end
  end

  # Renames are followed as a delete plus an add, which is what the
  # body comparison wants: it pairs by function, never by file.
  defp changed_elixir_files!(merge_base) do
    case System.cmd(
           "git",
           ["diff", "--name-only", "--diff-filter=ACMRD", merge_base <> "...HEAD"],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.filter(&String.ends_with?(&1, ".ex"))
        |> Enum.sort()

      {out, status} ->
        die("git diff failed (#{status}): #{String.trim(out)}")
    end
  end

  # A file that did not exist on the base side (or was deleted on this side)
  # is empty rather than an error: that is how a split's destination file and
  # a removed module look.
  defp file_at(rev, path) do
    case System.cmd("git", ["show", "#{rev}:#{path}"], stderr_to_stdout: true) do
      {contents, 0} -> contents
      {_out, _status} -> ""
    end
  end

  defp read_worktree(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
      {:error, reason} -> die("cannot read #{path}: #{:file.format_error(reason)}")
    end
  end

  # -- collection ------------------------------------------------------------

  # %{{name, arity} => %{visibility: :public | :private | :mixed,
  #                      files: [path], bodies: [normalized_ast]}}
  defp collect(files, source) do
    Enum.reduce(files, %{}, fn file, acc ->
      file
      |> source.()
      |> parse!(file)
      |> definitions()
      |> Enum.reduce(acc, fn {key, kind, body}, inner ->
        Map.update(
          inner,
          key,
          %{visibility: visibility(kind), files: [file], bodies: [body]},
          fn entry ->
            %{
              entry
              | visibility: merge_visibility(entry.visibility, visibility(kind)),
                files: Enum.uniq(entry.files ++ [file]),
                bodies: entry.bodies ++ [body]
            }
          end
        )
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

  defp visibility(:def), do: :public
  defp visibility(:defp), do: :private

  defp merge_visibility(same, same), do: same
  defp merge_visibility(_a, _b), do: :mixed

  # Every def/defp at any nesting depth, with its name/arity, kind, and
  # normalized body. `defdelegate`, `defmacro` and friends are out of scope:
  # a move PR that changes those is not what this script claims to check.
  defp definitions(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
          case signature(head) do
            nil -> {node, acc}
            key -> {node, [{key, kind, normalize(body)} | acc]}
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

  # Metadata out (line numbers move with every edit), module qualifiers out
  # (`Foo.bar(x)` == `bar(x)`), everything else kept.
  defp normalize(ast) do
    Macro.prewalk(ast, fn
      {{:., _dot_meta, [{:__aliases__, _alias_meta, _alias}, fun]}, _meta, args}
      when is_atom(fun) and is_list(args) ->
        {fun, [], args}

      {form, _meta, args} ->
        {form, [], args}

      other ->
        other
    end)
  end

  # -- comparison ------------------------------------------------------------

  defp widenings(before, now) do
    before
    |> Enum.filter(fn {key, entry} ->
      entry.visibility in [:private, :mixed] and
        match?(%{visibility: v} when v in [:public, :mixed], Map.get(now, key, %{}))
    end)
    |> Enum.map(fn {key, entry} ->
      {key, entry.files, Map.fetch!(now, key).files}
    end)
    |> Enum.sort()
  end

  defp compare_bodies(before, now) do
    keys = Map.keys(before) ++ Map.keys(now)

    Enum.reduce(Enum.sort(Enum.uniq(keys)), {[], [], [], []}, fn key,
                                                                {same, drift, added, removed} ->
      case {Map.get(before, key), Map.get(now, key)} do
        {nil, %{} = new} ->
          {same, drift, [{key, new.files} | added], removed}

        {%{} = old, nil} ->
          {same, drift, added, [{key, old.files} | removed]}

        {%{} = old, %{} = new} ->
          if Enum.sort(old.bodies) == Enum.sort(new.bodies) do
            {[{key, old.files, new.files} | same], drift, added, removed}
          else
            {same, [{key, old.files, new.files, clause_delta(old, new)} | drift], added, removed}
          end
      end
    end)
    |> then(fn {same, drift, added, removed} ->
      {Enum.reverse(same), Enum.reverse(drift), Enum.reverse(added), Enum.reverse(removed)}
    end)
  end

  # Clause count is the cheapest useful description of HOW a body drifted:
  # "5 clauses -> 4" reads differently from "same clause count, body edited".
  defp clause_delta(old, new) do
    {length(old.bodies), length(new.bodies)}
  end

  # -- report ----------------------------------------------------------------

  defp report(base, merge_base, files, widenings, identical, drifted, added, removed) do
    IO.puts("refactor-move report: HEAD vs #{base} (#{short(merge_base)})")
    IO.puts("#{length(files)} .ex file(s) changed\n")

    IO.puts("defp -> def widenings: #{length(widenings)}")

    Enum.each(widenings, fn {{name, arity}, from, to} ->
      IO.puts("  #{name}/#{arity}  #{Enum.join(from, ", ")} -> #{Enum.join(to, ", ")}")
    end)

    IO.puts("\nfunctions present on both sides: #{length(identical) + length(drifted)}")
    IO.puts("  bodies identical (comments/whitespace/qualifiers normalized): #{length(identical)}")
    IO.puts("  bodies DIFFER: #{length(drifted)}")

    Enum.each(drifted, fn {{name, arity}, from, to, {old_clauses, new_clauses}} ->
      IO.puts(
        "  #{name}/#{arity}  #{Enum.join(from, ", ")} -> #{Enum.join(to, ", ")}" <>
          "  (#{old_clauses} clause(s) -> #{new_clauses})"
      )
    end)

    IO.puts("\nfunctions only after: #{length(added)}")
    Enum.each(added, &print_one_sided/1)

    IO.puts("functions only before: #{length(removed)}")
    Enum.each(removed, &print_one_sided/1)
  end

  defp print_one_sided({{name, arity}, files}) do
    IO.puts("  #{name}/#{arity}  #{Enum.join(files, ", ")}")
  end

  defp short(sha), do: String.slice(sha, 0, 9)

  # -- exits -----------------------------------------------------------------

  defp die(message) do
    IO.puts(:stderr, "check_refactor_move: #{message}")
    halt(2)
  end

  defp halt(code), do: System.halt(code)
end

RefactorMove.main(System.argv())
