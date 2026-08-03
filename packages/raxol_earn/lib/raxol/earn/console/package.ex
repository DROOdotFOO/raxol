defmodule Raxol.Earn.Console.Package do
  @moduledoc """
  Parse a Console agent package -- the inverse of `Raxol.Earn.Console.Generator`.

  Reads the file set the generator emits (`soul.md`, optional `AGENTS.md`,
  `tasks.json`, `skills/<name>/SKILL.md`, `manifest.json`) into a validated
  `%Package{}` a runtime can boot from. `parse/1` is pure over a `filename =>
  binary` map; `load/1` reads a directory into that map first.

  Cron fields are re-validated with `Raxol.Earn.Console.Cron`, and skill paths
  must match the generator's single-segment slug (so a hostile
  `skills/../escape/SKILL.md` never becomes a struct entry). A malformed package
  is a typed `{:error, {:invalid_package, field, detail}}`, never a partial
  struct.

  This module owns the package FORMAT together with the generator. The runtime
  mapping (persona -> system prompt, tasks -> scheduler jobs, channels) lives in
  the `raxol_console` boot loader downstream; keeping the parse here means the
  format has one home and the generator/parser cannot drift apart untested.
  """

  alias Raxol.Earn.Console.Cron

  @runtime_atom %{"hermes" => :hermes, "openclaw" => :openclaw, "raxol" => :raxol}

  # Mirrors the generator's `@skill_name` (`skills/<name>/SKILL.md`): a single
  # safe slug segment, never `..`, `/`, or absolute.
  @skill_key ~r"^skills/([a-z0-9][a-z0-9_-]{0,63})/SKILL\.md$"

  @type task :: %{
          name: String.t(),
          description: String.t(),
          cron: String.t(),
          prompt: String.t()
        }
  @type skill :: %{name: String.t(), skill_md: String.t()}

  defstruct [:runtime, :soul_md, :agents_md, :manifest, tasks: [], skills: []]

  @type t :: %__MODULE__{
          runtime: :hermes | :openclaw | :raxol | nil,
          soul_md: String.t(),
          agents_md: String.t() | nil,
          manifest: map() | nil,
          tasks: [task()],
          skills: [skill()]
        }

  @doc "Read a package directory into a `%Package{}`."
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(dir) when is_binary(dir) do
    with {:ok, files} <- read_dir(dir), do: parse(files)
  end

  @doc "Parse a `filename => binary` map (the generator's `:files`) into a `%Package{}`."
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(files) when is_map(files) do
    with {:ok, soul} <- fetch(files, "soul.md"),
         {:ok, manifest} <- decode_manifest(files),
         {:ok, runtime} <- runtime(manifest),
         {:ok, tasks} <- tasks(files),
         {:ok, skills} <- skills(files) do
      {:ok,
       %__MODULE__{
         runtime: runtime,
         soul_md: soul,
         agents_md: Map.get(files, "AGENTS.md"),
         manifest: manifest,
         tasks: tasks,
         skills: skills
       }}
    end
  end

  def parse(other), do: {:error, {:invalid_package, :root, {:not_a_map, other}}}

  # -- files -----------------------------------------------------------------

  defp fetch(files, key) do
    case Map.get(files, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      nil -> {:error, {:invalid_package, key, :missing}}
      other -> {:error, {:invalid_package, key, {:not_a_string, other}}}
    end
  end

  defp decode_manifest(files) do
    case Map.get(files, "manifest.json") do
      nil -> {:ok, nil}
      bin when is_binary(bin) -> decode_json(bin, :manifest)
      other -> {:error, {:invalid_package, :manifest, {:not_a_string, other}}}
    end
  end

  defp runtime(nil), do: {:ok, nil}

  defp runtime(%{"runtime" => r}) when is_binary(r) do
    case Map.fetch(@runtime_atom, r) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, {:invalid_package, :runtime, {:unknown, r}}}
    end
  end

  defp runtime(%{}), do: {:ok, nil}

  # -- tasks -----------------------------------------------------------------

  defp tasks(files) do
    case Map.get(files, "tasks.json") do
      nil ->
        {:ok, []}

      bin when is_binary(bin) ->
        with {:ok, decoded} <- decode_json(bin, :tasks), do: task_list(decoded)

      other ->
        {:error, {:invalid_package, :tasks, {:not_a_string, other}}}
    end
  end

  defp task_list(%{"tasks" => list}) when is_list(list), do: parse_tasks(list)

  defp task_list(%{"tasks" => other}),
    do: {:error, {:invalid_package, :tasks, {:not_a_list, other}}}

  defp task_list(%{}), do: {:ok, []}

  defp parse_tasks(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case parse_task(item) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp parse_task(%{"name" => n, "description" => d, "cron" => c, "prompt" => p})
       when is_binary(n) and is_binary(d) and is_binary(c) and is_binary(p) do
    if Cron.valid?(c),
      do: {:ok, %{name: n, description: d, cron: c, prompt: p}},
      else: {:error, {:invalid_package, :task, {:bad_cron, n, c}}}
  end

  defp parse_task(other), do: {:error, {:invalid_package, :task, {:missing_fields, other}}}

  # -- skills ----------------------------------------------------------------

  defp skills(files) do
    files
    |> Enum.reduce_while({:ok, []}, fn {key, body}, {:ok, acc} ->
      case Regex.run(@skill_key, key) do
        [_, name] when is_binary(body) -> {:cont, {:ok, [%{name: name, skill_md: body} | acc]}}
        [_, _name] -> {:halt, {:error, {:invalid_package, :skill, {:not_a_string, key}}}}
        nil -> {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.sort_by(acc, & &1.name)}
      err -> err
    end
  end

  # -- helpers ---------------------------------------------------------------

  defp decode_json(bin, field) do
    case Jason.decode(bin) do
      {:ok, %{} = map} -> {:ok, map}
      {:ok, other} -> {:error, {:invalid_package, field, {:not_an_object, other}}}
      {:error, err} -> {:error, {:invalid_package, field, {:not_json, Exception.message(err)}}}
    end
  end

  defp read_dir(dir) do
    if File.dir?(dir) do
      dir
      |> Path.join("**/*")
      |> Path.wildcard(match_dot: false)
      |> Enum.filter(&regular_file?/1)
      |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, acc} ->
        case File.read(path) do
          {:ok, bin} -> {:cont, {:ok, Map.put(acc, Path.relative_to(path, dir), bin)}}
          {:error, posix} -> {:halt, {:error, {:invalid_package, :read, {posix, path}}}}
        end
      end)
    else
      {:error, {:invalid_package, :dir, {:not_a_directory, dir}}}
    end
  end

  # A regular file that is NOT a symlink. `File.regular?/1` follows symlinks, so a
  # package could smuggle host files (`soul.md` -> /etc/passwd, a symlinked
  # SKILL.md) into the parsed struct. `lstat` does not follow, so a symlinked
  # entry reports `:symlink` and is skipped -- a symlinked required file
  # (soul.md) then reads as missing and fails closed, which is the safe outcome.
  defp regular_file?(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end
end
