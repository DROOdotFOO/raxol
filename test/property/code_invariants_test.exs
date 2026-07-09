defmodule Raxol.Property.CodeInvariantsTest do
  @moduledoc """
  Source-level invariants enforced by grep. Each `describe` block guards a
  past fix from regressing -- if someone reintroduces the old pattern, the
  test fails with a pointer to the original commit.

  This file is the home for source guards that don't fit any individual
  module's test file. Add new entries when fixing a class of bug that's
  prone to silent reintroduction.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  defp source_files(globs) when is_list(globs) do
    globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@repo_root, &1)))
    |> Enum.reject(&String.contains?(&1, "_build/"))
    |> Enum.reject(&String.contains?(&1, "deps/"))
    |> Enum.uniq()
  end

  describe "no raw ANSI in View DSL components (regression for 506c1b9c)" do
    # Components must use the View DSL's style attributes (`fg:`, `bg:`,
    # `style: [:bold]`, ...) instead of embedding ANSI escape codes directly
    # in strings. Raw ANSI bypasses the renderer's color resolution, breaks
    # LiveView/MCP backends, and prevents theming.

    @view_dsl_globs [
      "lib/raxol/ui/components/**/*.ex"
    ]

    # Patterns that indicate a raw ANSI escape sequence inside an Elixir string.
    @ansi_patterns [
      ~r/"\\e\[/,
      ~r/"\\x1b\[/,
      ~r/"\\033\[/
    ]

    test "no escape-prefixed strings in components/" do
      files = source_files(@view_dsl_globs)
      assert files != [], "expected to find component source files"

      offenders =
        for file <- files,
            content = File.read!(file),
            pattern <- @ansi_patterns,
            String.match?(content, pattern) do
          Path.relative_to(file, @repo_root)
        end
        |> Enum.uniq()

      assert offenders == [],
             "View DSL components must not embed raw ANSI escape codes. " <>
               "Use style attrs instead. Offenders:\n  " <>
               Enum.join(offenders, "\n  ") <>
               "\n(Original fix: 506c1b9c -- remove raw ANSI from focus_ring, hint, select.)"
    end
  end

  describe "fprof access goes through apply/3 (regression for f435e5e1)" do
    # `:fprof` lives in OTP's `:tools` application, which isn't loaded at
    # compile time. Direct `:fprof.<function>(...)` calls produce
    # "undefined module" warnings (failing CI under `--warnings-as-errors`).
    # Using `apply(:fprof, :fun, args)` defers resolution to runtime where
    # `:tools` is available.

    @profiler_globs [
      "lib/raxol/performance/**/*.ex",
      "lib/raxol/dev/**/*.ex",
      "lib/mix/tasks/**/*.ex"
    ]

    test "no direct :fprof. calls in profilers" do
      files = source_files(@profiler_globs)

      offenders =
        for file <- files,
            content = File.read!(file),
            String.match?(content, ~r/(?<!apply\()\s*:fprof\.[a-z_]+\(/) do
          Path.relative_to(file, @repo_root)
        end
        |> Enum.uniq()

      assert offenders == [],
             "Use apply(:fprof, :fun, args) instead of direct :fprof.fun(args) " <>
               "calls -- :fprof is not loaded at compile time. Offenders:\n  " <>
               Enum.join(offenders, "\n  ") <>
               "\n(Original fix: f435e5e1 -- eliminate fprof compile warnings via apply/3.)"
    end
  end
end
