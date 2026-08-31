defmodule RaxolPlayground.CapabilitiesTest do
  # Every number this module serves is read off the repo at compile time. These
  # tests hold it against the repo as it is NOW, so a hand-typed constant
  # sneaking back in fails here rather than going stale on the page for a
  # release or two -- which is exactly what happened to raxol_speech,
  # raxol_telegram and raxol_watch, all shown as 0.1 while published at 0.2.
  use ExUnit.Case, async: true

  alias RaxolPlayground.Capabilities

  @repo_root Path.expand("../../..", __DIR__)

  defp mix_version!(path) do
    [_, version] = Regex.run(~r/@version\s+"([^"]+)"/, File.read!(path))
    version
  end

  defp package_dirs do
    @repo_root
    |> Path.join("packages")
    |> File.ls!()
    |> Enum.filter(&File.exists?(Path.join([@repo_root, "packages", &1, "mix.exs"])))
    |> Enum.sort()
  end

  test "the repo package count is the directory it links to" do
    assert Capabilities.repo_package_count() == length(package_dirs())
    assert Enum.map(Capabilities.repo_packages(), & &1.name) == package_dirs()
  end

  test "every repo package carries the version its mix.exs states" do
    for %{name: name, version: version} <- Capabilities.repo_packages() do
      expected = mix_version!(Path.join([@repo_root, "packages", name, "mix.exs"]))

      assert version == expected, "#{name} reports #{version}, mix.exs says #{expected}"
    end
  end

  test "the displayed version comes from the repo, not a literal" do
    assert Capabilities.version() == mix_version!(Path.join(@repo_root, "mix.exs"))

    assert Capabilities.version_minor() ==
             Capabilities.version() |> String.split(".") |> Enum.take(2) |> Enum.join(".")
  end

  # The published set is a judgment call and stays written down -- `packages/`
  # also holds pre-alpha work nobody can depend on yet. Only its versions are
  # derived, and this is the assertion that keeps them derived.
  test "published packages carry the minor of their real version" do
    for %{name: name, version: constraint} <- Capabilities.packages() do
      mix =
        if name == "raxol",
          do: Path.join(@repo_root, "mix.exs"),
          else: Path.join([@repo_root, "packages", name, "mix.exs"])

      expected =
        mix |> mix_version!() |> String.split(".") |> Enum.take(2) |> Enum.join(".")

      assert constraint == "~> " <> expected,
             "#{name} advertises #{constraint}, mix.exs says #{expected}"
    end
  end

  test "the published set is a subset of what the repo actually holds" do
    repo = package_dirs() ++ ["raxol"]

    for %{name: name} <- Capabilities.packages() do
      assert name in repo, "#{name} is advertised but is not a package in this repo"
    end
  end
end
