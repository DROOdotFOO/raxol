defmodule Raxol.Release.PackageCheck do
  @moduledoc """
  Validates the Hex release train before publishing any package.

  The check is deliberately release-train aware. The repo has package metadata
  on pre-alpha projects for local builds, but the public Hex train is smaller
  and ordered by inter-package dependencies.
  """

  @required_link_sets [
    MapSet.new(["GitHub", "Changelog", "Docs"]),
    MapSet.new(["GitHub", "Changelog", "Documentation"])
  ]

  @public_packages [
    %{app: :raxol_core, path: "packages/raxol_core", class: :public},
    %{app: :raxol_sensor, path: "packages/raxol_sensor", class: :public},
    %{app: :raxol_terminal, path: "packages/raxol_terminal", class: :public},
    %{app: :raxol_mcp, path: "packages/raxol_mcp", class: :public},
    %{app: :raxol_liveview, path: "packages/raxol_liveview", class: :public},
    %{app: :raxol_plugin, path: "packages/raxol_plugin", class: :public},
    %{app: :raxol_speech, path: "packages/raxol_speech", class: :public},
    %{app: :raxol_watch, path: "packages/raxol_watch", class: :public},
    %{app: :raxol, path: ".", class: :public},
    %{app: :raxol_agent, path: "packages/raxol_agent", class: :public},
    %{app: :raxol_payments, path: "packages/raxol_payments", class: :public},
    %{app: :raxol_telegram, path: "packages/raxol_telegram", class: :public}
  ]

  @pre_alpha_packages [
    %{
      app: :raxol_agent_client_protocol,
      path: "packages/raxol_agent_client_protocol",
      class: :pre_alpha
    },
    %{app: :raxol_gateway, path: "packages/raxol_gateway", class: :pre_alpha},
    %{app: :raxol_earn, path: "packages/raxol_earn", class: :pre_alpha},
    %{app: :raxol_symphony, path: "packages/raxol_symphony", class: :pre_alpha},
    %{app: :raxol_cli, path: "packages/raxol_cli", class: :pre_alpha},
    %{app: :raxol_console, path: "packages/raxol_console", class: :pre_alpha}
  ]

  @all_packages @public_packages ++ @pre_alpha_packages
  @package_by_app Map.new(@all_packages, &{&1.app, &1})
  @package_apps MapSet.new(Map.keys(@package_by_app))

  @type package_spec :: %{
          required(:app) => atom(),
          required(:path) => String.t(),
          required(:class) => :public | :pre_alpha
        }

  @type package_report :: %{
          required(:app) => atom(),
          required(:path) => String.t(),
          required(:class) => :public | :pre_alpha,
          required(:version) => String.t() | nil,
          required(:hex_build?) => boolean(),
          required(:errors) => [String.t()],
          required(:warnings) => [String.t()]
        }

  @type report :: %{
          required(:root) => String.t(),
          required(:packages) => [package_report()],
          required(:errors) => [String.t()]
        }

  @doc "Returns the public Hex release train in publish order."
  @spec public_packages() :: [package_spec()]
  def public_packages, do: @public_packages

  @doc "Returns every explicitly classified package project."
  @spec all_packages() :: [package_spec()]
  def all_packages, do: @all_packages

  @doc "Selects packages according to the release checker options."
  @spec select_packages(keyword()) ::
          {:ok, [package_spec()]} | {:error, [String.t()]}
  def select_packages(opts \\ []) do
    available =
      if Keyword.get(opts, :include_pre_alpha, false),
        do: @all_packages,
        else: @public_packages

    only = normalize_only(Keyword.get(opts, :only, []))

    if only == [] do
      {:ok, available}
    else
      by_app = Map.new(available, &{&1.app, &1})
      missing = Enum.reject(only, &Map.has_key?(by_app, &1))

      if missing == [] do
        {:ok, Enum.map(only, &Map.fetch!(by_app, &1))}
      else
        known =
          available |> Enum.map(&Atom.to_string(&1.app)) |> Enum.join(", ")

        {:error,
         [
           "unknown package(s): #{Enum.map_join(missing, ", ", &Atom.to_string/1)}",
           "available packages: #{known}"
         ]}
      end
    end
  end

  @doc "Runs the metadata and Hex build checks."
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    case select_packages(opts) do
      {:ok, packages} ->
        report = do_run(root, packages, opts)

        if report.errors == [],
          do: {:ok, report},
          else: {:error, report}

      {:error, errors} ->
        {:error, %{root: root, packages: [], errors: errors}}
    end
  end

  @doc "Validates one loaded Mix project config against a package spec."
  @spec validate_project_config(package_spec(), keyword(), String.t(), [
          package_spec()
        ]) ::
          {[String.t()], [String.t()]}
  def validate_project_config(
        spec,
        config,
        package_path,
        release_train \\ @public_packages
      ) do
    package = Keyword.get(config, :package, [])
    docs = Keyword.get(config, :docs, [])
    selected_apps = MapSet.new(Enum.map(release_train, & &1.app))

    errors =
      []
      |> require_equal(
        config[:app],
        spec.app,
        "project app must be #{inspect(spec.app)}"
      )
      |> require_present(config[:version], "project version is missing")
      |> require_version(config[:version])
      |> require_present(config[:description], "project description is missing")
      |> require_keyword(package, "package metadata is missing")
      |> require_package_name(package, spec.app)
      |> require_nonempty_list(package[:files], "package files are missing")
      |> require_nonempty_list(
        package[:maintainers],
        "package maintainers are missing"
      )
      |> require_nonempty_list(
        package[:licenses],
        "package licenses are missing"
      )
      |> require_links(package[:links], spec.class)
      |> require_docs_source_ref(docs, config[:version])
      |> require_package_files(package_path, package[:files])
      |> require_readme(package_path, package[:files])
      |> require_license(package_path, package[:files])
      |> require_docs_extras(package_path, docs, package[:files])

    {dep_errors, dep_warnings} =
      validate_dependency_constraints(spec, config, selected_apps)

    {Enum.reverse(errors) ++ dep_errors, dep_warnings}
  end

  @doc "Returns the Raxol package dependencies relevant to a Hex publish."
  @spec release_deps(keyword()) :: [{atom(), String.t() | nil, keyword()}]
  def release_deps(config) do
    config
    |> Keyword.get(:deps, [])
    |> Enum.flat_map(fn dep ->
      with {name, requirement, opts} <- normalize_dep(dep),
           true <- MapSet.member?(@package_apps, name),
           true <- publish_env_dep?(opts) do
        [{name, requirement, opts}]
      else
        _ -> []
      end
    end)
  end

  defp do_run(root, packages, opts) do
    metadata_only? = Keyword.get(opts, :metadata_only, false)

    release_train =
      if Keyword.get(opts, :include_pre_alpha, false),
        do: @all_packages,
        else: @public_packages

    build_root =
      Keyword.get(
        opts,
        :build_root,
        Path.join(root, "tmp/package_release_check")
      )

    File.rm_rf!(build_root)
    File.mkdir_p!(build_root)

    try do
      package_reports =
        Enum.map(packages, fn spec ->
          check_package(root, spec, release_train, metadata_only?, build_root)
        end)

      report_errors =
        validate_catalog(root) ++
          validate_order(package_reports, release_train) ++
          Enum.flat_map(package_reports, fn package ->
            Enum.map(package.errors, &"#{package.app}: #{&1}")
          end)

      %{root: root, packages: package_reports, errors: report_errors}
    after
      unless Keyword.get(opts, :keep_output, false) do
        File.rm_rf(build_root)
      end
    end
  end

  defp check_package(root, spec, release_train, metadata_only?, build_root) do
    package_path = Path.expand(spec.path, root)

    case load_project_config(root, spec) do
      {:ok, config} ->
        {errors, warnings} =
          validate_project_config(spec, config, package_path, release_train)

        {hex_errors, hex_warnings} =
          if metadata_only? do
            {[], []}
          else
            run_hex_build(spec, package_path, config, build_root)
          end

        %{
          app: spec.app,
          path: spec.path,
          class: spec.class,
          version: config[:version],
          deps: release_deps(config),
          hex_build?: not metadata_only?,
          errors: errors ++ hex_errors,
          warnings: warnings ++ hex_warnings
        }

      {:error, reason} ->
        %{
          app: spec.app,
          path: spec.path,
          class: spec.class,
          version: nil,
          deps: [],
          hex_build?: not metadata_only?,
          errors: ["could not load mix project: #{reason}"],
          warnings: []
        }
    end
  end

  defp load_project_config(root, %{app: :raxol, path: "."}) do
    if Path.expand(File.cwd!()) == root do
      {:ok, Mix.Project.config()}
    else
      load_child_project(:raxol, root)
    end
  end

  defp load_project_config(root, %{app: app, path: path}) do
    load_child_project(app, Path.expand(path, root))
  end

  defp load_child_project(app, path) do
    with_hex_build_env(fn ->
      {:ok,
       Mix.Project.in_project(app, path, [], fn _module ->
         Mix.Project.config()
       end)}
    end)
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    :exit, reason -> {:error, Exception.format_exit(reason)}
  end

  defp with_hex_build_env(fun) do
    old = System.get_env("HEX_BUILD")
    System.put_env("HEX_BUILD", "1")

    try do
      fun.()
    after
      if old,
        do: System.put_env("HEX_BUILD", old),
        else: System.delete_env("HEX_BUILD")
    end
  end

  defp validate_catalog(root) do
    expected =
      @all_packages
      |> Enum.reject(&(&1.app == :raxol))
      |> Enum.map(& &1.app)
      |> MapSet.new()

    discovered =
      root
      |> Path.join("packages/*/mix.exs")
      |> Path.wildcard()
      |> Enum.map(&read_app!/1)
      |> MapSet.new()

    cond do
      MapSet.equal?(expected, discovered) ->
        []

      true ->
        missing = MapSet.difference(discovered, expected)
        stale = MapSet.difference(expected, discovered)

        [
          "package catalog mismatch: unclassified=#{format_app_set(missing)} " <>
            "missing=#{format_app_set(stale)}"
        ]
    end
  end

  defp read_app!(mix_exs) do
    {:ok, source} = File.read(mix_exs)
    [_, app] = Regex.run(~r/app:\s*:(\w+)/, source)
    String.to_atom(app)
  end

  defp validate_order(package_reports, release_train) do
    index =
      release_train
      |> Enum.with_index()
      |> Map.new(fn {spec, idx} -> {spec.app, idx} end)

    package_reports
    |> Enum.flat_map(fn report ->
      deps = Map.get(report, :deps, [])
      current = Map.fetch!(index, report.app)

      deps
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&Map.has_key?(index, &1))
      |> Enum.filter(&(Map.fetch!(index, &1) > current))
      |> Enum.map(fn dep ->
        "#{report.app}: release order places dependency #{dep} after dependent"
      end)
    end)
  end

  defp validate_dependency_constraints(spec, config, selected_apps) do
    release_deps(config)
    |> Enum.reduce({[], []}, fn {dep, requirement, opts}, {errors, warnings} ->
      target = Map.fetch!(@package_by_app, dep)

      cond do
        Keyword.has_key?(opts, :path) and spec.app != :raxol ->
          {[
             "dependency #{dep} still has a path option under HEX_BUILD"
             | errors
           ], warnings}

        not MapSet.member?(selected_apps, dep) ->
          {["dependency #{dep} is outside the selected release train" | errors],
           warnings}

        requirement != expected_requirement(target) ->
          expected = expected_requirement(target)

          {[
             "dependency #{dep} uses #{inspect(requirement)}; expected #{inspect(expected)}"
             | errors
           ], warnings}

        true ->
          {errors, warnings}
      end
    end)
    |> then(fn {errors, warnings} ->
      {Enum.reverse(errors), Enum.reverse(warnings)}
    end)
  end

  defp expected_requirement(%{app: app}) do
    app
    |> package_version!()
    |> expected_requirement()
  end

  defp expected_requirement(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %Version{major: major, minor: minor}} -> "~> #{major}.#{minor}"
      :error -> nil
    end
  end

  defp package_version!(app) when is_atom(app),
    do: package_version!(Map.fetch!(@package_by_app, app))

  defp package_version!(%{path: "."}) do
    Mix.Project.config()[:version]
  end

  defp package_version!(%{path: path, app: app}) do
    path = Path.expand(path, File.cwd!())

    with_hex_build_env(fn ->
      Mix.Project.in_project(app, path, [], fn _module ->
        Mix.Project.config()[:version]
      end)
    end)
  end

  defp run_hex_build(spec, package_path, config, build_root) do
    output_dir = Path.join(build_root, Atom.to_string(spec.app))
    File.rm_rf!(output_dir)

    case System.find_executable("mix") do
      nil ->
        {["mix executable was not found"], []}

      mix ->
        {output, status} =
          System.cmd(mix, ["hex.build", "--unpack", "--output", output_dir],
            cd: package_path,
            env: [{"HEX_BUILD", "1"}, {"MIX_ENV", "prod"}],
            stderr_to_stdout: true
          )

        try do
          if status == 0 do
            output_dir
            |> read_hex_metadata()
            |> validate_hex_metadata(spec, config)
          else
            {["hex.build failed with exit #{status}: #{trim_output(output)}"],
             []}
          end
        after
          File.rm_rf(output_dir)
        end
    end
  end

  defp read_hex_metadata(output_dir) do
    metadata_path = Path.join(output_dir, "hex_metadata.config")

    case :file.consult(String.to_charlist(metadata_path)) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_hex_metadata({:error, reason}, _spec, _config) do
    {["could not read hex_metadata.config: #{inspect(reason)}"], []}
  end

  defp validate_hex_metadata({:ok, metadata}, spec, config) do
    app = metadata_string(metadata, "app")
    name = metadata_string(metadata, "name")
    version = metadata_string(metadata, "version")
    requirements = metadata_requirements(metadata)
    requirement_names = MapSet.new(Enum.map(requirements, & &1.name))

    errors =
      []
      |> require_equal(
        app,
        Atom.to_string(spec.app),
        "hex metadata app must match"
      )
      |> require_equal(
        name,
        Atom.to_string(spec.app),
        "hex metadata name must match"
      )
      |> require_equal(
        version,
        config[:version],
        "hex metadata version must match"
      )
      |> require_hexpm_requirements(requirements)
      |> require_packaged_release_deps(config, requirement_names)

    {Enum.reverse(errors), []}
  end

  defp metadata_string(metadata, key) do
    metadata
    |> metadata_value(key)
    |> to_string_value()
  end

  defp metadata_requirements(metadata) do
    metadata
    |> metadata_value("requirements")
    |> List.wrap()
    |> Enum.map(fn requirement ->
      %{
        name: metadata_string(requirement, "name") |> String.to_atom(),
        repository: metadata_string(requirement, "repository")
      }
    end)
  end

  defp metadata_value(metadata, key) do
    Enum.find_value(metadata, fn
      {found, value} ->
        if to_string(found) == key, do: value

      _other ->
        nil
    end)
  end

  defp to_string_value(nil), do: nil
  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_value(value), do: to_string(value)

  defp require_packaged_release_deps(errors, config, requirement_names) do
    config
    |> release_deps()
    |> Enum.reduce(errors, fn {dep, _requirement, opts}, acc ->
      cond do
        not Keyword.has_key?(opts, :path) and
            MapSet.member?(requirement_names, dep) ->
          acc

        Keyword.has_key?(opts, :path) and MapSet.member?(requirement_names, dep) ->
          acc

        true ->
          ["hex metadata omits release dependency #{dep}" | acc]
      end
    end)
  end

  defp require_hexpm_requirements(errors, requirements) do
    Enum.reduce(requirements, errors, fn requirement, acc ->
      if requirement.repository == "hexpm" do
        acc
      else
        [
          "dependency #{requirement.name} is not a Hex package requirement"
          | acc
        ]
      end
    end)
  end

  defp require_equal(errors, actual, expected, message) do
    if actual == expected,
      do: errors,
      else: ["#{message}: got #{inspect(actual)}" | errors]
  end

  defp require_present(errors, value, message) do
    if present?(value), do: errors, else: [message | errors]
  end

  defp require_version(errors, version) do
    case Version.parse(to_string(version || "")) do
      {:ok, _version} ->
        errors

      :error ->
        ["project version #{inspect(version)} is not a valid version" | errors]
    end
  end

  defp require_keyword(errors, value, message) do
    if Keyword.keyword?(value), do: errors, else: [message | errors]
  end

  defp require_package_name(errors, package, app) do
    require_equal(
      errors,
      package[:name],
      Atom.to_string(app),
      "package name must match app"
    )
  end

  defp require_nonempty_list(errors, value, message) do
    if is_list(value) and value != [], do: errors, else: [message | errors]
  end

  defp require_links(errors, links, :public) when is_map(links) do
    keys = links |> Map.keys() |> MapSet.new()

    if Enum.any?(@required_link_sets, &MapSet.subset?(&1, keys)) do
      errors
    else
      [
        "package links must include GitHub, Changelog, and Docs/Documentation"
        | errors
      ]
    end
  end

  defp require_links(errors, links, _class)
       when is_map(links) and map_size(links) > 0,
       do: errors

  defp require_links(errors, _links, _class),
    do: ["package links are missing" | errors]

  defp require_docs_source_ref(errors, docs, _version) when docs in [nil, []],
    do: errors

  defp require_docs_source_ref(errors, docs, version) do
    require_equal(
      errors,
      docs[:source_ref],
      "v#{version}",
      "docs source_ref must match version"
    )
  end

  defp require_package_files(errors, package_path, files) when is_list(files) do
    files
    |> Enum.filter(&(package_file_matches(package_path, &1) == []))
    |> Enum.reduce(errors, fn file, acc ->
      ["package file entry #{inspect(file)} does not match anything" | acc]
    end)
  end

  defp require_package_files(errors, _package_path, _files), do: errors

  defp require_readme(errors, package_path, files) do
    if package_contains?(
         package_path,
         files,
         &String.starts_with?(&1, "README")
       ),
       do: errors,
       else: ["package files do not include a README" | errors]
  end

  defp require_license(errors, package_path, files) do
    if package_contains?(
         package_path,
         files,
         &String.starts_with?(&1, "LICENSE")
       ),
       do: errors,
       else: ["package files do not include a LICENSE" | errors]
  end

  defp require_docs_extras(errors, _package_path, docs, _files)
       when docs in [nil, []],
       do: errors

  defp require_docs_extras(errors, package_path, docs, files) do
    docs
    |> Keyword.get(:extras, [])
    |> Enum.map(&doc_extra_path/1)
    |> Enum.reduce(errors, fn extra, acc ->
      abs = Path.expand(extra, package_path)

      cond do
        not File.exists?(abs) ->
          ["docs extra #{inspect(extra)} does not exist" | acc]

        not package_includes?(package_path, files, abs) ->
          [
            "docs extra #{inspect(extra)} is not included in package files"
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  defp doc_extra_path({path, _opts}), do: path
  defp doc_extra_path(path), do: path

  defp package_contains?(package_path, files, predicate) do
    package_path
    |> package_file_set(files)
    |> Enum.any?(fn path -> path |> Path.basename() |> predicate.() end)
  end

  defp package_includes?(package_path, files, abs_path) do
    package_path
    |> package_file_set(files)
    |> MapSet.member?(abs_path)
  end

  defp package_file_set(package_path, files) do
    files
    |> List.wrap()
    |> Enum.flat_map(&package_file_matches(package_path, &1))
    |> MapSet.new()
  end

  defp package_file_matches(package_path, file) do
    path = Path.expand(file, package_path)

    cond do
      wildcard?(file) ->
        Path.wildcard(path)

      File.dir?(path) ->
        [path | Path.wildcard(Path.join(path, "**/*"))]

      File.exists?(path) ->
        [path]

      true ->
        []
    end
    |> Enum.map(&Path.expand/1)
  end

  defp wildcard?(file), do: String.contains?(file, ["*", "?", "["])

  defp normalize_dep({name, requirement}) when is_atom(name),
    do: {name, requirement, []}

  defp normalize_dep({name, requirement, opts}) when is_atom(name),
    do: {name, requirement, opts}

  defp normalize_dep(_dep), do: :error

  defp publish_env_dep?(opts) do
    case Keyword.get(opts, :only) do
      nil -> true
      :prod -> true
      envs when is_list(envs) -> :prod in envs
      _other -> false
    end
  end

  defp normalize_only(nil), do: []
  defp normalize_only([]), do: []

  defp normalize_only(apps) when is_list(apps) do
    Enum.map(apps, &normalize_app!/1)
  end

  defp normalize_only(app) do
    [normalize_app!(app)]
  end

  defp normalize_app!(app) when is_atom(app), do: app

  defp normalize_app!(app) when is_binary(app),
    do: app |> String.trim() |> String.to_atom()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp trim_output(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> Enum.take(-20)
    |> Enum.join("\n")
  end

  defp format_app_set(apps) do
    apps
    |> Enum.map(&Atom.to_string/1)
    |> Enum.sort()
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      joined -> joined
    end
  end
end
