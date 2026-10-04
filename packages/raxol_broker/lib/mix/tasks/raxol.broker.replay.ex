defmodule Mix.Tasks.Raxol.Broker.Replay do
  @moduledoc """
  Prints the broker journal's decision trace for one day.

      mix raxol.broker.replay --date 2026-10-02 [--journal PATH]

  For every decision group opened that day (UTC), in journal order: the
  intent, the policy context, each rule's verdict for each policy pass, the
  review response, the order response, and the outcome. Fills recorded that
  day follow.

  The journal defaults to `~/.raxol/broker/journal` (`$RAXOL_BROKER_JOURNAL`).
  It is read without taking the writer lock, so this works while the broker
  runs. A journal whose hash chain does not verify is refused, with the
  offset of the first broken record.
  """

  use Mix.Task

  alias Raxol.Broker.Journal
  alias Raxol.Broker.Journal.Replay

  @shortdoc "Prints the broker decision trace for a day"
  @switches [date: :string, journal: :string]
  @usage "usage: mix raxol.broker.replay --date YYYY-MM-DD [--journal PATH]"

  @impl Mix.Task
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    if rest != [] or invalid != [], do: Mix.raise(@usage)

    date = parse_date(Keyword.get(opts, :date))

    path =
      Journal.path(path: Keyword.get(opts, :journal)) ||
        Mix.raise("no journal path: set --journal or $HOME")

    path
    |> Replay.run(date)
    |> print!(path)
  end

  defp print!({:ok, lines}, _path), do: Enum.each(lines, fn line -> Mix.shell().info(line) end)

  defp print!({:error, {:broken, offset}}, path),
    do: Mix.raise("journal #{path} is damaged: hash chain broken at offset #{offset}")

  defp print!({:error, {:no_journal, _}}, path), do: Mix.raise("no broker journal at #{path}")

  defp print!({:error, :unchained}, path),
    do: Mix.raise("#{path} is not a hash-chained broker journal")

  defp print!({:error, reason}, path),
    do: Mix.raise("cannot read journal #{path}: #{inspect(reason)}")

  defp parse_date(nil), do: Mix.raise(@usage)

  defp parse_date(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> Mix.raise("--date must be YYYY-MM-DD, got #{inspect(value)}")
    end
  end
end
