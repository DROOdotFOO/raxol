defmodule Mix.Tasks.Raxol.Fate do
  @shortdoc "Run the golden render harness (FATE-style)"
  @moduledoc """
  Render the fixture corpus and compare each hash against `priv/fate/golden.refs`.

      $ mix raxol.fate          # compare, exit non-zero on any mismatch
      $ mix raxol.fate --gen    # regenerate the references

  Hashes are architecture-independent; a mismatch on one arch and not another
  points at a real render determinism bug.
  """

  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    if "--gen" in args do
      Raxol.FATE.generate()
      report(Raxol.FATE.run(), :generated)
    else
      case Raxol.FATE.verify() do
        {:ok, results} ->
          report(results, :ok)

        {:error, %{mismatches: mismatches, missing: missing}} ->
          report(Raxol.FATE.run(), :ok)
          print_failures(mismatches, missing)

          Mix.raise(
            "raxol.fate: #{length(mismatches)} mismatch(es), #{length(missing)} missing"
          )
      end
    end
  end

  defp report(results, mode) do
    label = if mode == :generated, do: "GEN", else: "OK "

    Enum.each(results, fn {name, hash} ->
      Mix.shell().info(
        "  #{label}  #{String.pad_trailing(name, 20)} #{String.slice(hash, 0, 12)}"
      )
    end)

    Mix.shell().info("#{length(results)} fixtures")
  end

  defp print_failures(mismatches, missing) do
    Enum.each(mismatches, fn %{name: name, expected: exp, actual: act} ->
      Mix.shell().error(
        "  FAIL #{name}: expected #{String.slice(exp, 0, 12)}, got #{String.slice(act, 0, 12)}"
      )
    end)

    Enum.each(missing, fn name ->
      Mix.shell().error("  MISS #{name}: no reference (run --gen)")
    end)
  end
end
