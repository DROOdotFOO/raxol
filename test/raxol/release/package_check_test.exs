defmodule Raxol.Release.PackageCheckTest do
  use ExUnit.Case, async: false

  alias Raxol.Release.PackageCheck

  describe "select_packages/1" do
    test "defaults to the public Hex train" do
      assert {:ok, packages} = PackageCheck.select_packages([])

      apps = Enum.map(packages, & &1.app)

      assert :raxol_core in apps
      assert :raxol_telegram in apps
      refute :raxol_cli in apps
      refute :raxol_symphony in apps
    end

    test "keeps --only in caller order" do
      assert {:ok, packages} =
               PackageCheck.select_packages(
                 only: ["raxol_sensor", "raxol_core"]
               )

      assert Enum.map(packages, & &1.app) == [:raxol_sensor, :raxol_core]
    end
  end

  describe "release_deps/1" do
    test "keeps publish-time Raxol deps and ignores test-only deps" do
      deps =
        PackageCheck.release_deps(
          deps: [
            {:raxol_core, "~> 2.6"},
            {:raxol_earn, "~> 0.2", only: :test},
            {:raxol_agent, "~> 2.6", runtime: false},
            {:jason, "~> 1.4"}
          ]
        )

      assert deps == [
               {:raxol_core, "~> 2.6", []},
               {:raxol_agent, "~> 2.6", runtime: false}
             ]
    end
  end

  describe "validate_project_config/4" do
    test "rejects docs extras absent from package files" do
      root = fixture_package!()
      on_exit(fn -> File.rm_rf(root) end)

      config = [
        app: :fixture,
        version: "1.2.3",
        description: "Fixture package",
        deps: [],
        package: [
          name: "fixture",
          files: ~w(lib .formatter.exs mix.exs README.md LICENSE.md),
          maintainers: ["Raxol Team"],
          licenses: ["MIT"],
          links: %{
            "GitHub" => "https://github.com/DROOdotFOO/raxol",
            "Docs" => "https://hexdocs.pm/fixture",
            "Changelog" =>
              "https://github.com/DROOdotFOO/raxol/blob/master/CHANGELOG.md"
          }
        ],
        docs: [source_ref: "v1.2.3", extras: ["README.md", "docs/guide.md"]]
      ]

      {errors, warnings} =
        PackageCheck.validate_project_config(
          %{app: :fixture, path: ".", class: :public},
          config,
          root,
          []
        )

      assert warnings == []

      assert "docs extra \"docs/guide.md\" is not included in package files" in errors
    end
  end

  describe "run/1" do
    test "validates package metadata for a public package" do
      assert {:ok, report} =
               PackageCheck.run(metadata_only: true, only: [:raxol_core])

      assert report.errors == []
      assert [%{app: :raxol_core, errors: []}] = report.packages
    end
  end

  defp fixture_package! do
    root = Path.join(System.tmp_dir!(), "raxol-package-check-fixture")

    File.rm_rf!(root)
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, ".formatter.exs"), "[]\n")

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Fixture.MixProject do\nend\n"
    )

    File.write!(Path.join(root, "README.md"), "# Fixture\n")
    File.write!(Path.join(root, "LICENSE.md"), "MIT\n")
    File.write!(Path.join(root, "docs/guide.md"), "# Guide\n")

    root
  end
end
