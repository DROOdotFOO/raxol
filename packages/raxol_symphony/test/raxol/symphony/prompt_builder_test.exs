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
end
