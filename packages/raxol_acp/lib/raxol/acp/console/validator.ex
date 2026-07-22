defmodule Raxol.ACP.Console.Validator do
  @moduledoc """
  Static validation of a generated Console package, run before the bench and
  before anything is uploaded or submitted.

  Checks are structural on purpose: the `soul.md` prose format belongs to the
  runtimes (Virtuals/Nous own it — risk R2 in DESIGN.md §7), so this module
  asserts invariants that hold across format drift — an H1 title, sane length,
  no unresolved placeholders, no secret-shaped strings — plus hard contracts we
  do own: unique task names with valid 5-field cron and non-empty prompts, and
  agentskills-format frontmatter (`name:` + `description:`) on every SKILL.md.

  Length bounds are overridable via
  `config :raxol_acp, :console_soul_bytes, {min, max}` (default `{50, 40_000}`).
  Returns `{:ok, report}` (a `[{check, :ok}]` keyword) or
  `{:error, {check, detail}}` naming the first failing check.
  """

  alias Raxol.ACP.Console.Cron

  @placeholder ~r/\{\{|\bTODO\b|\bFIXME\b/
  @secretish ~r/sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|\b0x[0-9a-fA-F]{64}\b/
  @frontmatter ~r/\A---\n(.*?)\n---\n/s

  @checks [:soul, :placeholders, :secrets, :tasks, :skills, :manifest]

  @spec validate(%{
          :files => %{String.t() => binary()},
          :tasks => [map()],
          optional(atom()) => any()
        }) :: {:ok, keyword()} | {:error, {atom(), term()}}
  def validate(%{files: files, tasks: tasks}) do
    Enum.reduce_while(@checks, {:ok, []}, fn check, {:ok, report} ->
      case run(check, files, tasks) do
        :ok -> {:cont, {:ok, [{check, :ok} | report]}}
        {:error, detail} -> {:halt, {:error, {check, detail}}}
      end
    end)
    |> case do
      {:ok, report} -> {:ok, Enum.reverse(report)}
      e -> e
    end
  end

  defp run(:soul, files, _tasks) do
    {min, max} = Application.get_env(:raxol_acp, :console_soul_bytes, {50, 40_000})

    case Map.get(files, "soul.md") do
      nil ->
        {:error, :missing}

      soul when byte_size(soul) < min ->
        {:error, {:too_short, byte_size(soul)}}

      soul when byte_size(soul) > max ->
        {:error, {:too_long, byte_size(soul)}}

      soul ->
        if soul |> String.trim_leading() |> String.starts_with?("# "),
          do: :ok,
          else: {:error, :no_h1_title}
    end
  end

  defp run(:placeholders, files, _tasks), do: screen(files, @placeholder, & &1)

  defp run(:secrets, files, _tasks), do: screen(files, @secretish, fn _m -> :redacted end)

  defp run(:tasks, files, tasks) do
    names = Enum.map(tasks, & &1["name"])

    cond do
      not Map.has_key?(files, "tasks.json") and tasks != [] ->
        {:error, :tasks_json_missing}

      names != Enum.uniq(names) ->
        {:error, {:duplicate_task_names, names -- Enum.uniq(names)}}

      true ->
        Enum.find_value(tasks, :ok, fn t ->
          cond do
            not Cron.valid?(t["cron"]) -> {:error, {:invalid_cron, t["name"], t["cron"]}}
            String.trim(t["prompt"] || "") == "" -> {:error, {:empty_prompt, t["name"]}}
            true -> nil
          end
        end)
    end
  end

  defp run(:skills, files, _tasks) do
    files
    |> Enum.filter(fn {path, _} -> String.starts_with?(path, "skills/") end)
    |> Enum.find_value(:ok, fn {path, md} ->
      with [_, "SKILL.md"] <- path |> Path.split() |> Enum.take(-2),
           [_, fm] <- Regex.run(@frontmatter, md),
           true <- String.contains?(fm, "name:") and String.contains?(fm, "description:") do
        nil
      else
        _ -> {:error, {:bad_skill, path}}
      end
    end)
  end

  defp run(:manifest, files, _tasks) do
    with manifest when is_binary(manifest) <- Map.get(files, "manifest.json", {:error, :missing}),
         {:ok, %{"files" => listed}} <- Jason.decode(manifest) do
      actual = files |> Map.keys() |> Enum.sort()
      if listed == actual, do: :ok, else: {:error, {:manifest_drift, listed -- actual}}
    else
      {:error, :missing} -> {:error, :missing}
      _ -> {:error, :undecodable}
    end
  end

  defp screen(files, regex, redact) do
    Enum.find_value(files, :ok, fn {path, content} ->
      case Regex.run(regex, content) do
        nil -> nil
        [m | _] -> {:error, {path, redact.(m)}}
      end
    end)
  end
end
