defmodule Raxol.Release.PackageCheckTest do
  use ExUnit.Case, async: false

  alias Raxol.Release.PackageCheck

  @moduletag :tmp_dir

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

    test "rejects an unknown name without minting an atom for it" do
      name = "raxol_not_a_real_package_#{System.unique_integer([:positive])}"

      assert {:error, errors} = PackageCheck.select_packages(only: [name])
      assert Enum.any?(errors, &String.contains?(&1, "unknown package(s)"))

      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end

    test "points at --all when the name is a pre-alpha package" do
      assert {:error, errors} =
               PackageCheck.select_packages(only: ["raxol_symphony"])

      assert Enum.any?(errors, &String.contains?(&1, "pass --all"))
    end

    test "accepts a pre-alpha package once --all is set" do
      assert {:ok, packages} =
               PackageCheck.select_packages(
                 include_pre_alpha: true,
                 only: ["raxol_symphony"]
               )

      assert Enum.map(packages, & &1.app) == [:raxol_symphony]
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

  describe "resolve_build_root/2" do
    test "resolves the default under the project root", %{tmp_dir: root} do
      assert {:ok, path} = PackageCheck.resolve_build_root(root, [])
      assert String.starts_with?(path, Path.expand(root) <> "/")
    end

    test "refuses the project root itself", %{tmp_dir: root} do
      assert {:error, [message]} =
               PackageCheck.resolve_build_root(root, build_root: ".")

      assert message =~ "must not be the project root"
    end

    test "refuses a path that escapes the project root", %{tmp_dir: root} do
      assert {:error, [message]} =
               PackageCheck.resolve_build_root(root, build_root: "../escape")

      assert message =~ "not confined to the project root"
    end

    test "jails an absolute request under the project root", %{tmp_dir: root} do
      assert {:ok, path} =
               PackageCheck.resolve_build_root(root, build_root: "/etc")

      assert path == Path.join(Path.expand(root), "etc")
    end

    test "refuses a populated directory it did not create", %{tmp_dir: root} do
      occupied = Path.join(root, "occupied")
      File.mkdir_p!(occupied)
      File.write!(Path.join(occupied, "keep.txt"), "important\n")

      assert {:error, [message]} =
               PackageCheck.resolve_build_root(root, build_root: "occupied")

      assert message =~ "refusing to delete existing directory"
    end

    test "reuses a directory carrying its own marker", %{tmp_dir: root} do
      reusable = Path.join(root, "scratch")
      File.mkdir_p!(reusable)
      File.write!(Path.join(reusable, ".raxol-release-check"), "")
      File.write!(Path.join(reusable, "stale.txt"), "from a previous run\n")

      assert {:ok, _path} =
               PackageCheck.resolve_build_root(root, build_root: "scratch")
    end

    test "refuses a non-string build root", %{tmp_dir: root} do
      assert {:error, [message]} =
               PackageCheck.resolve_build_root(root, build_root: :tmp)

      assert message =~ "must be a string"
    end
  end

  describe "validate_order/2" do
    setup do
      train = [
        %{app: :raxol_core, path: "packages/raxol_core", class: :public},
        %{app: :raxol_agent, path: "packages/raxol_agent", class: :public}
      ]

      {:ok, train: train}
    end

    test "accepts a dependency published before its dependent", %{train: train} do
      reports = [
        %{app: :raxol_agent, deps: [{:raxol_core, "~> 2.6", []}]}
      ]

      assert PackageCheck.validate_order(reports, train) == []
    end

    test "flags a dependency published after its dependent", %{train: train} do
      reports = [
        %{app: :raxol_core, deps: [{:raxol_agent, "~> 2.6", []}]}
      ]

      assert [message] = PackageCheck.validate_order(reports, train)
      assert message =~ "places dependency raxol_agent after dependent"
    end

    test "ignores dependencies outside the train", %{train: train} do
      reports = [%{app: :raxol_core, deps: [{:raxol_earn, "~> 0.2", []}]}]

      assert PackageCheck.validate_order(reports, train) == []
    end
  end

  describe "validate_catalog/1" do
    test "flags a package directory that is not classified", %{tmp_dir: root} do
      write_package_project!(root, "raxol_unlisted")

      assert [message] = PackageCheck.validate_catalog(root)
      assert message =~ "unclassified=raxol_unlisted"
      assert message =~ "missing="
    end

    test "flags a mix.exs whose app name cannot be read", %{tmp_dir: root} do
      broken = Path.join(root, "packages/raxol_broken")
      File.mkdir_p!(broken)
      File.write!(Path.join(broken, "mix.exs"), "# no project here\n")

      assert [message] = PackageCheck.validate_catalog(root)
      assert message =~ "could not read the app name from"
      assert message =~ "raxol_broken"
    end

    test "ignores an app: occurrence that is not the project app", %{
      tmp_dir: root
    } do
      path = Path.join(root, "packages/raxol_commented")
      File.mkdir_p!(path)

      File.write!(Path.join(path, "mix.exs"), """
      defmodule RaxolCommented.MixProject do
        # historically this was app: :raxol_old_name
        def project do
          [
            app: :raxol_commented,
            version: "0.1.0"
          ]
        end
      end
      """)

      assert [message] = PackageCheck.validate_catalog(root)
      assert message =~ "unclassified=raxol_commented"
      refute message =~ "raxol_old_name"
    end

    # The decoy is at the start of its own line, so it matches the bare `app:`
    # pattern the same way the real key does. Only anchoring on `def project`
    # tells them apart, and getting it wrong reports a catalog mismatch about a
    # package name that appears nowhere in the tree.
    test "reads the project app, not an earlier app: at line start", %{
      tmp_dir: root
    } do
      path = Path.join(root, "packages/raxol_decoy")
      File.mkdir_p!(path)

      File.write!(Path.join(path, "mix.exs"), """
      defmodule RaxolDecoy.MixProject do
        @moduledoc \"\"\"
        Configure it like this:

            app: :raxol_wrong_name
        \"\"\"

        def project do
          [
            app: :raxol_decoy,
            version: "0.1.0"
          ]
        end
      end
      """)

      assert [message] = PackageCheck.validate_catalog(root)
      assert message =~ "unclassified=raxol_decoy"
      refute message =~ "raxol_wrong_name"
    end
  end

  describe "audit_release_deps/2" do
    test "accepts a dependency that reached the tarball" do
      config = [deps: [{:raxol_core, "~> 2.6"}]]
      requirements = MapSet.new(["raxol_core"])

      assert PackageCheck.audit_release_deps(config, requirements) == {[], []}
    end

    test "errors when a public-train dependency is missing from the tarball" do
      config = [deps: [{:raxol_core, "~> 2.6"}]]

      assert {[error], []} =
               PackageCheck.audit_release_deps(config, MapSet.new())

      assert error =~ "published tarball omits release dependency raxol_core"
    end

    test "warns when a pre-alpha dependency is dropped from the tarball" do
      config = [deps: [{:raxol_gateway, "~> 0.1", optional: true}]]

      assert {[], [warning]} =
               PackageCheck.audit_release_deps(config, MapSet.new())

      assert warning =~ "raxol_gateway is dropped from the published tarball"
    end
  end

  describe "untracked_package_files/3" do
    test "flags a packaged file that git does not track", %{tmp_dir: root} do
      init_git_repo!(root)
      package = fixture_package!(root)

      File.write!(Path.join(root, "docs/stray.md"), "# Stray\n")
      stage!(root, ["README.md", "LICENSE.md", "docs/guide.md"])

      assert {:ok, untracked} =
               PackageCheck.untracked_package_files(root, root,
                 files: ~w(README.md LICENSE.md docs)
               )

      assert "docs/stray.md" in untracked
      refute "docs/guide.md" in untracked
      assert package == root
    end

    test "honours exclude_patterns", %{tmp_dir: root} do
      init_git_repo!(root)
      fixture_package!(root)

      File.write!(Path.join(root, "lib/built.so"), "binary\n")
      stage!(root, ["README.md", "lib/fixture.ex"])

      assert {:ok, untracked} =
               PackageCheck.untracked_package_files(root, root,
                 files: ~w(lib README.md),
                 exclude_patterns: [~r/\.so$/]
               )

      assert untracked == []

      # Without the exclusion the same build artifact is a finding, which is
      # what makes the exclusion load-bearing rather than decorative.
      assert {:ok, ["lib/built.so"]} =
               PackageCheck.untracked_package_files(root, root,
                 files: ~w(lib README.md)
               )
    end

    # The file class this whole layer exists for. `.env`, `.env.*` and
    # `.secrets` are gitignored at the repo root, so they are untracked by
    # construction, and `mix hex.build` walks packaged directories with
    # dot-matching on and ships them. A walk without `match_dot: true` reports
    # a clean tree while the tarball carries the secret.
    test "flags an untracked dotfile under a packaged directory", %{
      tmp_dir: root
    } do
      init_git_repo!(root)
      fixture_package!(root)

      File.write!(Path.join(root, "lib/.env"), "SECRET=leak\n")
      File.write!(Path.join(root, "docs/.hidden.md"), "# Not for Hex\n")
      stage!(root, ["README.md", "lib/fixture.ex", "docs/guide.md"])

      assert {:ok, untracked} =
               PackageCheck.untracked_package_files(root, root,
                 files: ~w(lib docs README.md)
               )

      assert "lib/.env" in untracked
      assert "docs/.hidden.md" in untracked
    end

    test "counts a tracked dotfile as tracked", %{tmp_dir: root} do
      init_git_repo!(root)
      fixture_package!(root)

      File.write!(Path.join(root, "lib/.credo.exs"), "[]\n")
      stage!(root, ["README.md", "lib/fixture.ex", "lib/.credo.exs"])

      assert {:ok, untracked} =
               PackageCheck.untracked_package_files(root, root,
                 files: ~w(lib README.md)
               )

      assert untracked == []
    end

    test "reports :unavailable outside a git repository" do
      root =
        Path.join(
          System.tmp_dir!(),
          "raxol-release-check-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      fixture_package!(root)

      # Only meaningful when the scratch directory really is outside a
      # repository; otherwise git answers for the enclosing one.
      case System.cmd("git", ["rev-parse", "--git-dir"],
             cd: root,
             stderr_to_stdout: true
           ) do
        {_output, 0} ->
          :ok

        _not_a_repo ->
          assert PackageCheck.untracked_package_files(root, root,
                   files: ~w(README.md)
                 ) == :unavailable
      end
    end
  end

  describe "validate_project_config/4" do
    test "accepts a complete package", %{tmp_dir: root} do
      fixture_package!(root)

      assert {[], []} =
               PackageCheck.validate_project_config(
                 spec(),
                 valid_config(),
                 root,
                 []
               )
    end

    test "rejects docs extras absent from package files", %{tmp_dir: root} do
      fixture_package!(root)

      config =
        put_in(valid_config()[:docs][:extras], ["README.md", "docs/guide.md"])

      {errors, warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert warnings == []

      assert "docs extra \"docs/guide.md\" is not included in package files" in errors
    end

    test "rejects a docs source_ref that drifted from the version", %{
      tmp_dir: root
    } do
      fixture_package!(root)

      config = put_in(valid_config()[:docs][:source_ref], "v0.0.1")

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert Enum.any?(errors, &(&1 =~ "docs source_ref must match version"))
    end

    # ex_doc's keyword-literal spelling puts an atom where the other two
    # spellings put a string. `Path.expand/2` raises on an atom, which would
    # abort the whole run rather than report a finding.
    test "handles the keyword-literal docs extras spelling", %{tmp_dir: root} do
      fixture_package!(root)

      config =
        Keyword.put(valid_config(), :docs,
          source_ref: "v1.2.3",
          extras: ["README.md": [title: "Overview"]]
        )

      assert {[], []} =
               PackageCheck.validate_project_config(spec(), config, root, [])
    end

    test "rejects a keyword-literal extra that is not packaged", %{
      tmp_dir: root
    } do
      fixture_package!(root)

      config =
        Keyword.put(valid_config(), :docs,
          source_ref: "v1.2.3",
          extras: ["docs/guide.md": [title: "Guide"]]
        )

      assert {[message], []} =
               PackageCheck.validate_project_config(spec(), config, root, [])

      assert message =~ "is not included in package files"
    end

    test "rejects a package file entry that matches nothing", %{tmp_dir: root} do
      fixture_package!(root)

      config = put_in(valid_config()[:package][:files], ~w(README.md nope.md))

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert Enum.any?(errors, &(&1 =~ ~s(entry "nope.md" does not match)))
    end

    test "rejects a package missing a LICENSE file", %{tmp_dir: root} do
      fixture_package!(root)
      File.rm!(Path.join(root, "LICENSE.md"))

      config = put_in(valid_config()[:package][:files], ~w(README.md))

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert "package files do not include a LICENSE" in errors
    end

    test "rejects an incomplete link set on a public package", %{tmp_dir: root} do
      fixture_package!(root)

      config =
        put_in(valid_config()[:package][:links], %{
          "GitHub" => "https://github.com/DROOdotFOO/raxol"
        })

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert Enum.any?(errors, &(&1 =~ "must include GitHub, Changelog"))
    end

    test "rejects a version that is not a valid semver", %{tmp_dir: root} do
      fixture_package!(root)

      config = Keyword.put(valid_config(), :version, "not-a-version")

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert Enum.any?(errors, &(&1 =~ "is not a valid version"))
    end

    test "rejects a mismatched project app", %{tmp_dir: root} do
      fixture_package!(root)

      config = Keyword.put(valid_config(), :app, :something_else)

      {errors, _warnings} =
        PackageCheck.validate_project_config(spec(), config, root, [])

      assert Enum.any?(errors, &(&1 =~ "project app must be :fixture"))
    end
  end

  describe "run/1" do
    test "validates package metadata for a public package" do
      assert {:ok, report} =
               PackageCheck.run(metadata_only: true, only: [:raxol_core])

      assert report.errors == []
      assert report.global_errors == []
      assert [%{app: :raxol_core, errors: []}] = report.packages
    end

    test "refuses a dangerous build root before doing any work" do
      assert {:error, report} =
               PackageCheck.run(
                 metadata_only: true,
                 only: [:raxol_core],
                 build_root: "."
               )

      assert report.packages == []
      assert [message] = report.global_errors
      assert message =~ "must not be the project root"
    end
  end

  # --- fixtures --------------------------------------------------------------

  defp spec, do: %{app: :fixture, path: ".", class: :public}

  defp valid_config do
    [
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
      docs: [source_ref: "v1.2.3", extras: ["README.md"]]
    ]
  end

  defp fixture_package!(root) do
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "docs"))
    File.write!(Path.join(root, ".formatter.exs"), "[]\n")

    File.write!(
      Path.join(root, "lib/fixture.ex"),
      "defmodule Fixture do\nend\n"
    )

    File.write!(
      Path.join(root, "mix.exs"),
      "defmodule Fixture.MixProject do\nend\n"
    )

    File.write!(Path.join(root, "README.md"), "# Fixture\n")
    File.write!(Path.join(root, "LICENSE.md"), "MIT\n")
    File.write!(Path.join(root, "docs/guide.md"), "# Guide\n")

    root
  end

  defp write_package_project!(root, name) do
    path = Path.join(root, "packages/#{name}")
    File.mkdir_p!(path)

    File.write!(Path.join(path, "mix.exs"), """
    defmodule #{Macro.camelize(name)}.MixProject do
      def project do
        [
          app: :#{name},
          version: "0.1.0"
        ]
      end
    end
    """)

    path
  end

  defp init_git_repo!(root) do
    unless System.find_executable("git") do
      raise "git is required for the provenance tests"
    end

    {_output, 0} = System.cmd("git", ["init", "--quiet"], cd: root)
    :ok
  end

  defp stage!(root, paths) do
    {_output, 0} = System.cmd("git", ["add", "--" | paths], cd: root)
    :ok
  end
end
