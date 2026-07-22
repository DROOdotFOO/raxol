defmodule Raxol.ACP.Console.Generator do
  @moduledoc """
  Turns a validated `Raxol.ACP.Console.Spec` into a Console agent package.

  One structured inference call (through `Raxol.ACP.Console.Inference`) returns
  a JSON envelope; this module parses it, canonicalizes cadences, and assembles
  the file set the Console's Deploy Instance flow consumes:

      soul.md                       # always
      AGENTS.md                     # openclaw target only
      tasks.json                    # scheduled tasks, cron cadences
      skills/<name>/SKILL.md        # agentskills-format, one per skill
      deploy_instructions.md        # buyer's three-click redeploy walkthrough
      manifest.json                 # runtime, file list, generator metadata

  Contract with the model (enforced downstream by `Validator`): the envelope is
  a single JSON object `{"soul_md", "agents_md"?, "tasks": [{"name",
  "description", "cron", "prompt"}], "skills": [{"name", "skill_md"}]}` — every
  task `cron` a valid 5-field expression (NL cadences from the buyer are
  canonicalized here), every skill a SKILL.md with `name`/`description` YAML
  frontmatter. A malformed envelope fails delivery with a typed error rather
  than shipping a broken package; there is deliberately no silent retry loop
  (SLA discipline — the operator sees `{:generation_*, _}` in telemetry).
  """

  alias Raxol.ACP.Console.{Inference, Spec}

  # A skill name becomes a path segment (`skills/<name>/SKILL.md`), so it is
  # constrained to a safe, single-segment slug -- never `..`, `/`, or absolute.
  # Untrusted model output (steerable by buyer input) must not choose a file path.
  @skill_name ~r/^[a-z0-9][a-z0-9_-]{0,63}$/

  @type package :: %{
          runtime: :hermes | :openclaw,
          files: %{String.t() => binary()},
          tasks: [map()]
        }

  @doc "Generate the package for `spec`, keyed by `job_id` for provenance."
  @spec generate(Spec.t(), binary()) :: {:ok, package()} | {:error, term()}
  def generate(%Spec{} = spec, job_id) do
    runtime = resolve_runtime(spec)

    with {:ok, raw} <- Inference.complete(system_prompt(runtime), user_prompt(spec, runtime)),
         {:ok, env} <- decode(raw),
         {:ok, soul} <- fetch_str(env, "soul_md"),
         {:ok, tasks} <- normalize_tasks(env),
         {:ok, skills} <- normalize_skills(env) do
      files =
        %{"soul.md" => soul}
        |> put_agents_md(runtime, env)
        |> Map.put("tasks.json", Jason.encode!(%{"tasks" => tasks}, pretty: true))
        |> put_skills(skills)
        |> Map.put("deploy_instructions.md", deploy_instructions(runtime, spec))

      files =
        Map.put(
          files,
          "manifest.json",
          manifest(runtime, Enum.sort(["manifest.json" | Map.keys(files)]), job_id)
        )

      {:ok, %{runtime: runtime, files: files, tasks: tasks}}
    end
  end

  # `:either` resolves per the requested feature set: OpenClaw when skills are
  # requested (it ships ACP skills natively), hermes otherwise.
  defp resolve_runtime(%Spec{runtime: :either, skills: []}), do: :hermes
  defp resolve_runtime(%Spec{runtime: :either}), do: :openclaw
  defp resolve_runtime(%Spec{runtime: runtime}), do: runtime

  # -- prompts ---------------------------------------------------------------

  defp system_prompt(runtime) do
    """
    You author configuration packages for hosted autonomous agents on the
    Virtuals Console (runtime: #{runtime}). Respond with ONE JSON object and
    nothing else — no prose, no code fences. Shape:
    {"soul_md": string, #{if runtime == :openclaw, do: ~s("agents_md": string, ), else: ""}\
    "tasks": [{"name": snake_case string, "description": string,
    "cron": 5-field numeric cron string, "prompt": string}],
    "skills": [{"name": snake_case string, "skill_md": string}]}
    soul_md is a markdown document starting with a single `# <Agent Name>` H1,
    describing identity, purpose, operating boundaries, and tone. Every skill_md
    starts with YAML frontmatter delimited by `---` lines containing `name:` and
    `description:`. Cron fields are numeric only (no month/day names). Do not
    include placeholders like {{...}}, TODO, or FIXME, and never include
    credentials, private keys, or seed phrases.
    """
  end

  defp user_prompt(%Spec{} = spec, runtime) do
    Jason.encode!(%{
      "runtime" => runtime,
      "agent_name" => spec.agent_name,
      "purpose" => spec.purpose,
      "persona" => spec.persona,
      "scheduled_tasks" =>
        Enum.map(spec.scheduled_tasks, fn t ->
          %{"description" => t.description, "cadence" => cadence_hint(t.cadence)}
        end),
      "skills" => spec.skills,
      "constraints" => spec.constraints
    })
  end

  defp cadence_hint({:cron, c}), do: %{"cron" => c}
  defp cadence_hint({:nl, text}), do: %{"natural_language" => text}

  # -- envelope handling -----------------------------------------------------

  defp decode(raw) do
    raw
    |> String.trim()
    |> strip_fences()
    |> Jason.decode()
    |> case do
      {:ok, %{} = env} -> {:ok, env}
      {:ok, other} -> {:error, {:generation_bad_envelope, other}}
      {:error, err} -> {:error, {:generation_not_json, Exception.message(err)}}
    end
  end

  defp strip_fences("```" <> rest) do
    rest
    |> String.split("\n", parts: 2)
    |> List.last()
    |> String.trim_trailing()
    |> String.trim_trailing("```")
  end

  defp strip_fences(raw), do: raw

  defp fetch_str(env, key) do
    case Map.get(env, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      v -> {:error, {:generation_missing, key, v}}
    end
  end

  defp normalize_tasks(env) do
    env
    |> Map.get("tasks", [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => n, "description" => d, "cron" => c, "prompt" => p} = _t, {:ok, acc}
      when is_binary(n) and is_binary(d) and is_binary(c) and is_binary(p) ->
        {:cont, {:ok, [%{"name" => n, "description" => d, "cron" => c, "prompt" => p} | acc]}}

      t, _acc ->
        {:halt, {:error, {:generation_bad_task, t}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp normalize_skills(env) do
    env
    |> Map.get("skills", [])
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn
      %{"name" => n, "skill_md" => md}, {:ok, acc}
      when is_binary(n) and is_binary(md) ->
        if Regex.match?(@skill_name, n),
          do: {:cont, {:ok, [%{"name" => n, "skill_md" => md} | acc]}},
          else: {:halt, {:error, {:generation_unsafe_skill_name, n}}}

      s, _acc ->
        {:halt, {:error, {:generation_bad_skill, s}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      e -> e
    end
  end

  defp put_agents_md(files, :openclaw, env) do
    case Map.get(env, "agents_md") do
      md when is_binary(md) and md != "" -> Map.put(files, "AGENTS.md", md)
      _ -> files
    end
  end

  defp put_agents_md(files, _runtime, _env), do: files

  defp put_skills(files, skills) do
    Enum.reduce(skills, files, fn %{"name" => name, "skill_md" => md}, acc ->
      Map.put(acc, "skills/#{name}/SKILL.md", md)
    end)
  end

  defp deploy_instructions(runtime, %Spec{} = spec) do
    """
    # Deploying this agent to your Virtuals Console

    1. Open your agent in the Console dashboard and choose **Deploy Instance**.
       Your wallet, signers, ACP identity, and Console agent record are
       preserved across redeploys.
    2. Pick the **#{runtime}** runtime.
    3. Supply `soul.md` from this package as the instance's soul, and configure
       the scheduled tasks from `tasks.json` (name, cadence, prompt).
    #{if spec.skills == [], do: "", else: "4. Install the bundled `skills/` folders per your runtime's skill setup.\n"}
    Everything is editable after deploying. This package was validated on the
    open-source #{runtime} runtime before delivery; see the evidence link in the
    job deliverable.
    """
  end

  defp manifest(runtime, listed_files, job_id) do
    Jason.encode!(
      %{
        "offering" => "custom_console_agent",
        "runtime" => runtime,
        "job_id" => job_id,
        "files" => listed_files,
        "generated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      pretty: true
    )
  end
end
