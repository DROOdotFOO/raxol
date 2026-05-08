defmodule Raxol.Symphony.Evidence.Recording do
  @moduledoc """
  Surfaces asciicast (`*.cast`) artifacts produced during a Symphony run.

  Scans `<workspace>/.raxol_symphony/` (override via `:scan_dir`) for files
  matching `*.cast`, `*.asciinema`, or any extension supplied via
  `:extensions`. Returns metadata only -- the file is not parsed.

  Reading actual recordings (for replay) is the consumer's job; this
  collector exists so the dashboard / MCP tool can advertise their
  existence and let an operator fetch them.
  """

  @behaviour Raxol.Symphony.Evidence.Backend

  alias Raxol.Symphony.{Config, Evidence}

  @default_subdir ".raxol_symphony"
  @default_extensions [".cast", ".asciinema"]

  @impl true
  @spec collect(Evidence.t(), Config.t(), keyword()) :: Evidence.t()
  def collect(%Evidence{workspace: nil} = evidence, _config, _opts) do
    Evidence.put_error(evidence, :recording, :no_workspace)
  end

  def collect(%Evidence{workspace: workspace} = evidence, _config, opts) do
    scan_dir = Keyword.get(opts, :scan_dir, Path.join(workspace, @default_subdir))
    extensions = Keyword.get(opts, :extensions, @default_extensions)

    case scan(scan_dir, extensions) do
      {:ok, recordings} -> %Evidence{evidence | recordings: recordings}
      {:error, reason} -> Evidence.put_error(evidence, :recording, reason)
    end
  end

  defp scan(dir, extensions) do
    cond do
      not File.exists?(dir) -> {:ok, []}
      not File.dir?(dir) -> {:error, :scan_dir_not_a_directory}
      true -> {:ok, list_recordings(dir, extensions)}
    end
  end

  defp list_recordings(dir, extensions) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&matches?(&1, extensions))
        |> Enum.map(fn entry -> describe(Path.join(dir, entry), entry) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1.modified_at, &>=/2)

      {:error, _} ->
        []
    end
  end

  defp matches?(entry, extensions) do
    ext = entry |> Path.extname() |> String.downcase()
    ext in extensions
  end

  defp describe(path, name) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, size: size, mtime: mtime}} ->
        %{
          name: name,
          path: path,
          size_bytes: size,
          modified_at: mtime
        }

      _ ->
        nil
    end
  end
end
