defmodule Raxol.Harness.Fixture.Bless do
  @moduledoc """
  Regenerates `<name>.blocks.json` snapshots by running a pluggable
  projector over each golden fixture session in a directory.

  Mirrors the RATE precedent (`priv/rate/golden.refs` +
  `mix raxol.rate --gen` + `assert RATE.run() == RATE.run()`,
  06-projection §7 open question 6) at the fixture/session level rather
  than the pixel-hash level. Adversarial fixtures are skipped — they are
  authored to be semantically pathological for a projection consumer, not
  blessed as golden output.

  Two modes: the default writes snapshots; `check: true` diffs the
  on-disk snapshot against a fresh projection without writing anything
  and reports `{:error, {:drift, names}}` when any golden fixture's
  snapshot is stale or missing — the CI-facing half of the drift
  tripwire.
  """

  alias Raxol.Harness.Fixture
  alias Raxol.Harness.Fixture.Session

  @default_dir "test/fixtures/harness/sessions"
  @blocks_schema "harness-fixture-blocks/1"

  @spec default_dir() :: Path.t()
  def default_dir, do: @default_dir

  @type status :: :written | :current | :drift | :skipped

  @type result :: %{
          name: String.t(),
          path: Path.t(),
          blocks_path: Path.t() | nil,
          count: non_neg_integer() | nil,
          status: status()
        }

  @doc """
  Run the bless pass.

  Options:
    * `:dir` — directory containing `*.jsonl` fixtures (default `#{@default_dir}`)
    * `:projector` — module implementing `Raxol.Harness.Fixture.Projector` (default `Raxol.Harness.Fixture.Projectors.Identity`)
    * `:names` — explicit fixture base names (without `.jsonl`) to bless; defaults to every fixture found in `:dir`
    * `:check` — when `true`, write nothing; compare each on-disk snapshot to a fresh projection and return `{:error, {:drift, names}}` if any differ or are missing
  """
  @spec run(keyword()) :: {:ok, [result()]} | {:error, term()}
  def run(opts \\ []) do
    dir = Keyword.get(opts, :dir, @default_dir)
    check? = Keyword.get(opts, :check, false)

    projector =
      Keyword.get(opts, :projector, Raxol.Harness.Fixture.Projectors.Identity)

    names = Keyword.get(opts, :names, [])

    with {:ok, paths} <- session_paths(dir, names),
         {:ok, results} <- bless_all(paths, projector, check?) do
      drifted = for %{status: :drift, name: name} <- results, do: name

      if drifted == [] do
        {:ok, results}
      else
        {:error, {:drift, drifted}}
      end
    end
  end

  defp bless_all(paths, projector, check?) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case bless_one(path, projector, check?) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = err -> err
    end
  end

  defp session_paths(dir, []) do
    case File.ls(dir) do
      {:ok, entries} ->
        paths =
          entries
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.sort()
          |> Enum.map(&Path.join(dir, &1))

        {:ok, paths}

      {:error, reason} ->
        {:error, {:dir_error, dir, reason}}
    end
  end

  defp session_paths(dir, names) do
    {:ok, Enum.map(names, &Path.join(dir, &1 <> ".jsonl"))}
  end

  defp bless_one(path, projector, check?) do
    case Fixture.load(path) do
      {:ok, %Session{} = session} ->
        bless_session(session, path, projector, check?)

      {:error, reason} ->
        {:error, {path, reason}}
    end
  end

  defp bless_session(session, path, projector, check?) do
    name = Path.basename(path, ".jsonl")

    if Session.golden?(session) do
      blocks = projector.project(session)
      blocks_path = Path.rootname(path) <> ".blocks.json"

      json =
        Jason.encode!(
          %{
            schema: @blocks_schema,
            projector: inspect(projector),
            blocks: blocks
          },
          pretty: true
        ) <> "\n"

      status = write_or_check(blocks_path, json, check?)

      {:ok,
       %{
         name: name,
         path: path,
         blocks_path: blocks_path,
         count: block_count(blocks),
         status: status
       }}
    else
      {:ok,
       %{name: name, path: path, blocks_path: nil, count: 0, status: :skipped}}
    end
  end

  defp write_or_check(blocks_path, json, false) do
    File.write!(blocks_path, json)
    :written
  end

  defp write_or_check(blocks_path, json, true) do
    case File.read(blocks_path) do
      {:ok, ^json} -> :current
      _missing_or_stale -> :drift
    end
  end

  # A projector's `project/1` return is `term()` (the real T7 projection
  # shape isn't decided yet, per Raxol.Harness.Fixture.Projector) — most
  # naturally a list of blocks, but not guaranteed. Report a count when
  # it's countable, `nil` otherwise, rather than assuming `length/1`.
  defp block_count(blocks) when is_list(blocks), do: length(blocks)
  defp block_count(blocks) when is_map(blocks), do: map_size(blocks)
  defp block_count(_blocks), do: nil
end
