defmodule Raxol.Agent.Glob do
  @moduledoc """
  `Path.wildcard/2` under a directory whose name is data, not pattern.

  `Path.wildcard(Path.join(dir, "*.md"))` hands `dir` to the glob compiler
  too, so a directory named `notes [1]` matches nothing, one named `bk{a,b}`
  matches `bka/` and `bkb/` instead, and on Windows every `\\` separator is
  read as an escape. `under/3` escapes `dir` first, so only `pattern` is glob
  syntax. The root app carries its own copy (`Raxol.Utils.Glob`); the
  packages do not depend on each other.
  """

  @doc """
  Files matching `pattern` under the literal directory `dir`.

  Same options and result spelling as `Path.wildcard/2`.
  """
  @spec under(Path.t(), String.t(), keyword()) :: [String.t()]
  def under(dir, pattern, opts \\ []) do
    dir |> escape() |> Path.join(pattern) |> Path.wildcard(opts)
  end

  @doc """
  `path` with every glob metacharacter escaped, for use as the literal prefix
  of a pattern. Windows separators become `/` first: there a `\\` is never
  part of a name, and escaped it would stop being a separator.
  """
  @spec escape(Path.t()) :: String.t()
  def escape(path) do
    path
    |> to_string()
    |> normalize_separators(:os.type())
    |> String.replace(~r/[\\\[\]{}*?]/, "\\\\\\0")
  end

  defp normalize_separators(path, {:win32, _}), do: String.replace(path, "\\", "/")
  defp normalize_separators(path, _unix), do: path
end
