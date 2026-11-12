defmodule Raxol.System.Updater.Archive do
  @moduledoc """
  Extracts a checksum-verified update archive without letting any entry land
  outside the destination directory.

  Every entry is vetted before a single byte is written: absolute paths,
  drive letters, `..` components, and anything that is not a regular file or
  directory (symlinks, hard links, devices) refuse the whole archive. The
  extraction itself is `:erl_tar` / `:zip`, never a shell `tar`/`unzip`
  whose traversal handling depends on the host's build.
  """

  @type kind :: :tar_gz | :zip

  @spec extract(Path.t(), Path.t(), kind()) :: :ok | {:error, term()}
  def extract(archive, dest, kind) do
    with {:ok, entries} <- entries(archive, kind),
         :ok <- vet(entries),
         :ok <- File.mkdir_p(dest) do
      do_extract(archive, dest, kind)
    end
  end

  @doc """
  The regular file named `name` inside `dir` (searched recursively). A
  symlink with that name does not count.
  """
  @spec find_executable(Path.t(), String.t()) ::
          {:ok, Path.t()} | {:error, term()}
  def find_executable(dir, name) do
    case find(dir, name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  defp entries(archive, :tar_gz) do
    case :erl_tar.table(to_charlist(archive), [:compressed, :verbose]) do
      {:ok, rows} ->
        {:ok,
         Enum.map(rows, fn row -> {to_string(elem(row, 0)), elem(row, 1)} end)}

      {:error, reason} ->
        {:error, {:unreadable_archive, reason}}
    end
  end

  defp entries(archive, :zip) do
    case :zip.list_dir(to_charlist(archive)) do
      {:ok, rows} ->
        {:ok,
         for {:zip_file, name, info, _comment, _offset, _size} <- rows do
           {to_string(name), elem(info, 2)}
         end}

      {:error, reason} ->
        {:error, {:unreadable_archive, reason}}
    end
  end

  defp vet(entries) do
    Enum.find_value(entries, :ok, fn {name, type} ->
      cond do
        type not in [:regular, :directory] ->
          {:error, {:unsafe_archive_entry, name, type}}

        not safe_path?(name) ->
          {:error, {:unsafe_archive_entry, name}}

        true ->
          nil
      end
    end)
  end

  defp safe_path?(name) do
    segments = String.split(name, ["/", "\\"], trim: true)

    name != "" and Path.type(name) == :relative and
      not String.starts_with?(name, ["/", "\\"]) and
      not Regex.match?(~r/\A[A-Za-z]:/, name) and
      segments != [] and ".." not in segments
  end

  defp do_extract(archive, dest, :tar_gz) do
    case :erl_tar.extract(to_charlist(archive), [
           :compressed,
           {:cwd, to_charlist(dest)}
         ]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp do_extract(archive, dest, :zip) do
    case :zip.extract(to_charlist(archive), [{:cwd, to_charlist(dest)}]) do
      {:ok, _files} -> :ok
      {:error, reason} -> {:error, {:extract_failed, reason}}
    end
  end

  defp find(dir, name) do
    case File.ls(dir) do
      {:ok, children} ->
        children
        |> Enum.sort()
        |> Enum.find_value(fn child ->
          match(Path.join(dir, child), child, name)
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp match(path, child, name) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} when child == name -> path
      {:ok, %File.Stat{type: :directory}} -> find(path, name)
      _other -> nil
    end
  end
end
