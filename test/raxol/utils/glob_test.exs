defmodule Raxol.Utils.GlobTest do
  use ExUnit.Case, async: true

  alias Raxol.Utils.Glob

  @moduletag :tmp_dir

  test "a directory name is matched literally, not as glob syntax", %{
    tmp_dir: tmp
  } do
    for {dir, file} <- [
          {"notes [1]", "a.md"},
          {"bk{a,b}", "own.md"},
          {"bka", "x.md"},
          {"st*r?", "s.md"}
        ] do
      File.mkdir_p!(Path.join(tmp, dir))
      File.write!(Path.join([tmp, dir, file]), "")
    end

    assert Glob.under(Path.join(tmp, "notes [1]"), "*.md") == [
             Path.join([tmp, "notes [1]", "a.md"])
           ]

    assert Glob.under(Path.join(tmp, "bk{a,b}"), "*.md") == [
             Path.join([tmp, "bk{a,b}", "own.md"])
           ]

    assert Glob.under(Path.join(tmp, "st*r?"), "**/*.md") == [
             Path.join([tmp, "st*r?", "s.md"])
           ]
  end

  test "the pattern keeps its glob syntax and Path.wildcard's dotfile option",
       %{tmp_dir: tmp} do
    for file <- ["a.ex", "b.exs", ".hidden.ex"],
        do: File.write!(Path.join(tmp, file), "")

    assert Glob.under(tmp, "*.{ex,exs}")
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() ==
             ["a.ex", "b.exs"]

    assert Glob.under(tmp, "*.ex", match_dot: true)
           |> Enum.map(&Path.basename/1)
           |> Enum.sort() ==
             [".hidden.ex", "a.ex"]
  end
end
