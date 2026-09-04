defmodule Mix.Tasks.Raxol.Release.Check do
  @moduledoc """
  Validates the Raxol Hex package release train.

      mix raxol.release.check
      mix raxol.release.check --metadata-only
      mix raxol.release.check --only raxol_core,raxol_sensor
      mix raxol.release.check --all

  By default this checks the public Hex train only. `--all` includes pre-alpha
  projects that carry package metadata but are not part of the public train yet.

  ## Options

    * `--all` -- include pre-alpha packages in the train
    * `--metadata-only` -- skip `mix hex.build`, validate metadata only
    * `--only NAMES` -- comma-separated package names
    * `--keep-output` -- leave the unpacked tarballs on disk
    * `--allow-untracked` -- report packaged-but-untracked files as warnings
      instead of errors. For local work with uncommitted files under a packaged
      directory; never pass it in CI, where an untracked packaged file means the
      tarball would carry content that is not in the repository.
  """

  use Mix.Task

  alias Raxol.Release.PackageCheck

  @shortdoc "Validate the Hex package release train"
  @switches [
    all: :boolean,
    metadata_only: :boolean,
    only: :string,
    keep_output: :boolean,
    allow_untracked: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [], []} ->
        opts
        |> check_options()
        |> run_check()

      {_opts, _args, invalid} ->
        Mix.raise("invalid option(s): #{inspect(invalid)}")
    end
  end

  defp check_options(opts) do
    [
      include_pre_alpha: Keyword.get(opts, :all, false),
      metadata_only: Keyword.get(opts, :metadata_only, false),
      only: parse_only(opts[:only]),
      keep_output: Keyword.get(opts, :keep_output, false),
      allow_untracked: Keyword.get(opts, :allow_untracked, false)
    ]
  end

  defp parse_only(nil), do: []

  defp parse_only(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp run_check(opts) do
    case PackageCheck.run(opts) do
      {:ok, report} ->
        print_report(report)
        Mix.shell().info("package release check passed")

      {:error, report} ->
        print_report(report)
        Mix.raise("package release check failed")
    end
  end

  defp print_report(report) do
    Mix.shell().info(
      "package release check: #{length(report.packages)} package(s)"
    )

    Enum.each(report.packages, &print_package/1)

    Enum.each(report.global_errors, fn error ->
      Mix.shell().error("[error] #{error}")
    end)
  end

  defp print_package(package) do
    if package.errors == [] do
      suffix =
        if package.hex_build?, do: "metadata + hex.build", else: "metadata"

      Mix.shell().info("[ok] #{package.app} #{package.version} #{suffix}")
    else
      Mix.shell().error("[fail] #{package.app} #{package.version || "unknown"}")
    end

    Enum.each(
      package.warnings,
      &Mix.shell().info("[warn] #{package.app}: #{&1}")
    )

    Enum.each(
      package.errors,
      &Mix.shell().error("[error] #{package.app}: #{&1}")
    )
  end
end
