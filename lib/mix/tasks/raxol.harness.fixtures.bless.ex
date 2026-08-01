defmodule Mix.Tasks.Raxol.Harness.Fixtures.Bless do
  @shortdoc "Regenerate harness fixture <name>.blocks.json snapshots"

  @moduledoc """
  Runs a projector over every golden harness fixture session and writes
  `<name>.blocks.json` beside it — the regenerable snapshot half of the
  fixture toolchain (06-projection §1.2).

      mix raxol.harness.fixtures.bless
      mix raxol.harness.fixtures.bless --check
      mix raxol.harness.fixtures.bless --projector MyApp.Projector
      mix raxol.harness.fixtures.bless --dir test/fixtures/harness/sessions simple-chat multi-tool-turn

  `--check` writes nothing: it diffs each on-disk snapshot against a
  fresh projection and fails (non-zero exit) when any snapshot is stale
  or missing — the CI half of the drift tripwire.

  Defaults to `Raxol.Harness.Fixture.Projectors.Identity`, the trivial
  placeholder ahead of the real journal-fold projection (roadmap T7).
  Adversarial fixtures are skipped (see `Raxol.Harness.Fixture.Bless`).

  Mirrors the RATE `--gen` precedent (`mix raxol.rate --gen`) at the
  fixture/session level rather than the pixel-hash level: snapshot churn
  in a PR that didn't mean to touch the projection is the review
  tripwire.
  """

  use Mix.Task

  alias Raxol.Harness.Fixture.Bless

  @switches [projector: :string, dir: :string, check: :boolean]

  @impl Mix.Task
  def run(args) do
    {opts, names, _invalid} = OptionParser.parse(args, switches: @switches)

    projector = resolve_projector(opts[:projector])
    dir = opts[:dir] || Bless.default_dir()
    check? = opts[:check] || false

    case Bless.run(dir: dir, projector: projector, names: names, check: check?) do
      {:ok, results} ->
        Enum.each(results, &report/1)

      {:error, {:drift, drifted}} ->
        Mix.raise(
          "harness fixture snapshot drift: #{Enum.join(drifted, ", ")} — " <>
            "run `mix raxol.harness.fixtures.bless` and review the diff"
        )

      {:error, reason} ->
        Mix.raise("harness fixture bless failed: #{inspect(reason)}")
    end
  end

  defp resolve_projector(nil), do: Raxol.Harness.Fixture.Projectors.Identity

  defp resolve_projector(name) do
    module = Module.concat([name])

    case Code.ensure_loaded(module) do
      {:module, ^module} ->
        module

      {:error, reason} ->
        Mix.raise("cannot load projector #{name}: #{inspect(reason)}")
    end
  end

  defp report(%{status: :skipped, name: name}) do
    Mix.shell().info("skip    #{name} (not a golden fixture)")
  end

  defp report(%{status: :current, name: name, blocks_path: blocks_path}) do
    Mix.shell().info("current #{name} (#{blocks_path})")
  end

  defp report(%{
         status: :written,
         name: name,
         blocks_path: blocks_path,
         count: count
       }) do
    Mix.shell().info("bless   #{name} -> #{blocks_path} (#{count} entries)")
  end
end
