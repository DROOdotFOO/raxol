defmodule Mix.Tasks.Raxol.Scoreboard do
  @shortdoc "Deterministic performance counters as one JSON record"
  @moduledoc """
  Collect the scoreboard metrics (see `Raxol.Scoreboard`) and print them.

      $ MIX_ENV=test mix raxol.scoreboard
      $ MIX_ENV=test mix raxol.scoreboard --output scoreboard.json \\
          --include buffer.json --commit "$GITHUB_SHA"

  Options:

    * `--output PATH` -- write the record as JSON.
    * `--include PATH` -- merge the `"metrics"` object of another JSON file,
      such as the one `bench/core/buffer_gate.exs --json PATH` writes. May be
      given more than once.
    * `--commit SHA` -- the commit the record describes (default: `git
      rev-parse HEAD`).
    * `--bless` -- rewrite `priv/scoreboard/screens.refs` from the current
      scenario screens before collecting. Use it only when a scenario is
      meant to draw something different, and commit the file with the change:
      a different screen is a different benchmark.
    * `--no-agent-tasks` -- skip the agent tasks (`Raxol.Scoreboard.AgentTasks`).
      `scripts/scoreboard-backfill.sh` passes it: the commits it measures
      predate the derived tools the tasks call.

  The application is configured but not started: the scenarios call the
  render pipeline directly, and a started application would add processes
  and user preferences that have nothing to do with the measurement. The
  agent tasks (`Raxol.Scoreboard.AgentTasks`) then start the runtime they
  need under their own supervisor and stop it. A task path that does not
  reach its goal is printed and left out of the record, so the comparison
  shows its metrics as not measured.
  """

  use Mix.Task

  @switches [
    output: :string,
    include: :keep,
    commit: :string,
    bless: :boolean,
    agent_tasks: :boolean
  ]

  @impl true
  def run(args) do
    opts = parse_args!(args)

    Mix.Task.run("app.config")
    # The agent tasks run real sessions; their info and debug logs (on in
    # the test environment) would bury the record.
    Logger.configure(level: :warning)

    if opts[:bless], do: bless()

    included =
      opts
      |> Keyword.get_values(:include)
      |> Enum.reduce(%{}, fn path, acc -> Map.merge(acc, read_include(path)) end)

    metrics =
      Raxol.Scoreboard.collect()
      |> Map.merge(agent_metrics(opts))
      |> Map.merge(included)

    record = Raxol.Scoreboard.record(metrics, opts[:commit] || head_commit())

    print(record)

    case opts[:output] do
      nil -> :ok
      path -> File.write!(path, Jason.encode!(record, pretty: true))
    end
  end

  defp parse_args!(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        opts

      {_opts, rest, invalid} ->
        Mix.raise(
          "raxol.scoreboard: unexpected arguments #{inspect(rest ++ invalid)}"
        )
    end
  end

  defp agent_metrics(opts) do
    if Keyword.get(opts, :agent_tasks, true) do
      {metrics, failures} = Raxol.Scoreboard.AgentTasks.collect()
      Enum.each(failures, &Mix.shell().error("raxol.scoreboard: " <> &1))
      metrics
    else
      %{}
    end
  end

  defp bless do
    :ok = Raxol.Scoreboard.bless_screens()
    Mix.shell().info("raxol.scoreboard: rewrote priv/scoreboard/screens.refs")
  end

  defp read_include(path) do
    case path |> File.read!() |> Jason.decode!() do
      %{"metrics" => metrics} when is_map(metrics) ->
        metrics

      other ->
        Mix.raise(
          "raxol.scoreboard: #{path} has no \"metrics\" object: #{inspect(other)}"
        )
    end
  end

  defp head_commit do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} ->
        String.trim(sha)

      {out, status} ->
        Mix.raise(
          "raxol.scoreboard: git rev-parse HEAD exited #{status}: #{out}"
        )
    end
  end

  defp print(record) do
    labels = Map.new(Raxol.Scoreboard.definitions(), &{&1["id"], &1})

    record["metrics"]
    |> Enum.sort()
    |> Enum.each(fn {id, value} ->
      unit = get_in(labels, [id, "unit"])

      Mix.shell().info(
        String.pad_trailing(id, 40) <>
          String.pad_leading(format(value), 14) <> " " <> unit
      )
    end)

    toolchain = record["toolchain"]

    Mix.shell().info(
      "commit #{String.slice(record["commit"], 0, 12)}, Elixir #{toolchain["elixir"]}, " <>
        "OTP #{toolchain["otp"]}, #{toolchain["system_arch"]}"
    )
  end

  defp format(value) when is_integer(value), do: Integer.to_string(value)

  defp format(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)
end
