defmodule Raxol.Release.PackageCheck do
  @moduledoc """
  Validates the Hex release train before publishing any package.

  The check is deliberately release-train aware. The repo has package metadata
  on pre-alpha projects for local builds, but the public Hex train is smaller
  and ordered by inter-package dependencies.

  Three layers run per package:

    * **metadata** -- project/package/docs keys, link sets, file globs that
      match something, docs extras that are actually packaged, and dependency
      requirements that agree with the version each dependency publishes.

    * **provenance** -- every file the package would ship is tracked by git, so
      publishing from a dirty tree cannot leak untracked content into a public
      registry. `mix hex.build` packages the working tree, not the commit, so a
      green run on a dirty tree otherwise says nothing about what ships.

    * **tarball** -- `HEX_BUILD=1 mix hex.build --unpack`, then the generated
      `hex_metadata.config` is compared against the *source* project config.
      Comparing against the publish config would be circular: a dependency
      dropped by an env conditional in `mix.exs` is absent from both sides and
      produces no finding at all.
  """

  alias Raxol.Core.Boundary.Path, as: Boundary

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
  @package_apps MapSet.new(@all_packages, & &1.app)
  @public_apps MapSet.new(@public_packages, & &1.app)
  @pre_alpha_names MapSet.new(@pre_alpha_packages, &Atom.to_string(&1.app))

  # Per-process, because the directory is deleted recursively at both ends of a
  # run. Two concurrent runs -- a manual one and the `mix raxol.check` that
  # shells out to this task -- otherwise share one scratch directory and delete
  # each other's tarballs mid-build.
  @default_build_dir "tmp/package_release_check"
  @build_marker ".raxol-release-check"
  @max_reported_untracked 10

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
          required(:deps) => [{atom(), String.t() | nil, keyword()}],
          required(:hex_build?) => boolean(),
          required(:errors) => [String.t()],
          required(:warnings) => [String.t()]
        }

  @type report :: %{
          required(:root) => String.t(),
          required(:packages) => [package_report()],
          required(:global_errors) => [String.t()],
          required(:errors) => [String.t()]
        }

  @doc "Returns the public Hex release train in publish order."
  @spec public_packages() :: [package_spec()]
  def public_packages, do: @public_packages

  @doc "Returns every explicitly classified package project."
  @spec all_packages() :: [package_spec()]
  def all_packages, do: @all_packages

  @doc """
  Selects packages according to the release checker options.

  `:only` accepts atoms or strings. Strings are matched against known package
  names rather than converted, so a typo cannot mint an atom from argv.
  """
  @spec select_packages(keyword()) ::
          {:ok, [package_spec()]} | {:error, [String.t()]}
  def select_packages(opts \\ []) do
    available = available_packages(opts)

    case normalize_only(Keyword.get(opts, :only, [])) do
      [] -> {:ok, available}
      only -> resolve_only(only, available)
    end
  end

  @doc """
  Runs the metadata, provenance, and Hex build checks.

  Not safe to run concurrently with anything else in the same VM. Loading a
  child project goes through `Mix.Project.in_project/4`, which changes the
  working directory of the whole OS process, and the HEX_BUILD toggling around
  it mutates the process environment. Both are global. Tests covering this
  module are `async: false` for that reason.
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with {:ok, packages} <- select_packages(opts),
         {:ok, build_root} <- resolve_build_root(root, opts) do
      report = do_run(root, packages, build_root, opts)

      if report.errors == [],
        do: {:ok, report},
        else: {:error, report}
    else
      {:error, errors} ->
        {:error,
         %{root: root, packages: [], global_errors: errors, errors: errors}}
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
    versions = version_index(release_train, %{})

    validate_metadata(spec, config, package_path, %{
      release_train: release_train,
      versions: versions,
      reloadable?: true
    })
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

  # --- selection -------------------------------------------------------------

  defp available_packages(opts) do
    if Keyword.get(opts, :include_pre_alpha, false),
      do: @all_packages,
      else: @public_packages
  end

  defp resolve_only(only, available) do
    by_name = Map.new(available, &{Atom.to_string(&1.app), &1})
    missing = Enum.reject(only, &Map.has_key?(by_name, &1))

    if missing == [] do
      {:ok, Enum.map(only, &Map.fetch!(by_name, &1))}
    else
      {:error, unknown_package_errors(missing, available)}
    end
  end

  defp unknown_package_errors(missing, available) do
    known = Enum.map_join(available, ", ", &Atom.to_string(&1.app))

    hint =
      case Enum.filter(missing, &MapSet.member?(@pre_alpha_names, &1)) do
        [] ->
          []

        pre_alpha ->
          [
            "#{Enum.join(pre_alpha, ", ")} is pre-alpha; pass --all to include it"
          ]
      end

    [
      "unknown package(s): #{Enum.join(missing, ", ")}",
      "available packages: #{known}"
    ] ++ hint
  end

  defp normalize_only(nil), do: []
  defp normalize_only([]), do: []

  defp normalize_only(apps) when is_list(apps),
    do: Enum.map(apps, &to_package_name/1)

  defp normalize_only(app), do: [to_package_name(app)]

  defp to_package_name(app) when is_atom(app), do: Atom.to_string(app)
  defp to_package_name(app) when is_binary(app), do: String.trim(app)

  # --- build root ------------------------------------------------------------

  @doc """
  Resolves the scratch directory the Hex builds unpack into.

  `build_root` is deleted recursively, so it is confined under the project root
  and may be neither the root itself nor an existing directory this checker did
  not create. Without those gates `run(build_root: ".")` deletes the working
  tree. The path is always interpreted relative to `root`; an absolute request
  is jailed under it rather than honoured.
  """
  @spec resolve_build_root(String.t(), keyword()) ::
          {:ok, String.t()} | {:error, [String.t()]}
  def resolve_build_root(root, opts \\ []) do
    requested = Keyword.get(opts, :build_root, default_build_dir())

    with true <- is_binary(requested),
         {:ok, path} <- Boundary.confine(root, requested),
         :ok <- refuse_project_root(path, root),
         :ok <- refuse_foreign_directory(path) do
      {:ok, path}
    else
      false ->
        {:error, ["build_root must be a string, got #{inspect(requested)}"]}

      {:error, reason} when is_atom(reason) ->
        {:error,
         [
           "build_root #{inspect(requested)} is not confined to the project " <>
             "root (#{reason})"
         ]}

      {:error, errors} when is_list(errors) ->
        {:error, errors}
    end
  end

  defp default_build_dir, do: Path.join(@default_build_dir, System.pid())

  defp refuse_project_root(path, root) do
    if path == root do
      {:error, ["build_root must not be the project root itself"]}
    else
      :ok
    end
  end

  defp refuse_foreign_directory(path) do
    cond do
      not File.exists?(path) -> :ok
      File.exists?(Path.join(path, @build_marker)) -> :ok
      File.dir?(path) and File.ls!(path) == [] -> :ok
      true -> {:error, ["refusing to delete existing directory #{path}"]}
    end
  end

  # --- run -------------------------------------------------------------------

  defp do_run(root, packages, build_root, opts) do
    release_train = available_packages(opts)
    configs = load_configs(root, release_train)

    ctx = %{
      root: root,
      build_root: build_root,
      release_train: release_train,
      configs: configs,
      versions: version_index(release_train, configs),
      tracked: tracked_index(root),
      metadata_only?: Keyword.get(opts, :metadata_only, false),
      allow_untracked?: Keyword.get(opts, :allow_untracked, false)
    }

    prepare_build_root!(build_root)

    try do
      package_reports = Enum.map(packages, &check_package(ctx, &1))

      global_errors =
        validate_catalog(root) ++ validate_order(package_reports, release_train)

      %{
        root: root,
        packages: package_reports,
        global_errors: global_errors,
        errors: global_errors ++ flatten_package_errors(package_reports)
      }
    after
      unless Keyword.get(opts, :keep_output, false) do
        File.rm_rf(build_root)
      end
    end
  end

  defp prepare_build_root!(build_root) do
    File.rm_rf!(build_root)
    File.mkdir_p!(build_root)
    File.write!(Path.join(build_root, @build_marker), "")
  end

  defp flatten_package_errors(package_reports) do
    Enum.flat_map(package_reports, fn package ->
      Enum.map(package.errors, &"#{package.app}: #{&1}")
    end)
  end

  defp check_package(ctx, spec) do
    package_path = Path.expand(spec.path, ctx.root)
    entry = Map.fetch!(ctx.configs, spec.app)

    case entry.publish do
      {:ok, config} ->
        report_for(ctx, spec, entry, config, package_path)

      {:error, reason} ->
        base_report(spec, ctx, nil, [], [
          "could not load mix project: #{reason}"
        ])
    end
  end

  defp report_for(ctx, spec, entry, config, package_path) do
    # Walked once and shared. Expanding `:files` means walking every packaged
    # directory, which for the root package is the whole of `lib`, and the
    # metadata and provenance layers both need the same answer.
    file_set =
      package_file_set(package_path, Keyword.get(config, :package, []))

    {errors, warnings} =
      validate_metadata(spec, config, package_path, %{
        release_train: ctx.release_train,
        versions: ctx.versions,
        reloadable?: entry.reloadable?,
        file_set: file_set
      })

    {track_errors, track_warnings} =
      validate_tracked_files(ctx, package_path, file_set)

    {hex_errors, hex_warnings} =
      if ctx.metadata_only? do
        {[], []}
      else
        run_hex_build(ctx, spec, package_path, entry, config)
      end

    base_report(
      spec,
      ctx,
      config[:version],
      release_deps(config),
      errors ++ track_errors ++ hex_errors,
      warnings ++ track_warnings ++ hex_warnings
    )
  end

  defp base_report(spec, ctx, version, deps, errors, warnings \\ []) do
    %{
      app: spec.app,
      path: spec.path,
      class: spec.class,
      version: version,
      deps: deps,
      hex_build?: not ctx.metadata_only?,
      errors: errors,
      warnings: warnings
    }
  end

  # --- project loading -------------------------------------------------------

  # Each release-train project is loaded exactly once per environment and cached
  # for the whole run. Resolving a dependency's expected requirement used to
  # reload the dependency's project per dependent, which is quadratic in the
  # size of the train.
  defp load_configs(root, release_train) do
    Map.new(release_train, fn spec ->
      {spec.app, load_config_pair(root, spec)}
    end)
  end

  defp load_config_pair(root, %{app: :raxol, path: "."}) do
    if Path.expand(File.cwd!()) == root do
      # `:raxol` is already on the Mix project stack, so it cannot be reloaded
      # under HEX_BUILD. `reloadable?: false` records that, and the checks that
      # depend on a publish-shaped config skip rather than reporting a finding
      # they cannot substantiate. The tarball is still covered:
      # `require_hexpm_requirements/2` asserts every requirement in the built
      # `hex_metadata.config` resolves from hexpm, which a leaked path dep
      # cannot do.
      config = Mix.Project.config()
      %{source: root_source(config), publish: {:ok, config}, reloadable?: false}
    else
      load_reloadable(:raxol, root)
    end
  end

  defp load_config_pair(root, %{app: app, path: path}) do
    load_reloadable(app, Path.expand(path, root))
  end

  # The one config on the stack is whatever the ambient environment made it. If
  # HEX_BUILD is already set -- and the documented publish workflow is literally
  # `HEX_BUILD=1 mix hex.publish` -- then it is the publish config, and handing
  # it to the dependency-drop audit as the source side reintroduces exactly the
  # circularity the moduledoc says this design avoids: a dependency dropped by
  # an env conditional is absent from both sides, the two agree, and nothing is
  # reported. Refuse to be the source in that case so the audit degrades to a
  # visible warning instead of to silence.
  defp root_source(config) do
    case System.get_env("HEX_BUILD") do
      nil ->
        {:ok, config}

      _set ->
        {:error,
         "HEX_BUILD is set in the environment, so the root project config is " <>
           "already publish-shaped; rerun without it to audit dropped deps"}
    end
  end

  defp load_reloadable(app, path) do
    %{
      source: load_child_project(app, path, false),
      publish: load_child_project(app, path, true),
      reloadable?: true
    }
  end

  defp load_child_project(app, path, hex_build?) do
    with_hex_build_env(hex_build?, fn ->
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

  defp with_hex_build_env(false, fun) do
    old = System.get_env("HEX_BUILD")
    System.delete_env("HEX_BUILD")

    try do
      fun.()
    after
      if old, do: System.put_env("HEX_BUILD", old)
    end
  end

  defp with_hex_build_env(true, fun) do
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

  defp version_index(release_train, configs) do
    Map.new(release_train, fn spec ->
      {spec.app, config_version(Map.get(configs, spec.app))}
    end)
  end

  defp config_version(%{publish: {:ok, config}}), do: config[:version]
  defp config_version(_entry), do: nil

  # --- metadata --------------------------------------------------------------

  defp validate_metadata(spec, config, package_path, opts) do
    package = Keyword.get(config, :package, [])
    docs = Keyword.get(config, :docs, [])

    file_set =
      Map.get_lazy(opts, :file_set, fn ->
        package_file_set(package_path, package)
      end)

    errors =
      []
      |> project_errors(spec, config)
      |> package_errors(spec, package)
      |> content_errors(
        spec,
        package_path,
        package,
        docs,
        config[:version],
        file_set
      )

    {dep_errors, dep_warnings} = validate_dependency_constraints(config, opts)

    {Enum.reverse(errors) ++ dep_errors, dep_warnings}
  end

  defp project_errors(errors, spec, config) do
    errors
    |> require_equal(
      config[:app],
      spec.app,
      "project app must be #{inspect(spec.app)}"
    )
    |> require_present(config[:version], "project version is missing")
    |> require_version(config[:version])
    |> require_present(config[:description], "project description is missing")
  end

  defp package_errors(errors, spec, package) do
    errors
    |> require_keyword(package, "package metadata is missing")
    |> require_package_name(package, spec.app)
    |> require_nonempty_list(package[:files], "package files are missing")
    |> require_nonempty_list(
      package[:maintainers],
      "package maintainers are missing"
    )
    |> require_nonempty_list(package[:licenses], "package licenses are missing")
    |> require_links(package[:links], spec.class)
  end

  defp content_errors(
         errors,
         spec,
         package_path,
         package,
         docs,
         version,
         file_set
       ) do
    errors
    |> require_docs_source_ref(docs, spec.app, version)
    |> require_package_files(package_path, package[:files])
    |> require_readme(file_set)
    |> require_license(file_set)
    |> require_docs_extras(package_path, docs, file_set)
  end

  defp validate_dependency_constraints(config, opts) do
    selected_apps = MapSet.new(opts.release_train, & &1.app)

    config
    |> release_deps()
    |> Enum.reduce({[], []}, fn dep, acc ->
      check_dependency(dep, selected_apps, opts, acc)
    end)
    |> then(fn {errors, warnings} ->
      {Enum.reverse(errors), Enum.reverse(warnings)}
    end)
  end

  defp check_dependency(dep_entry, selected_apps, opts, {errors, warnings}) do
    case dependency_issue(dep_entry, selected_apps, opts) do
      :ok -> {errors, warnings}
      {:error, message} -> {[message | errors], warnings}
    end
  end

  defp dependency_issue({dep, requirement, dep_opts}, selected_apps, opts) do
    cond do
      Keyword.has_key?(dep_opts, :path) ->
        path_dep_issue(dep, opts)

      not MapSet.member?(selected_apps, dep) ->
        {:error, "dependency #{dep} is outside the selected release train"}

      true ->
        requirement_issue(dep, requirement, opts.versions)
    end
  end

  # A path dep survives only when the project could not be reloaded under
  # HEX_BUILD, which is exactly the `:raxol` root case. Reporting it there would
  # be a false positive about a config that was never meant to be publish-shaped.
  defp path_dep_issue(dep, %{reloadable?: true}),
    do: {:error, "dependency #{dep} still has a path option under HEX_BUILD"}

  defp path_dep_issue(_dep, _opts), do: :ok

  defp requirement_issue(dep, requirement, versions) do
    # No version index (the metadata-only public entry point) means the
    # requirement cannot be checked against anything. Skip rather than
    # inventing a finding.
    if Map.has_key?(versions, dep) do
      compare_requirement(dep, requirement, expected_requirement(dep, versions))
    else
      :ok
    end
  end

  defp compare_requirement(dep, _requirement, nil),
    do: {:error, "could not resolve the published version of #{dep}"}

  defp compare_requirement(_dep, requirement, requirement), do: :ok

  defp compare_requirement(dep, requirement, expected) do
    {:error,
     "dependency #{dep} uses #{inspect(requirement)}; expected #{inspect(expected)}"}
  end

  defp expected_requirement(app, versions) do
    versions
    |> Map.get(app)
    |> requirement_for_version()
  end

  defp requirement_for_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %Version{major: major, minor: minor}} -> "~> #{major}.#{minor}"
      :error -> nil
    end
  end

  defp requirement_for_version(_version), do: nil

  # --- provenance ------------------------------------------------------------

  defp tracked_index(root) do
    if System.find_executable("git") do
      read_tracked_index(root)
    else
      :unavailable
    end
  end

  defp read_tracked_index(root) do
    case System.cmd("git", ["ls-files", "-z"], cd: root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok,
         output
         |> String.split(<<0>>, trim: true)
         |> MapSet.new(&Path.expand(&1, root))}

      _other ->
        :unavailable
    end
  rescue
    _exception -> :unavailable
  end

  defp validate_tracked_files(
         %{tracked: :unavailable},
         _package_path,
         _file_set
       ) do
    {[],
     ["git is unavailable, so packaged files were not checked for provenance"]}
  end

  defp validate_tracked_files(
         %{tracked: {:ok, tracked}} = ctx,
         _package_path,
         file_set
       ) do
    untracked = reject_tracked(file_set, ctx.root, tracked)
    messages = untracked_messages(untracked)

    if ctx.allow_untracked?,
      do: {[], messages},
      else: {messages, []}
  end

  @doc """
  Lists the files a package would ship that git does not track, relative to
  `root`.

  `mix hex.build` packages the working tree, not the commit, so a green check
  on a dirty tree says nothing about what a publish actually ships. Returns
  `:unavailable` when git cannot answer, which the run reports as a warning
  rather than treating as a clean result.
  """
  @spec untracked_package_files(String.t(), String.t(), keyword()) ::
          {:ok, [String.t()]} | :unavailable
  def untracked_package_files(root, package_path, package) do
    case tracked_index(root) do
      :unavailable ->
        :unavailable

      {:ok, tracked} ->
        {:ok, untracked_in(root, package_path, package, tracked)}
    end
  end

  defp untracked_in(root, package_path, package, tracked) do
    package_path
    |> package_file_set(package)
    |> reject_tracked(root, tracked)
  end

  defp reject_tracked(file_set, root, tracked) do
    file_set
    |> Enum.reject(&MapSet.member?(tracked, &1))
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.sort()
  end

  defp untracked_messages([]), do: []

  defp untracked_messages(untracked) do
    {shown, rest} = Enum.split(untracked, @max_reported_untracked)

    messages =
      Enum.map(shown, &"packaged file #{&1} is not tracked by git")

    case rest do
      [] ->
        messages

      more ->
        messages ++ ["and #{length(more)} more untracked packaged file(s)"]
    end
  end

  # --- catalog and order -----------------------------------------------------

  @doc """
  Checks that every project under `packages/` is classified in this module.

  A package that exists on disk but appears in neither train is `unclassified`;
  a classified package with no project on disk is `missing`. Either one means
  the release train no longer describes the repo.
  """
  @spec validate_catalog(String.t()) :: [String.t()]
  def validate_catalog(root) do
    expected =
      @all_packages
      |> Enum.reject(&(&1.app == :raxol))
      |> MapSet.new(&Atom.to_string(&1.app))

    {discovered, unreadable} = discover_package_names(root)

    cond do
      unreadable != [] ->
        [
          "could not read the app name from: #{Enum.join(Enum.sort(unreadable), ", ")}"
        ]

      MapSet.equal?(expected, discovered) ->
        []

      true ->
        unclassified = MapSet.difference(discovered, expected)
        missing = MapSet.difference(expected, discovered)

        [
          "package catalog mismatch: unclassified=#{format_name_set(unclassified)} " <>
            "missing=#{format_name_set(missing)}"
        ]
    end
  end

  # Names stay strings on purpose: a newly added package under `packages/` is
  # exactly the case this check exists to catch, and its app atom need not
  # exist in this VM yet.
  defp discover_package_names(root) do
    root
    |> Path.join("packages/*/mix.exs")
    |> Path.wildcard()
    |> Enum.reduce({MapSet.new(), []}, fn mix_exs, {names, unreadable} ->
      case read_app_name(mix_exs) do
        {:ok, name} ->
          {MapSet.put(names, name), unreadable}

        :error ->
          {names, [Path.relative_to(mix_exs, root) | unreadable]}
      end
    end)
  end

  # Anchored on `def project` rather than on the first `app:` in the file. A
  # `releases:` block, an `application/0` entry or an `app:` inside a
  # `@moduledoc` example all match the bare pattern, and the resulting mismatch
  # surfaces as a confusing catalog error about a package name nobody wrote.
  defp read_app_name(mix_exs) do
    with {:ok, source} <- File.read(mix_exs),
         [_, body] <- Regex.run(~r/def\s+project(?:\(\))?\s+do(.*)/s, source),
         [_, name] <- Regex.run(~r/^\s*app:\s*:(\w+)/m, body) do
      {:ok, name}
    else
      _other -> :error
    end
  end

  @doc """
  Checks that no package is published before a dependency it needs.

  `package_reports` need only carry `:app` and `:deps`; the publish order is
  the position of each package in `release_train`.
  """
  @spec validate_order([map()], [package_spec()]) :: [String.t()]
  def validate_order(package_reports, release_train) do
    index =
      release_train
      |> Enum.with_index()
      |> Map.new(fn {spec, idx} -> {spec.app, idx} end)

    Enum.flat_map(package_reports, &order_errors(&1, index))
  end

  defp order_errors(report, index) do
    case Map.fetch(index, report.app) do
      {:ok, current} ->
        report
        |> Map.get(:deps, [])
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(Map.get(index, &1, current) > current))
        |> Enum.map(fn dep ->
          "#{report.app}: release order places dependency #{dep} after dependent"
        end)

      :error ->
        []
    end
  end

  # --- hex build -------------------------------------------------------------

  defp run_hex_build(ctx, spec, package_path, entry, config) do
    output_dir = Path.join(ctx.build_root, Atom.to_string(spec.app))
    File.rm_rf!(output_dir)

    case System.find_executable("mix") do
      nil ->
        {["mix executable was not found"], []}

      mix ->
        build_and_validate(mix, output_dir, package_path, spec, entry, config)
    end
  end

  defp build_and_validate(mix, output_dir, package_path, spec, entry, config) do
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
        |> validate_hex_metadata(spec, entry, config)
      else
        {["hex.build failed with exit #{status}: #{trim_output(output)}"], []}
      end
    after
      File.rm_rf(output_dir)
    end
  end

  defp read_hex_metadata(output_dir) do
    metadata_path = Path.join(output_dir, "hex_metadata.config")

    case :file.consult(String.to_charlist(metadata_path)) do
      {:ok, metadata} -> {:ok, metadata}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_hex_metadata({:error, reason}, _spec, _entry, _config) do
    {["could not read hex_metadata.config: #{inspect(reason)}"], []}
  end

  defp validate_hex_metadata({:ok, metadata}, spec, entry, config) do
    requirements = metadata_requirements(metadata)
    requirement_names = MapSet.new(requirements, & &1.name)

    errors =
      []
      |> require_equal(
        metadata_string(metadata, "app"),
        Atom.to_string(spec.app),
        "hex metadata app must match"
      )
      |> require_equal(
        metadata_string(metadata, "name"),
        Atom.to_string(spec.app),
        "hex metadata name must match"
      )
      |> require_equal(
        metadata_string(metadata, "version"),
        config[:version],
        "hex metadata version must match"
      )
      |> require_hexpm_requirements(requirements)

    {dep_errors, dep_warnings} = source_dep_audit(entry, requirement_names)

    {Enum.reverse(errors) ++ dep_errors, dep_warnings}
  end

  defp source_dep_audit(%{source: {:ok, config}}, requirement_names),
    do: audit_release_deps(config, requirement_names)

  defp source_dep_audit(%{source: {:error, reason}}, _requirement_names),
    do:
      {[],
       ["source config unavailable, dependency drop not audited: #{reason}"]}

  @doc """
  Compares the dependencies a project declares against the ones it publishes.

  Audit the *source* config, never the publish config. Auditing the publish
  config is circular: a dependency dropped by an env conditional in `mix.exs`
  is missing from the publish config and from the tarball, so the two agree and
  nothing is reported.

  A public-train dependency that fails to reach the tarball is an error. A
  pre-alpha one is an intentional drop, but it still changes what Hex consumers
  get, so it is surfaced as a warning rather than as silence.
  """
  @spec audit_release_deps(keyword(), MapSet.t(String.t())) ::
          {[String.t()], [String.t()]}
  def audit_release_deps(source_config, requirement_names) do
    source_config
    |> release_deps()
    |> Enum.reduce({[], []}, fn {dep, _requirement, _opts}, acc ->
      collect_dep_audit(dep, requirement_names, acc)
    end)
    |> then(fn {errors, warnings} ->
      {Enum.reverse(errors), Enum.reverse(warnings)}
    end)
  end

  defp collect_dep_audit(dep, requirement_names, {errors, warnings}) do
    cond do
      MapSet.member?(requirement_names, Atom.to_string(dep)) ->
        {errors, warnings}

      MapSet.member?(@public_apps, dep) ->
        {["published tarball omits release dependency #{dep}" | errors],
         warnings}

      true ->
        {errors, [dropped_dep_warning(dep) | warnings]}
    end
  end

  defp dropped_dep_warning(dep) do
    "release dependency #{dep} is dropped from the published tarball; " <>
      "it is not on the public Hex train"
  end

  defp metadata_string(metadata, key) do
    metadata
    |> metadata_value(key)
    |> to_string_value()
  end

  # Requirement names stay strings: they come out of a generated file and are
  # only ever compared, never used as atoms.
  defp metadata_requirements(metadata) do
    metadata
    |> metadata_value("requirements")
    |> List.wrap()
    |> Enum.map(fn requirement ->
      %{
        name: metadata_string(requirement, "name"),
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

  # --- metadata predicates ---------------------------------------------------

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

  # Two accepted spellings, both pinned to the version. `vX.Y.Z` is the root
  # `raxol` tag, correct for the packages on that version line. The independent
  # 0.x packages cannot use it: `v0.2.0` is a root tag pointing at raxol from
  # 2025, so a bare ref sends every source link in their published docs to
  # unrelated code. They tag `<package>-vX.Y.Z` instead.
  defp require_docs_source_ref(errors, docs, _app, _version)
       when docs in [nil, []],
       do: errors

  defp require_docs_source_ref(errors, docs, app, version) do
    accepted = ["v#{version}", "#{app}-v#{version}"]

    if docs[:source_ref] in accepted do
      errors
    else
      [
        "docs source_ref must match version, as one of " <>
          "#{inspect(accepted)}: got #{inspect(docs[:source_ref])}"
        | errors
      ]
    end
  end

  defp require_package_files(errors, package_path, files) when is_list(files) do
    files
    |> Enum.filter(&(package_file_matches(package_path, &1) == []))
    |> Enum.reduce(errors, fn file, acc ->
      ["package file entry #{inspect(file)} does not match anything" | acc]
    end)
  end

  defp require_package_files(errors, _package_path, _files), do: errors

  defp require_readme(errors, file_set) do
    if basename_present?(file_set, "README"),
      do: errors,
      else: ["package files do not include a README" | errors]
  end

  defp require_license(errors, file_set) do
    if basename_present?(file_set, "LICENSE"),
      do: errors,
      else: ["package files do not include a LICENSE" | errors]
  end

  defp require_docs_extras(errors, _package_path, docs, _file_set)
       when docs in [nil, []],
       do: errors

  defp require_docs_extras(errors, package_path, docs, file_set) do
    docs
    |> Keyword.get(:extras, [])
    |> Enum.map(&doc_extra_path/1)
    |> Enum.reduce(errors, fn extra, acc ->
      abs = Path.expand(extra, package_path)

      cond do
        not File.exists?(abs) ->
          ["docs extra #{inspect(extra)} does not exist" | acc]

        not MapSet.member?(file_set, abs) ->
          [
            "docs extra #{inspect(extra)} is not included in package files"
            | acc
          ]

        true ->
          acc
      end
    end)
  end

  # ex_doc accepts three spellings, and the keyword-literal one
  # (`extras: ["README.md": [title: "x"]]`) yields an atom key. `Path.expand/2`
  # raises on an atom, which would take the whole run down rather than report a
  # finding, so normalise to a string here.
  defp doc_extra_path({path, _opts}), do: doc_extra_path(path)
  defp doc_extra_path(path) when is_atom(path), do: Atom.to_string(path)
  defp doc_extra_path(path), do: path

  defp basename_present?(file_set, prefix) do
    Enum.any?(file_set, fn path ->
      path |> Path.basename() |> String.starts_with?(prefix)
    end)
  end

  # --- file globbing ---------------------------------------------------------

  # The regular files a `mix hex.build` of this package would ship: every
  # `:files` entry expanded, directories walked, then `:exclude_patterns`
  # applied to the package-relative path exactly as Hex applies them.
  defp package_file_set(package_path, package) do
    excludes = Keyword.get(package, :exclude_patterns, [])

    package
    |> Keyword.get(:files, [])
    |> List.wrap()
    |> Enum.flat_map(&package_file_matches(package_path, &1))
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&excluded?(&1, package_path, excludes))
    |> MapSet.new()
  end

  defp excluded?(path, package_path, excludes) do
    relative = Path.relative_to(path, package_path)
    Enum.any?(excludes, &Regex.match?(&1, relative))
  end

  # `match_dot: true` on both walks, because that is what `mix hex.build` does.
  # Without it the walk cannot see a dotfile under a packaged directory, and a
  # dotfile is the single likeliest thing to be untracked and unpublishable:
  # `.env`, `.env.*` and `.secrets` are all gitignored here, so they are
  # untracked by construction. A provenance layer blind to exactly the files it
  # exists to catch reports a clean tree while the tarball carries the secret.
  defp package_file_matches(package_path, file) do
    path = Path.expand(file, package_path)

    cond do
      wildcard?(file) ->
        Path.wildcard(path, match_dot: true)

      File.dir?(path) ->
        [path | Path.wildcard(Path.join(path, "**/*"), match_dot: true)]

      File.exists?(path) ->
        [path]

      true ->
        []
    end
    |> Enum.map(&Path.expand/1)
  end

  defp wildcard?(file), do: String.contains?(file, ["*", "?", "["])

  # --- misc ------------------------------------------------------------------

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

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp trim_output(output) do
    output
    |> String.trim()
    |> String.split("\n")
    |> Enum.take(-20)
    |> Enum.join("\n")
  end

  defp format_name_set(names) do
    names
    |> Enum.sort()
    |> Enum.join(", ")
    |> case do
      "" -> "none"
      joined -> joined
    end
  end
end
