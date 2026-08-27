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

  # A package is defined by its mix.exs, NOT by having a .formatter.exs -- which
  # is the point. Enumerating by `.formatter.exs` would make a package that is
  # missing one invisible to the very test that exists to catch it, and the root
  # glob would quietly format it at 80 columns. CI's `Check package formatting`
  # step makes the same assertion; this is the cheaper of the two signals.
  test "every package carries its own .formatter.exs" do
    for package <- packages() do
      assert File.exists?("packages/#{package}/.formatter.exs"),
             "#{package} has no .formatter.exs, so the root glob formats it at " <>
               "80 columns while its own CI gate expects 98"
    end
  end

  # Asked of the formatter rather than of the config's shape. The delegation list
  # is a glob now, so string-matching a package name against it would pass while
  # proving nothing about what `mix format` actually does to that package's
  # files -- which is the whole property.
  test "every package resolves through its own formatter, not the root's" do
    for package <- packages() do
      {format, _opts} = Mix.Tasks.Format.formatter_for_file(probe_path(package))

      assert format.(@wide_line) == @wide_line,
             "#{package} resolves through the root formatter (80 columns), so a " <>
               "root-cwd `mix format` would rewrap what its own gate blessed"
    end
  end

  defp packages do
    "packages/*/mix.exs"
    |> Path.wildcard()
    |> Enum.map(&(&1 |> Path.dirname() |> Path.basename()))
    |> tap(&assert &1 != [], "no packages found; is this running from the repo root?")
  end

  # A path that need not EXIST. `formatter_for_file/1` picks a config by walking
  # up from the path, so it answers for a hypothetical file just as well as a
  # real one -- and asking about a hypothetical removes two ways for this test
  # to fail for reasons that are not the property: a package whose `lib/` is
  # empty or absent (docs-only, or code not landed yet) used to `flunk`, and
  # picking `List.first()` out of a wildcard made the subject depend on
  # directory order.
  defp probe_path(package), do: "packages/#{package}/lib/formatter_probe.ex"
end
