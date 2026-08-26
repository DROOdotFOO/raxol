# Prose-lint Markdown files without booting Mix.
#
#     elixir scripts/prose_lint.exs FILE...
#
# The pre-commit hook runs this instead of `mix raxol.check_docs`. The rules are
# the same module either way; what differs is that nothing here loads the
# project, so the check survives states where Mix refuses to start at all:
#
#   * deps on disk not matching the branch's mix.lock, which is routine when
#     branches carry different locks and `deps/` is shared across a checkout;
#   * a `_build` compiled by a different Elixir than the one on PATH;
#   * a root mix.lock that no longer re-resolves.
#
# None of those say anything about the prose in a commit, so none of them should
# be able to block one. `Raxol.Docs.ProseLint` is stdlib-only, so requiring the
# single source file is the whole setup.
#
# Exit codes: 0 clean, 1 findings, 2 could not run.

lint_source =
  Path.join([__DIR__, "..", "lib", "raxol", "docs", "prose_lint.ex"])

unless File.exists?(lint_source) do
  IO.puts(
    :stderr,
    "prose_lint: cannot find #{Path.relative_to_cwd(lint_source)}"
  )

  System.halt(2)
end

Code.require_file(lint_source)

case System.argv() do
  [] ->
    IO.puts(:stderr, "usage: elixir scripts/prose_lint.exs FILE...")
    System.halt(2)

  paths ->
    # `check_file/2` treats an unreadable path as clean, which is right for a
    # repo-wide sweep over a stale file list and wrong for named arguments: a
    # typo would exit 0 and read as a pass. Named files must exist.
    case Enum.reject(paths, &File.regular?(Path.relative_to_cwd(&1))) do
      [] ->
        :ok

      missing ->
        IO.puts(:stderr, "prose_lint: cannot read: #{Enum.join(missing, ", ")}")
        System.halt(2)
    end

    findings =
      paths
      |> Enum.map(&Path.relative_to_cwd/1)
      |> Raxol.Docs.ProseLint.lint_files()

    {errors, _warnings} = Enum.split_with(findings, &(&1.severity == :error))

    if errors == [] do
      System.halt(0)
    else
      IO.puts(:stderr, "\n#{length(errors)} error(s):")

      errors
      |> Raxol.Docs.ProseLint.format_findings()
      |> Enum.each(&IO.puts(:stderr, &1))

      System.halt(1)
    end
end
