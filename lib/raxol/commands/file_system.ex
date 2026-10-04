defmodule Raxol.Commands.FileSystem do
  @moduledoc """
  Pure functional in-memory virtual file system.

  Every operation takes a filesystem struct and returns `{:ok, result}` or
  `{:error, reason}`. The struct is immutable -- mutations return a new copy.

  Internally uses a flat map keyed by absolute path for O(1) lookups. Every
  non-root node has an existing directory parent; attempts to create a child
  below a file return `{:error, :not_a_directory}` without changing the
  filesystem.

  ## Example

      fs = FileSystem.new()
      {:ok, fs} = FileSystem.mkdir(fs, "/docs")
      {:ok, fs} = FileSystem.create_file(fs, "/docs/readme.txt", "Hello")
      {:ok, entries} = FileSystem.ls(fs, "/docs")
      {:ok, content} = FileSystem.cat(fs, "/docs/readme.txt")
  """

  @type node_type :: :file | :directory
  @type timestamp :: integer()

  @type node_entry :: %{
          type: node_type(),
          created_at: timestamp(),
          modified_at: timestamp(),
          size: non_neg_integer(),
          content: String.t() | nil,
          children: [String.t()] | nil
        }

  @type tree_node :: {String.t(), node_type(), [tree_node()]}

  @type stat_info :: %{
          type: node_type(),
          size: non_neg_integer(),
          created_at: timestamp(),
          modified_at: timestamp(),
          path: String.t()
        }

  @type t :: %__MODULE__{
          cwd: String.t(),
          prev_dir: String.t() | nil,
          nodes: %{String.t() => node_entry()}
        }

  @bytes_per_kb 1024
  @bytes_per_mb 1024 * 1024

  defstruct cwd: "/",
            prev_dir: nil,
            nodes: %{}

  # -------------------------------------------------------------------
  # Construction
  # -------------------------------------------------------------------

  @doc "Create a new filesystem with an empty root directory."
  @spec new() :: t()
  def new do
    now = System.monotonic_time(:millisecond)

    %__MODULE__{
      cwd: "/",
      prev_dir: nil,
      nodes: %{
        "/" => dir_node(now)
      }
    }
  end

  # -------------------------------------------------------------------
  # Core CRUD
  # -------------------------------------------------------------------

  @doc """
  Create a directory at `path`.

  The parent must exist and be a directory.
  """
  @spec mkdir(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def mkdir(%__MODULE__{} = fs, path) do
    now = System.monotonic_time(:millisecond)
    insert_node(fs, path, dir_node(now))
  end

  @doc """
  Create a file at `path` with `content`.

  The parent must exist and be a directory.
  """
  @spec create_file(t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, atom()}
  def create_file(%__MODULE__{} = fs, path, content) when is_binary(content) do
    now = System.monotonic_time(:millisecond)
    insert_node(fs, path, file_node(content, now))
  end

  @doc "Remove a file or empty directory at `path`."
  @spec rm(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def rm(%__MODULE__{} = fs, path) do
    abs = resolve_path(fs.cwd, path)
    do_rm(fs, abs)
  end

  defp do_rm(_fs, "/"), do: {:error, :cannot_remove_root}

  defp do_rm(fs, abs) do
    case Map.get(fs.nodes, abs) do
      nil ->
        {:error, :not_found}

      %{type: :directory, children: [_ | _]} ->
        {:error, :directory_not_empty}

      _node ->
        now = System.monotonic_time(:millisecond)
        name = Path.basename(abs)
        parent = parent_path(abs)

        nodes =
          fs.nodes
          |> Map.delete(abs)
          |> update_in([parent, :children], &List.delete(&1, name))
          |> update_in([parent, :modified_at], fn _ -> now end)

        {:ok, %{fs | nodes: nodes}}
    end
  end

  @doc "Check if a path exists."
  @spec exists?(t(), String.t()) :: boolean()
  def exists?(%__MODULE__{} = fs, path) do
    abs = resolve_path(fs.cwd, path)
    Map.has_key?(fs.nodes, abs)
  end

  @doc "Return metadata for the node at `path`."
  @spec stat(t(), String.t()) :: {:ok, stat_info()} | {:error, atom()}
  def stat(%__MODULE__{} = fs, path) do
    abs = resolve_path(fs.cwd, path)

    case Map.get(fs.nodes, abs) do
      nil ->
        {:error, :not_found}

      node ->
        {:ok,
         %{
           type: node.type,
           size: node.size,
           created_at: node.created_at,
           modified_at: node.modified_at,
           path: abs
         }}
    end
  end

  # -------------------------------------------------------------------
  # Navigation
  # -------------------------------------------------------------------

  @doc """
  List entries in a directory. Returns `{:ok, entries}` where entries
  is a sorted list of child names.
  """
  @spec ls(t(), String.t()) :: {:ok, [String.t()]} | {:error, atom()}
  def ls(%__MODULE__{} = fs, path \\ ".") do
    abs = resolve_path(fs.cwd, path)

    case Map.get(fs.nodes, abs) do
      nil -> {:error, :not_found}
      %{type: :file} -> {:error, :not_a_directory}
      %{type: :directory, children: children} -> {:ok, Enum.sort(children)}
    end
  end

  @doc """
  Change the current working directory. Supports absolute paths, relative
  paths, `..` (parent), and `-` (previous directory).
  """
  @spec cd(t(), String.t()) :: {:ok, t()} | {:error, atom()}
  def cd(%__MODULE__{prev_dir: nil}, "-"), do: {:error, :no_previous_directory}

  def cd(%__MODULE__{prev_dir: prev} = fs, "-"), do: do_cd(fs, prev)

  def cd(%__MODULE__{} = fs, path) do
    abs = resolve_path(fs.cwd, path)
    do_cd(fs, abs)
  end

  defp do_cd(fs, abs) do
    case Map.get(fs.nodes, abs) do
      nil -> {:error, :not_found}
      %{type: :file} -> {:error, :not_a_directory}
      %{type: :directory} -> {:ok, %{fs | cwd: abs, prev_dir: fs.cwd}}
    end
  end

  @doc "Return the current working directory."
  @spec pwd(t()) :: String.t()
  def pwd(%__MODULE__{cwd: cwd}), do: cwd

  @doc """
  Return a tree representation of the directory at `path`, limited to `depth` levels.
  Returns `{:ok, tree_node}` where tree_node is `{name, type, children}`.
  """
  @spec tree(t(), String.t(), non_neg_integer()) ::
          {:ok, tree_node()} | {:error, atom()}
  def tree(%__MODULE__{} = fs, path \\ "/", depth \\ 3) do
    abs = resolve_path(fs.cwd, path)

    case Map.get(fs.nodes, abs) do
      nil ->
        {:error, :not_found}

      %{type: :file} ->
        {:ok, {Path.basename(abs), :file, []}}

      %{type: :directory} ->
        name = if abs == "/", do: "/", else: Path.basename(abs)
        {:ok, build_tree(fs, abs, name, depth)}
    end
  end

  @spec build_tree(t(), String.t(), String.t(), non_neg_integer()) ::
          tree_node()
  defp build_tree(_fs, _abs, name, 0), do: {name, :directory, []}

  defp build_tree(fs, abs, name, depth) do
    %{children: children} = Map.fetch!(fs.nodes, abs)

    child_nodes =
      children
      |> Enum.sort()
      |> Enum.map(fn child_name ->
        child_path = join_path(abs, child_name)

        case Map.fetch!(fs.nodes, child_path) do
          %{type: :file} ->
            {child_name, :file, []}

          %{type: :directory} ->
            build_tree(fs, child_path, child_name, depth - 1)
        end
      end)

    {name, :directory, child_nodes}
  end

  # -------------------------------------------------------------------
  # Read
  # -------------------------------------------------------------------

  @doc "Read the content of a file."
  @spec cat(t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def cat(%__MODULE__{} = fs, path) do
    abs = resolve_path(fs.cwd, path)

    case Map.get(fs.nodes, abs) do
      nil -> {:error, :not_found}
      %{type: :directory} -> {:error, :is_a_directory}
      %{type: :file, content: content} -> {:ok, content}
    end
  end

  # -------------------------------------------------------------------
  # Formatting
  # -------------------------------------------------------------------

  @doc """
  Format ls output for terminal display. Returns a list of styled line tuples
  `{text, style}` where style is `:directory` or `:file`.
  """
  @spec format_ls([String.t()], t(), String.t()) :: [{String.t(), atom()}]
  def format_ls(entries, %__MODULE__{} = fs, dir_path) do
    abs = resolve_path(fs.cwd, dir_path)

    entries
    |> Enum.sort()
    |> Enum.map(fn name ->
      child_path = join_path(abs, name)

      case Map.get(fs.nodes, child_path) do
        %{type: :directory} -> {name <> "/", :directory}
        %{type: :file, size: size} -> {"#{name}  #{format_size(size)}", :file}
        nil -> {name, :file}
      end
    end)
  end

  @doc """
  Format file content for terminal display. Returns a list of `{line, line_number}`
  tuples, truncated to fit `max_width` and `max_height`.

  Note: uses `String.length/1` (grapheme count) for truncation. For CJK-accurate
  display width, the render pipeline handles this via `Raxol.UI.TextMeasure`.
  """
  @spec format_cat(String.t(), pos_integer(), pos_integer()) :: [
          {String.t(), pos_integer()}
        ]
  def format_cat(content, max_width, max_height) do
    content
    |> String.split("\n")
    |> Enum.take(max_height)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, num} ->
      truncated =
        if String.length(line) > max_width,
          do: String.slice(line, 0, max_width - 1) <> "~",
          else: line

      {truncated, num}
    end)
  end

  # -------------------------------------------------------------------
  # Path Resolution (internal)
  # -------------------------------------------------------------------

  @spec resolve_path(String.t(), String.t()) :: String.t()
  defp resolve_path(_cwd, "/" <> _ = abs), do: normalize_path(abs)
  defp resolve_path(cwd, relative), do: normalize_path(join_path(cwd, relative))

  @spec normalize_path(String.t()) :: String.t()
  defp normalize_path(path) do
    segments =
      path
      |> String.split("/", trim: true)
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [] -> []
        "..", [_ | rest] -> rest
        segment, acc -> [segment | acc]
      end)
      |> Enum.reverse()

    case segments do
      [] -> "/"
      parts -> "/" <> Enum.join(parts, "/")
    end
  end

  # -------------------------------------------------------------------
  # Internal helpers
  # -------------------------------------------------------------------

  @spec insert_node(t(), String.t(), node_entry()) ::
          {:ok, t()} | {:error, atom()}
  defp insert_node(fs, path, node) do
    abs = resolve_path(fs.cwd, path)
    parent = parent_path(abs)
    parent_node = Map.get(fs.nodes, parent)

    cond do
      Map.has_key?(fs.nodes, abs) ->
        {:error, :already_exists}

      is_nil(parent_node) ->
        {:error, :parent_not_found}

      parent_node.type != :directory ->
        {:error, :not_a_directory}

      true ->
        name = Path.basename(abs)
        now = node.created_at

        nodes =
          fs.nodes
          |> Map.put(abs, node)
          |> update_in([parent, :children], &[name | &1])
          |> update_in([parent, :modified_at], fn _ -> now end)

        {:ok, %{fs | nodes: nodes}}
    end
  end

  defp dir_node(now) do
    %{
      type: :directory,
      created_at: now,
      modified_at: now,
      size: 0,
      content: nil,
      children: []
    }
  end

  defp file_node(content, now) do
    %{
      type: :file,
      created_at: now,
      modified_at: now,
      size: byte_size(content),
      content: content,
      children: nil
    }
  end

  @spec join_path(String.t(), String.t()) :: String.t()
  defp join_path("/", child), do: "/" <> child
  defp join_path(parent, child), do: parent <> "/" <> child

  @spec parent_path(String.t()) :: String.t()
  defp parent_path("/"), do: "/"
  defp parent_path(path), do: Path.dirname(path)

  @spec format_size(non_neg_integer()) :: String.t()
  defp format_size(bytes) when bytes < @bytes_per_kb, do: "#{bytes}B"

  defp format_size(bytes) when bytes < @bytes_per_mb,
    do: "#{div(bytes, @bytes_per_kb)}K"

  defp format_size(bytes), do: "#{div(bytes, @bytes_per_mb)}M"
end
