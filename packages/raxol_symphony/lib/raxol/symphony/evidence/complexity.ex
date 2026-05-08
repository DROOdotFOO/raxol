defmodule Raxol.Symphony.Evidence.Complexity do
  @moduledoc """
  Complexity / SLOC report for the workspace.

  Prefers `cloc --json --quiet .` when the binary is on `PATH`; falls back
  to a minimal Elixir SLOC counter that walks the workspace and counts
  non-blank, non-comment lines per recognized extension.

  Tests can override the binary via the `:cloc_path` option, or skip cloc
  entirely with `cloc_path: false`.
  """

  @behaviour Raxol.Symphony.Evidence.Backend

  alias Raxol.Symphony.{Config, Evidence}

  # Languages with single-line `#`, `//`, or `--` comments. Block comments
  # are intentionally not stripped -- the fallback is meant to be cheap and
  # approximate, not authoritative.
  @ext_to_lang %{
    ".ex" => {:elixir, ["#"]},
    ".exs" => {:elixir, ["#"]},
    ".heex" => {:heex, ["<%--"]},
    ".rs" => {:rust, ["//"]},
    ".go" => {:go, ["//"]},
    ".ts" => {:typescript, ["//"]},
    ".tsx" => {:typescript, ["//"]},
    ".js" => {:javascript, ["//"]},
    ".jsx" => {:javascript, ["//"]},
    ".py" => {:python, ["#"]},
    ".rb" => {:ruby, ["#"]},
    ".lua" => {:lua, ["--"]},
    ".sh" => {:shell, ["#"]},
    ".bash" => {:shell, ["#"]},
    ".zsh" => {:shell, ["#"]},
    ".sql" => {:sql, ["--"]},
    ".md" => {:markdown, []},
    ".json" => {:json, []},
    ".yaml" => {:yaml, ["#"]},
    ".yml" => {:yaml, ["#"]}
  }

  # Skip these directories during the fallback walk.
  @ignored_dirs ~w(.git node_modules deps _build .elixir_ls target dist build .venv venv)

  @impl true
  @spec collect(Evidence.t(), Config.t(), keyword()) :: Evidence.t()
  def collect(%Evidence{workspace: nil} = evidence, _config, _opts) do
    Evidence.put_error(evidence, :complexity, :no_workspace)
  end

  def collect(%Evidence{workspace: workspace} = evidence, _config, opts) do
    case Keyword.get(opts, :cloc_path, :auto) do
      false -> %{evidence | complexity: fallback_count(workspace)}
      :auto -> via_cloc_or_fallback(evidence, workspace, System.find_executable("cloc"))
      path when is_binary(path) -> via_cloc(evidence, workspace, path)
    end
  end

  defp via_cloc_or_fallback(evidence, workspace, nil),
    do: %{evidence | complexity: fallback_count(workspace)}

  defp via_cloc_or_fallback(evidence, workspace, cloc_path),
    do: via_cloc(evidence, workspace, cloc_path)

  defp via_cloc(evidence, workspace, cloc_path) do
    case System.cmd(cloc_path, ["--json", "--quiet", "."], cd: workspace, stderr_to_stdout: true) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, json} ->
            %{evidence | complexity: normalize_cloc(json)}

          {:error, _} ->
            %{evidence | complexity: fallback_count(workspace)}
            |> Evidence.put_error(:complexity, :cloc_invalid_json)
        end

      {output, status} ->
        %{evidence | complexity: fallback_count(workspace)}
        |> Evidence.put_error(:complexity, {:cloc_failed, status, String.slice(output, 0, 200)})
    end
  rescue
    e in ErlangError ->
      case e.original do
        :enoent ->
          %{evidence | complexity: fallback_count(workspace)}
          |> Evidence.put_error(:complexity, :cloc_not_found)

        _ ->
          %{evidence | complexity: fallback_count(workspace)}
          |> Evidence.put_error(:complexity, {:exception, e})
      end
  end

  defp normalize_cloc(json) when is_map(json) do
    sum = Map.get(json, "SUM", %{})
    languages = Map.delete(json, "header") |> Map.delete("SUM")

    %{
      source: :cloc,
      total_files: Map.get(sum, "nFiles", 0),
      total_blank: Map.get(sum, "blank", 0),
      total_comment: Map.get(sum, "comment", 0),
      total_code: Map.get(sum, "code", 0),
      languages:
        Map.new(languages, fn {lang, stats} ->
          {lang,
           %{
             files: Map.get(stats, "nFiles", 0),
             blank: Map.get(stats, "blank", 0),
             comment: Map.get(stats, "comment", 0),
             code: Map.get(stats, "code", 0)
           }}
        end)
    }
  end

  # ---------------------------------------------------------------------------
  # Fallback walker
  # ---------------------------------------------------------------------------

  defp fallback_count(workspace) do
    {languages, total_files, total_code} = walk(workspace)

    %{
      source: :fallback,
      total_files: total_files,
      total_blank: 0,
      total_comment: 0,
      total_code: total_code,
      languages: languages
    }
  end

  defp walk(root) do
    do_walk(root, root, %{}, 0, 0)
  end

  defp do_walk(root, dir, langs, files, code) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.reduce(entries, {langs, files, code}, fn entry, acc ->
          handle_entry(root, dir, entry, acc)
        end)

      {:error, _} ->
        {langs, files, code}
    end
  end

  defp handle_entry(root, dir, entry, {l, f, c} = acc) do
    full = Path.join(dir, entry)

    cond do
      ignored?(entry, full) -> acc
      File.dir?(full) -> do_walk(root, full, l, f, c)
      File.regular?(full) -> count_file(full, l, f, c)
      true -> acc
    end
  end

  defp ignored?(entry, _full) when entry in @ignored_dirs, do: true
  defp ignored?(_entry, _full), do: false

  defp count_file(path, langs, files, code) do
    ext = Path.extname(path) |> String.downcase()

    case Map.get(@ext_to_lang, ext) do
      nil ->
        {langs, files, code}

      {lang, comment_prefixes} ->
        case File.read(path) do
          {:ok, body} ->
            count = sloc(body, comment_prefixes)
            updated = Map.update(langs, Atom.to_string(lang), one(count), &add_one(&1, count))
            {updated, files + 1, code + count}

          {:error, _} ->
            {langs, files, code}
        end
    end
  end

  defp sloc(body, comment_prefixes) do
    body
    |> String.split("\n")
    |> Enum.count(fn line ->
      trimmed = String.trim(line)

      trimmed != "" and
        not Enum.any?(comment_prefixes, &String.starts_with?(trimmed, &1))
    end)
  end

  defp one(count), do: %{files: 1, blank: 0, comment: 0, code: count}

  defp add_one(stats, count) do
    %{
      stats
      | files: stats.files + 1,
        code: stats.code + count
    }
  end
end
