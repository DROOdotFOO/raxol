defmodule Raxol.Symphony.PromptBuilderTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Issue, PromptBuilder}
  alias Raxol.Symphony.Issue.Blocker

  defp issue(opts \\ []) do
    defaults = %Issue{
      id: "abc",
      identifier: "MT-1",
      title: "Refactor X",
      state: "Todo",
      description: "Some body text",
      url: "https://linear.app/foo/issue/MT-1",
      labels: ["bug", "high"],
      priority: 2,
      blocked_by: []
    }

    struct(defaults, opts)
  end

  describe "build/3 -- happy paths" do
    test "renders simple variable substitution" do
      assert {:ok, rendered} =
               PromptBuilder.build(
                 issue(),
                 "Working on {{ issue.identifier }} -- {{ issue.title }}."
               )

      assert rendered == "Working on MT-1 -- Refactor X."
    end

    test "iterates labels" do
      template = """
      Labels:
      {% for label in issue.labels %}- {{ label }}
      {% endfor %}
      """

      assert {:ok, rendered} = PromptBuilder.build(issue(), template)
      assert rendered =~ "- bug"
      assert rendered =~ "- high"
    end

    test "iterates blocked_by" do
      blockers = [
        %Blocker{id: "b1", identifier: "MT-99", state: "In Progress"},
        %Blocker{id: "b2", identifier: "MT-100", state: "Done"}
      ]

      template = """
      Blockers:
      {% for b in issue.blocked_by %}- {{ b.identifier }} ({{ b.state }})
      {% endfor %}
      """

      assert {:ok, rendered} =
               PromptBuilder.build(issue(blocked_by: blockers), template)

      assert rendered =~ "- MT-99 (In Progress)"
      assert rendered =~ "- MT-100 (Done)"
    end

    test "attempt variable is null on first attempt" do
      template = "Attempt: {{ attempt }}."
      assert {:ok, "Attempt: ."} = PromptBuilder.build(issue(), template, nil)
    end

    test "attempt variable is integer on retry" do
      template = "Attempt: {{ attempt }}."
      assert {:ok, "Attempt: 3."} = PromptBuilder.build(issue(), template, 3)
    end

    test "supports {% if attempt %} branch for continuation guidance" do
      template =
        ~S"""
        Issue {{ issue.identifier }}.
        {% if attempt %}This is retry #{{ attempt }}.{% endif %}
        """

      assert {:ok, first} = PromptBuilder.build(issue(), template, nil)
      refute first =~ "This is retry"

      assert {:ok, retry} = PromptBuilder.build(issue(), template, 2)
      assert retry =~ "This is retry #2."
    end
  end

  describe "fallback" do
    test "empty template uses the SPEC default prompt" do
      assert {:ok, prompt} = PromptBuilder.build(issue(), "")
      assert prompt == "You are working on an issue from Linear."
    end

    test "nil template uses the default prompt" do
      assert {:ok, prompt} = PromptBuilder.build(issue(), nil)
      assert prompt == "You are working on an issue from Linear."
    end

    test "whitespace-only template uses the default prompt" do
      assert {:ok, prompt} = PromptBuilder.build(issue(), "   \n\t  ")
      assert prompt == "You are working on an issue from Linear."
    end
  end

  describe "strict mode failures" do
    test "unknown variable fails rendering" do
      assert {:error, {:template_render_error, _}} =
               PromptBuilder.build(issue(), "Hello {{ unknown_var }}.")
    end

    test "unknown filter fails rendering" do
      assert {:error, {:template_render_error, _}} =
               PromptBuilder.build(issue(), "{{ issue.title | nonexistent_filter }}.")
    end

    test "unknown nested issue field fails rendering" do
      assert {:error, {:template_render_error, _}} =
               PromptBuilder.build(issue(), "{{ issue.totally_made_up_field }}.")
    end
  end

  describe "default_prompt/0" do
    test "exposes the spec default" do
      assert PromptBuilder.default_prompt() == "You are working on an issue from Linear."
    end
  end

  # White-box: the memo key is `{PromptBuilder, :parsed_template, template}`
  # in `:persistent_term`. Unique per-template tags keep these async-safe.
  describe "template AST memoization" do
    defp memo_key(template), do: {PromptBuilder, :parsed_template, template}

    test "memoizes the parsed AST; a second build reuses it instead of re-parsing" do
      tag = System.unique_integer([:positive])
      template = "A#{tag} {{ issue.identifier }}"
      other = "B#{tag} {{ issue.identifier }}"
      on_exit(fn -> :persistent_term.erase(memo_key(template)) end)

      # First build parses + memoizes `template`.
      assert {:ok, rendered} = PromptBuilder.build(issue(), template)
      assert rendered == "A#{tag} MT-1"

      # Poison the memo with a DIFFERENT template's AST. A re-parse would
      # render `template`'s text ("A..."); a memo HIT renders the poisoned
      # AST's text ("B...").
      {:ok, other_ast} = Solid.parse(other)
      :persistent_term.put(memo_key(template), other_ast)

      assert {:ok, hit} = PromptBuilder.build(issue(), template)
      assert hit == "B#{tag} MT-1"
    end

    test "a different template is a distinct key and re-parses" do
      tag = System.unique_integer([:positive])
      t1 = "one#{tag} {{ issue.identifier }}"
      t2 = "two#{tag} {{ issue.identifier }}"

      on_exit(fn ->
        :persistent_term.erase(memo_key(t1))
        :persistent_term.erase(memo_key(t2))
      end)

      assert {:ok, r1} = PromptBuilder.build(issue(), t1)
      assert r1 == "one#{tag} MT-1"

      assert {:ok, r2} = PromptBuilder.build(issue(), t2)
      assert r2 == "two#{tag} MT-1"
    end

    test "renders of the memoized template stay per-issue/attempt (only the parse is shared)" do
      tag = System.unique_integer([:positive])
      template = "s#{tag} {{ issue.identifier }} a={{ attempt }}"
      on_exit(fn -> :persistent_term.erase(memo_key(template)) end)

      assert {:ok, first} = PromptBuilder.build(issue(), template, nil)
      assert first == "s#{tag} MT-1 a="

      assert {:ok, retry} = PromptBuilder.build(issue(identifier: "MT-2"), template, 5)
      assert retry == "s#{tag} MT-2 a=5"
    end
  end
end
