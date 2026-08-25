defmodule Raxol.FormatterDelegationTest do
  @moduledoc """
  The root formatter must resolve every package's files through that package's
  own `.formatter.exs`.

  Without that, a root-cwd `mix format packages/...` -- an editor save in a
  monorepo workspace -- rewraps those files at the root's 80 columns, reverting
  the 98-column shape the package's own gate enforces, and the two gates become
  mutually unsatisfiable.
  """

  use ExUnit.Case, async: true

  # 94 columns: legal at the package default of 98, split by the root's 80.
  @wide_line "{:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, message_hash::binary>>)}\n"

  test "the root formatter still holds root files to 80 columns" do
    {format, _opts} = Mix.Tasks.Format.formatter_for_file("lib/raxol.ex")

    refute format.(@wide_line) == @wide_line
  end

  # Asked of the formatter rather than of the config's shape. The delegation list
  # is a glob now, so string-matching a package name against it would pass while
  # proving nothing about what `mix format` actually does to that package's
  # files -- which is the whole property.
  test "every package resolves through its own formatter, not the root's" do
    for package <- packages() do
      file = sample_file(package)
      {format, _opts} = Mix.Tasks.Format.formatter_for_file(file)

      assert format.(@wide_line) == @wide_line,
             "#{package} resolves through the root formatter (80 columns), so a " <>
               "root-cwd `mix format` would rewrap what its own gate blessed"
    end
  end

  defp packages do
    "packages/*/.formatter.exs"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
  end

  # Any real source file under the package will do: the question is which
  # formatter config `mix format` picks for that path, not what the file holds.
  defp sample_file(package) do
    "packages/#{package}/lib/**/*.ex"
    |> Path.wildcard()
    |> List.first()
    |> case do
      nil -> flunk("#{package} has no lib/**/*.ex to probe delegation with")
      file -> file
    end
  end
end
