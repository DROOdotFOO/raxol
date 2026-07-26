defmodule Raxol.Symphony.PromptBuilder do
  @moduledoc """
  Renders a `WORKFLOW.md` prompt template with strict Liquid semantics.

  Implements SPEC s5.4 (Prompt Template Contract):

  - Use a strict template engine (Liquid via `:solid`).
  - Unknown variables MUST fail rendering.
  - Unknown filters MUST fail rendering.
  - Convert issue object keys to strings for template compatibility.
  - Preserve nested arrays/maps (labels, blockers) so templates can iterate.

  Fallback: when the prompt body is empty/blank, returns the SPEC's default
  `"You are working on an issue from Linear."` prompt instead of failing.

  The parsed template AST is memoized in a single `:persistent_term` entry
  (a bounded, FIFO-evicted map from template string to AST), so a template
  is parsed once and every subsequent render across both runners reuses the
  AST. Rendering is never memoized (it varies per issue/attempt). The cache
  is capped at #{16} templates so a live-reloaded `WORKFLOW.md` cannot grow
  it without bound; a re-parse of an evicted template is the only cost.

  Error returns:

  - `{:error, :solid_not_loaded}` -- consumer omitted `:solid`.
  - `{:error, {:template_parse_error, reason}}` -- parse failure.
  - `{:error, {:template_render_error, [error]}}` -- render failure (unknown
    variable, unknown filter, etc).
  """

  alias Raxol.Symphony.Issue

  @default_prompt "You are working on an issue from Linear."

  @doc """
  Renders the prompt template for an issue.

  - `issue` -- normalized `Raxol.Symphony.Issue`.
  - `prompt_template` -- the trimmed Markdown body from `WORKFLOW.md`.
  - `attempt` -- nil on first attempt, integer on retry/continuation.

  Returns `{:ok, rendered_string}` or `{:error, reason}`.
  """
  @spec build(Issue.t(), binary() | nil, non_neg_integer() | nil) ::
          {:ok, binary()} | {:error, term()}
  def build(%Issue{} = issue, prompt_template, attempt \\ nil) do
    if solid_loaded?() do
      do_build(issue, fallback_template(prompt_template), attempt)
    else
      {:error, :solid_not_loaded}
    end
  end

  defp do_build(%Issue{} = issue, template, attempt) do
    with {:ok, parsed} <- parse_template(template) do
      render_template(parsed, issue, attempt)
    end
  end

  # The parsed Liquid AST is a pure function of the template string, so it
  # is memoized in ONE `:persistent_term` entry holding a bounded map from
  # template string to AST. Both runners re-render the SAME `WORKFLOW.md`
  # template on every fresh run of every issue; without this each run
  # re-parses it. The read-often/write-rarely profile fits `:persistent_term`
  # (a global GC fires only on a genuinely new template, which is rare).
  #
  # A single entry, not one key per template, is deliberate: `WorkflowStore`
  # hot-reloads `WORKFLOW.md`, so a per-template key scheme would accumulate a
  # never-evicted entry for every template ever seen. Here the map is capped
  # at @max_memoized with FIFO eviction, so a live-edited template can never
  # grow the cache without bound — an evicted template just re-parses on next
  # use. Parse errors are not memoized (cheap, rare, and must stay observable).
  @memo_key {__MODULE__, :parsed_templates}
  @max_memoized 16

  defp parse_template(template) do
    memo = :persistent_term.get(@memo_key, %{map: %{}, order: []})

    case Map.get(memo.map, template) do
      nil -> parse_and_memoize(memo, template)
      parsed -> {:ok, parsed}
    end
  end

  defp parse_and_memoize(memo, template) do
    case Solid.parse(template) do
      {:ok, parsed} ->
        :persistent_term.put(@memo_key, put_bounded(memo, template, parsed))
        {:ok, parsed}

      {:error, error} ->
        {:error, {:template_parse_error, error}}
    end
  end

  # FIFO insert into the bounded memo: evict the oldest template when full so
  # the entry never grows past @max_memoized across live template reloads.
  defp put_bounded(%{map: map, order: order}, template, parsed) do
    if map_size(map) >= @max_memoized do
      {evict, rest} = List.pop_at(order, 0)

      %{
        map: map |> Map.delete(evict) |> Map.put(template, parsed),
        order: rest ++ [template]
      }
    else
      %{map: Map.put(map, template, parsed), order: order ++ [template]}
    end
  end

  defp render_template(parsed, %Issue{} = issue, attempt) do
    vars = build_vars(issue, attempt)

    case Solid.render(parsed, vars,
           strict_variables: true,
           strict_filters: true
         ) do
      {:ok, iolist} ->
        {:ok, IO.iodata_to_binary(iolist)}

      {:error, errors, _partial} ->
        {:error, {:template_render_error, errors}}
    end
  end

  @doc """
  Returns the default fallback prompt text.
  """
  @spec default_prompt() :: binary()
  def default_prompt, do: @default_prompt

  # -- Internals --------------------------------------------------------------

  defp fallback_template(template) do
    if blank?(template), do: @default_prompt, else: template
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: true

  defp build_vars(%Issue{} = issue, attempt) do
    %{
      "issue" => issue_to_liquid_map(issue),
      "attempt" => attempt
    }
  end

  defp issue_to_liquid_map(%Issue{} = issue) do
    %{
      "id" => issue.id,
      "identifier" => issue.identifier,
      "title" => issue.title,
      "description" => issue.description,
      "state" => issue.state,
      "url" => issue.url,
      "labels" => issue.labels,
      "priority" => issue.priority,
      "branch_name" => issue.branch_name,
      "created_at" => format_datetime(issue.created_at),
      "updated_at" => format_datetime(issue.updated_at),
      "blocked_by" => Enum.map(issue.blocked_by, &blocker_to_liquid_map/1)
    }
  end

  defp blocker_to_liquid_map(%Issue.Blocker{} = blocker) do
    %{
      "id" => blocker.id,
      "identifier" => blocker.identifier,
      "state" => blocker.state
    }
  end

  defp blocker_to_liquid_map(other) when is_map(other) do
    Map.new(other, fn {k, v} -> {to_string(k), v} end)
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  defp solid_loaded?, do: Code.ensure_loaded?(Solid)
end
