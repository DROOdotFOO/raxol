# T0 — D-PA resolver CLI (thin wrapper around lib/verdict_resolver_core.exs).
#
# Implements 01-t0-matrix.md §7.2 (D-PA) + §7.4 (GO gate) over the matrix in
# t0-verdict.json. All decision logic lives in the pure module
# `T0.VerdictResolver` (lib/verdict_resolver_core.exs) so the discrimination
# fixture suite (test/resolver_test.exs) pins it; this file is only argv +
# file IO + JSON, made TOTAL: any unreadable/malformed input exits non-zero
# with "cannot resolve: <reason>" instead of a stacktrace.
#
# Usage (runs under plain `elixir` or `mix run` -- no dependency on the
# host Mix project):
#   elixir scripts/harness/t0/verdict_resolver.exs [path/to/t0-verdict.json]
# Default path: scripts/harness/t0/t0-verdict.json (this file's own dir).
#
# Exit codes: 0 = resolved (a dpa of "pending" is a valid, honest answer);
# 1 = input unreadable/malformed; 2 = usage error.

Code.require_file("lib/verdict_resolver_core.exs", __DIR__)

unless Code.ensure_loaded?(Jason) do
  # Bare `elixir verdict_resolver.exs` invocation (no host Mix project) --
  # `mix run` invocations already have Jason from the app's own deps and
  # must NOT call Mix.install/2 (raises inside an existing Mix project).
  Mix.install([{:jason, "~> 1.4"}])
end

defmodule T0.VerdictResolver.CLI do
  def main(argv, default_dir) do
    path =
      case argv do
        [] -> Path.join(default_dir, "t0-verdict.json")
        [p] -> p
        _ -> die(2, "usage: verdict_resolver.exs [path/to/t0-verdict.json]")
      end

    with {:read, {:ok, bin}} <- {:read, File.read(path)},
         {:decode, {:ok, decoded}} <- {:decode, Jason.decode(bin)},
         {:matrix, %{"matrix" => matrix}} when is_list(matrix) <-
           {:matrix, decoded} do
      matrix
      |> T0.VerdictResolver.resolve()
      |> Jason.encode!(pretty: true)
      |> IO.puts()
    else
      {:read, {:error, reason}} ->
        die(
          1,
          "cannot resolve: cannot read #{path}: #{:file.format_error(reason)}"
        )

      {:decode, {:error, err}} ->
        die(
          1,
          "cannot resolve: invalid JSON in #{path}: #{Exception.message(err)}"
        )

      {:matrix, _} ->
        die(1, "cannot resolve: #{path} has no list-valued \"matrix\" key")
    end
  end

  defp die(code, msg) do
    IO.puts(:stderr, msg)
    System.halt(code)
  end
end

T0.VerdictResolver.CLI.main(System.argv(), __DIR__)
