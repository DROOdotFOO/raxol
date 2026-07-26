defmodule Raxol.Symphony.PromptBuilder do
  @memo_key {__MODULE__, :parsed_templates}
  @empty_memo %{map: %{}, order: []}

  # WHY 16: cap the parsed-template memo so a hot-reloaded `WORKFLOW.md`
  # (every edit is a fresh template string, hence a new key) cannot grow it
  # without bound. 16 comfortably covers the handful of workflow variants a
  # deployment runs concurrently; an evicted template just re-parses on next
  # use. Defined above the moduledoc so the doc can interpolate the attribute
  # rather than restate the literal.
  @max_memoized 16

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
  is capped at #{@max_memoized} templates so a live-reloaded `WORKFLOW.md`
  cannot grow it without bound; a re-parse of an evicted template is the only
  cost. Writes funnel through `Raxol.Symphony.PromptBuilder.Memo` (a single
  writer) so the cap holds under concurrent parses; reads stay lock-free
  against `:persistent_term`.

  On `:persistent_term` cost: every write is a `:persistent_term.put`, which
  triggers a global GC. A WorkflowStore hot-reload of a changed template is a
  new key, so a fresh parse -> put -> global GC; and once the memo is at the
  cap, every new-template build rewrites the single entry (another put, another
  global GC). This is acceptable only because template churn is low -- the
  memo is read on every render but written rarely.

  Error returns:

  - `{:error, :solid_not_loaded}` -- consumer omitted `:solid`.
  - `{:error, {:template_parse_error, reason}}` -- parse failure.
  - `{:error, {:template_render_error, [error]}}` -- render failure (unknown
    variable, unknown filter, etc).
  """

  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.PromptBuilder.Memo

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
  # re-parses it. Reads are lock-free here; writes are serialized through the
  # single-writer `Memo` so the FIFO bound holds under concurrent parses.
  #
  # A single entry, not one key per template, is deliberate: `WorkflowStore`
  # hot-reloads `WORKFLOW.md`, so a per-template key scheme would accumulate a
  # never-evicted entry for every template ever seen. Parse errors are not
  # memoized (cheap, rare, and must stay observable).
  defp parse_template(template) do
    memo = :persistent_term.get(@memo_key, @empty_memo)

    case Map.get(memo.map, template) do
      nil -> parse_and_memoize(template)
      parsed -> {:ok, parsed}
    end
  end

  defp parse_and_memoize(template) do
    case Solid.parse(template) do
      {:ok, parsed} ->
        Memo.memoize(@memo_key, @max_memoized, template, parsed)
        {:ok, parsed}

      {:error, error} ->
        {:error, {:template_parse_error, error}}
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
