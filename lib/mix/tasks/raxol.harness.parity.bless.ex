defmodule Mix.Tasks.Raxol.Harness.Parity.Bless do
  @shortdoc "Regenerate the multi-surface parity artifacts"

  @moduledoc """
  Renders every harness fixture through all four surface projections
  (`:cells`, `:liveview_dom`, `:ssh_ansi`, `:structured_json`), writing one
  reviewable artifact per fixture x surface under
  `test/fixtures/harness/parity/` plus the hash refs file
  `priv/harness/parity.refs`.

      mix raxol.harness.parity.bless
      mix raxol.harness.parity.bless --check
      mix raxol.harness.parity.bless simple-chat unicode-heavy

  `--check` writes nothing: it re-renders every pair and fails (non-zero
  exit) on any artifact or refs drift -- the CI half of the tripwire.

  Sits beside the two existing bless tasks rather than replacing either:
  `mix raxol.harness.fixtures.bless` snapshots the journal-fold projection,
  `mix raxol.harness.goldens.bless` snapshots the raw degradation-ladder
  bytes of ONE surface across three render modes, and this one snapshots ONE
  render across FOUR surfaces -- and additionally asserts the surfaces agree
  with each other (`Raxol.Harness.Surface.Parity.parity/1`, exercised by
  `test/harness/surface_parity_test.exs`).
  """

  use Mix.Task

  alias Raxol.Harness.Surface.Parity

  @switches [check: :boolean]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, names, _invalid} = OptionParser.parse(args, switches: @switches)
    check? = opts[:check] || false

    case Parity.run(check: check?, names: names) do
      {:ok, results} ->
        Enum.each(results, &report/1)
        Mix.shell().info(summary(results, check?))

      {:error, {:drift, drifted}} ->
        Enum.each(drifted, &Mix.shell().info("drift   #{&1}"))

        Mix.raise(
          "harness parity drift: #{Enum.join(drifted, ", ")} -- run " <>
            "`mix raxol.harness.parity.bless` and review the diff"
        )
    end
  end

  defp summary(results, check?) do
    verb = if check?, do: "verified", else: "blessed"

    fixtures = results |> Enum.map(& &1.fixture) |> Enum.uniq() |> length()

    "#{verb} #{length(results)} artifacts " <>
      "(#{fixtures} fixtures x #{length(Parity.surfaces())} surfaces)"
  end

  defp report(%{status: :current, name: name}),
    do: Mix.shell().info("current #{name}")

  defp report(%{status: :created, name: name, path: path, bytes: bytes}),
    do:
      Mix.shell().info("bless (new)       #{name} -> #{path} (#{bytes} bytes)")

  defp report(%{
         status: :overwritten,
         name: name,
         path: path,
         bytes: bytes,
         old_bytes: old
       }) do
    Mix.shell().info(
      "bless (overwrote) #{name} -> #{path} (was #{old} bytes, now #{bytes} bytes)"
    )
  end
end
