defmodule Raxol.Agent.ClientProtocol.ProjectRoot do
  @max_bytes 4_096
  @max_links 40

  @moduledoc """
  The project root a `session/new` names in `cwd`.

  `resolve/1` takes an absolute path of at most #{@max_bytes} bytes that
  names an existing directory and returns that directory's real path, with
  every symlink on the way followed. The agent's journal is bound to what
  this returns, so two spellings of one directory are one root and continue
  one journal. Nothing after this resolves the path again.

  Letter case and Unicode normalisation are left as the client wrote them:
  on a volume that takes `a` and `A` for one directory they are two roots.
  """

  @bound_to "the agent's journal is bound to it"

  @doc "The real path of the directory `cwd` names, or why it is refused."
  @spec resolve(term()) :: {:ok, Path.t()} | {:error, String.t()}
  def resolve(cwd) when is_binary(cwd) and byte_size(cwd) > @max_bytes,
    do: {:error, "cwd is longer than #{@max_bytes} bytes"}

  def resolve(cwd) when is_binary(cwd) do
    if Path.type(cwd) == :absolute, do: existing(cwd), else: not_absolute()
  end

  def resolve(_cwd), do: not_absolute()

  defp not_absolute, do: {:error, "cwd must be an absolute path: #{@bound_to}"}

  defp existing(cwd) do
    with {:ok, real} <- real_path(cwd, @max_links),
         true <- same_directory?(cwd, real) do
      {:ok, real}
    else
      _missing -> {:error, "cwd must name an existing directory: #{@bound_to}"}
    end
  end

  # `path` with its symlinks followed, at most `links` of them: a loop ends
  # in `:error`.
  defp real_path(path, links) do
    [root | parts] = path |> Path.expand() |> Path.split()
    follow(parts, root, links)
  end

  defp follow([], resolved, _links), do: {:ok, resolved}

  defp follow([part | rest], resolved, links) do
    path = Path.join(resolved, part)

    case :file.read_link_all(path) do
      {:ok, _target} when links == 0 -> :error
      {:ok, target} -> real_path(Path.join([target(target, resolved) | rest]), links - 1)
      {:error, _not_a_link} -> follow(rest, path, links)
    end
  end

  defp target(target, directory),
    do: target |> IO.chardata_to_string() |> Path.expand(directory)

  # The walk above joins a link's target to its directory as text, which
  # differs from what the system does for a target that climbs out of
  # another link. What it found is used only if it is the directory the
  # system itself finds for `cwd`.
  defp same_directory?(cwd, real) do
    with {:ok, %File.Stat{type: :directory} = named} <- File.stat(cwd),
         {:ok, %File.Stat{type: :directory} = found} <- File.stat(real) do
      {named.major_device, named.inode} == {found.major_device, found.inode}
    else
      _missing -> false
    end
  end
end
