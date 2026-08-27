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

    {errors, warnings} = Enum.split_with(findings, &(&1.severity == :error))

    report = fn
      [], _label ->
        :ok

      found, label ->
        IO.puts(:stderr, "\n#{length(found)} #{label}(s):")

        found
        |> Raxol.Docs.ProseLint.format_findings()
        |> Enum.each(&IO.puts(:stderr, &1))
    end

    report.(errors, "error")

    # Warnings are PRINTED and not fatal, matching `mix raxol.check_docs`, which
    # counts them toward failure only under `--warnings-as-errors`.
    #
    # Unreachable as things stand: the only warning-severity rule is
    # `:heading_case`, which is opt-in via `headings: true` and nothing here
    # enables it. Written anyway because the alternative is a silent `_warnings`
    # discard, and the day the hook does pass `--headings` that discard is a
    # hook withholding what CI is about to say -- the same hook-versus-CI split
    # this script exists to close on scope, one axis over.
    report.(warnings, "warning")

    System.halt(if errors == [], do: 0, else: 1)
end
