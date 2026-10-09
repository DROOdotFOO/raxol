defmodule Mix.Tasks.Raxol.Broker.Gen.Tools do
  @moduledoc """
  Generates `Raxol.Broker.Tools.<Family>` modules from
  `priv/robinhood/tools_list.json` into `lib/raxol/broker/tools/generated/`.

      mix raxol.broker.gen.tools          # write, removing stale files
      mix raxol.broker.gen.tools --check  # fail if anything would change

  Run from `packages/raxol_broker`. Idempotent: a second run changes nothing.
  """

  use Mix.Task

  alias Raxol.Broker.Tools.Generator

  @shortdoc "Generates typed read-tool modules from the tool capture"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [check: :boolean])

    if rest != [] or invalid != [],
      do: Mix.raise("usage: mix raxol.broker.gen.tools [--check]")

    Mix.Task.run("compile")
    files = Generator.render()
    stale = stale_files(files)
    changed = for {path, contents} <- files, File.read(path) != {:ok, contents}, do: path

    if opts[:check], do: check(changed ++ stale), else: write(files, changed, stale)
  end

  defp check([]), do: Mix.shell().info("generated tools are up to date")

  defp check(outdated),
    do: Mix.raise("generated tools are out of date: #{Enum.join(outdated, ", ")}")

  defp write(files, changed, stale) do
    File.mkdir_p!(Generator.dir())
    Enum.each(stale, &File.rm!/1)
    Enum.each(changed, &File.write!(&1, files[&1]))
    Mix.shell().info("#{length(changed)} written, #{length(stale)} removed")
  end

  defp stale_files(files) do
    Path.join(Generator.dir(), "*.ex") |> Path.wildcard() |> Enum.reject(&Map.has_key?(files, &1))
  end
end
