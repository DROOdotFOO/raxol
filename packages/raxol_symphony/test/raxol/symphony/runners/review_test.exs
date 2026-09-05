defmodule Raxol.Symphony.Runners.ReviewTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Review.Contract
  alias Raxol.Symphony.Runners.Review, as: ReviewRunner

  # -- Fake vendor runners ----------------------------------------------------

  defmodule OkRunner do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, _opts), do: :ok
  end

  defmodule ErrorRunner do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, _opts), do: {:error, :boom}
  end

  # Reviewers report the exact opts they were handed to the test pid (via
  # :parent) so we can assert the Contract-only isolation invariant.
  defmodule ApproveReviewer do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, opts) do
      send(Keyword.fetch!(opts, :parent), {:reviewer_opts, opts})
      :ok
    end
  end

  defmodule RejectReviewer do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, opts) do
      send(Keyword.fetch!(opts, :parent), {:reviewer_opts, opts})
      {:error, :needs_work}
    end
  end

  # Pauses on its own behalf the first time (as Codex does on an approval
  # request) and finishes once the operator's decision reaches it.
  defmodule PausingImplementer do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, opts) do
      case Keyword.get(opts, :resume_value) do
        nil ->
          {:pause, :awaiting_approval, %{decision: "acceptForSession", turn: 1}}

        decision ->
          send(Keyword.fetch!(opts, :parent), {:implementer_resumed, decision})
          :ok
      end
    end
  end

  # Reports every dispatch so a test can prove the implementer did NOT re-run.
  defmodule ReportingImplementer do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, opts) do
      send(Keyword.fetch!(opts, :parent), {:implementer_ran, opts})
      :ok
    end
  end

  # The same, on the reviewer side of the pause.
  defmodule PausingReviewer do
    @behaviour Raxol.Symphony.Runner
    @impl true
    def run(_issue, _config, opts) do
      send(Keyword.fetch!(opts, :parent), {:reviewer_opts, opts})

      case Keyword.get(opts, :resume_value) do
        nil -> {:pause, :awaiting_approval, %{decision: "acceptForSession", turn: 1}}
        _ -> :ok
      end
    end
  end

  # -- Fixtures ---------------------------------------------------------------

  defp issue, do: %Issue{id: "i-1", identifier: "MT-1", title: "Do thing", state: "Todo"}

  defp config(review_overrides) do
    review =
      Map.merge(
        %{
          enabled: true,
          implementer_kind: "impl",
          reviewer_kind: "rev",
          candidate_kinds: ["impl", "rev"]
        },
        review_overrides
      )

    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory"},
        runner: %{kind: "review"},
        review: review
      },
      prompt_template: ""
    })
  end

  defp resolver(map) do
    fn kind ->
      case Map.fetch(map, kind) do
        {:ok, mod} -> {:ok, mod}
        :error -> {:error, {:unknown_kind, kind}}
      end
    end
  end

  # -- Implement phase --------------------------------------------------------

  describe "implement phase" do
    test "passes :ok through when review is disabled" do
      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: resolver(%{"impl" => OkRunner})
      ]

      assert :ok = ReviewRunner.run(issue(), config(%{enabled: false}), opts)
    end

    test "pauses :awaiting_review with a contract and a different reviewer" do
      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: resolver(%{"impl" => OkRunner, "rev" => ApproveReviewer}),
        review_vendor_availability: fn _ -> true end,
        review_git_runner: fn _args, _cwd -> {:ok, "THE DIFF"} end
      ]

      assert {:pause, :awaiting_review, token} = ReviewRunner.run(issue(), config(%{}), opts)
      assert token.reviewer_kind == "rev"
      assert token.implementer_kind == "impl"
      assert %Contract{diff: "THE DIFF", implementer_kind: "impl"} = token.contract
    end

    test "escalates to :awaiting_human when no different vendor is available" do
      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: resolver(%{"impl" => OkRunner}),
        review_vendor_availability: fn k -> k == "impl" end,
        review_git_runner: fn _args, _cwd -> {:ok, ""} end
      ]

      assert {:pause, :awaiting_human, token} = ReviewRunner.run(issue(), config(%{}), opts)
      assert token.reason == :insufficient_vendors
    end

    test "passes an implementer error through unchanged" do
      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: resolver(%{"impl" => ErrorRunner})
      ]

      assert {:error, :boom} = ReviewRunner.run(issue(), config(%{}), opts)
    end
  end

  # -- Review phase (resume) --------------------------------------------------

  describe "review phase" do
    defp resume_opts(token, extra) do
      [
        parent: self(),
        resume_token: token,
        resume_value: :proceed,
        review_runner_resolver: resolver(%{"rev" => ApproveReviewer, "reject" => RejectReviewer})
      ] ++ extra
    end

    test "approves when the reviewer returns :ok" do
      token = %{
        reviewer_kind: "rev",
        implementer_kind: "impl",
        contract: %Contract{issue_identifier: "MT-1", diff: "d"}
      }

      assert :ok = ReviewRunner.run(issue(), config(%{}), resume_opts(token, []))
    end

    test "surfaces a rejection as changes_requested" do
      token = %{
        reviewer_kind: "reject",
        implementer_kind: "impl",
        contract: %Contract{issue_identifier: "MT-1"}
      }

      assert {:error, {:changes_requested, :needs_work}} =
               ReviewRunner.run(issue(), config(%{}), resume_opts(token, []))
    end

    test "the reviewer receives the Contract only -- never the implementer workspace" do
      contract = %Contract{issue_identifier: "MT-1", diff: "d", implementer_kind: "impl"}
      token = %{reviewer_kind: "rev", implementer_kind: "impl", contract: contract}

      assert :ok = ReviewRunner.run(issue(), config(%{}), resume_opts(token, []))

      assert_receive {:reviewer_opts, ropts}
      assert ropts[:review_contract] == contract
      assert is_binary(ropts[:review_prompt])
      # An isolated workspace, NOT the implementer's worktree.
      assert ropts[:workspace_path] != "/tmp/ws"
      refute Keyword.has_key?(ropts, :resume_token)
    end
  end

  # -- Full implement -> pause -> review -> complete cycle ---------------------

  describe "full review cycle" do
    test "implement pauses for review, then the resumed reviewer completes it" do
      res = resolver(%{"impl" => OkRunner, "rev" => ApproveReviewer})

      implement_opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: res,
        review_vendor_availability: fn _ -> true end,
        review_git_runner: fn _args, _cwd -> {:ok, "DIFF"} end
      ]

      # Phase 1: implement -> pause carrying the review token (as the
      # orchestrator would park it).
      assert {:pause, :awaiting_review, token} =
               ReviewRunner.run(issue(), config(%{}), implement_opts)

      # Phase 2: orchestrator resumes with the token; the different-vendor
      # reviewer runs against the Contract and approves -> run completes.
      resume = [
        parent: self(),
        resume_token: token,
        resume_value: :proceed,
        review_runner_resolver: res
      ]

      assert :ok = ReviewRunner.run(issue(), config(%{}), resume)
      assert_receive {:reviewer_opts, ropts}
      assert ropts[:review_contract] == token.contract
      assert ropts[:workspace_path] != "/tmp/ws"
    end
  end

  # -- Human escalation resume ------------------------------------------------

  describe "human escalation resume" do
    defp human_opts(decision) do
      [
        parent: self(),
        resume_token: %{
          contract: %Contract{issue_identifier: "MT-1"},
          implementer_kind: "impl",
          reason: :insufficient_vendors
        },
        resume_value: decision
      ]
    end

    test "an :approved decision completes the run" do
      assert :ok = ReviewRunner.run(issue(), config(%{}), human_opts(:approved))
    end

    test "a :rejected decision requests changes" do
      assert {:error, {:changes_requested, :rejected_by_human}} =
               ReviewRunner.run(issue(), config(%{}), human_opts(:rejected))
    end

    test "a decision arriving as a string from the MCP surface is honoured" do
      assert :ok = ReviewRunner.run(issue(), config(%{}), human_opts("approved"))

      assert {:error, {:changes_requested, :rejected_by_human}} =
               ReviewRunner.run(issue(), config(%{}), human_opts("rejected"))
    end

    test "an unrecognised decision is reported, not guessed at" do
      assert {:error, {:unexpected_human_decision, :maybe}} =
               ReviewRunner.run(issue(), config(%{}), human_opts(:maybe))
    end
  end

  # -- Pauses raised by the inner agents, not by this module -------------------

  describe "delegated pause" do
    test "an implementer pause resumes back into the implementer" do
      res = resolver(%{"impl" => PausingImplementer, "rev" => ApproveReviewer})

      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: res,
        review_vendor_availability: fn _ -> true end,
        review_git_runner: fn _args, _cwd -> {:ok, "DIFF"} end
      ]

      assert {:pause, :awaiting_approval, token} =
               ReviewRunner.run(issue(), config(%{}), opts)

      assert token.review_delegate == :implementer

      resume = [resume_token: token, resume_value: :approved] ++ opts

      assert {:pause, :awaiting_review, review_token} =
               ReviewRunner.run(issue(), config(%{}), resume)

      assert_receive {:implementer_resumed, :approved}
      assert review_token.reviewer_kind == "rev"
    end

    # The dangerous misroute: a decision the operator gave about the REVIEWER's
    # request must not start a fresh implementer run against the real worktree.
    test "a reviewer pause resumes back into the reviewer, never the implementer" do
      res = resolver(%{"impl" => ReportingImplementer, "rev" => PausingReviewer})

      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: res,
        review_vendor_availability: fn _ -> true end,
        review_git_runner: fn _args, _cwd -> {:ok, "DIFF"} end
      ]

      assert {:pause, :awaiting_review, review_token} =
               ReviewRunner.run(issue(), config(%{}), opts)

      assert_receive {:implementer_ran, _}

      resume = [resume_token: review_token, resume_value: :proceed] ++ opts
      assert {:pause, :awaiting_approval, token} = ReviewRunner.run(issue(), config(%{}), resume)
      assert token.review_delegate == :reviewer

      assert :ok =
               ReviewRunner.run(
                 issue(),
                 config(%{}),
                 [resume_token: token, resume_value: :approved] ++ opts
               )

      # Both reviewer dispatches got the Contract in their own isolated
      # workspace, and the implementer never ran a second time.
      for _ <- 1..2 do
        assert_receive {:reviewer_opts, ropts}
        assert %Contract{} = ropts[:review_contract]
        assert ropts[:workspace_path] != "/tmp/ws"
      end

      refute_received {:implementer_ran, _}
    end

    test "a token from neither phase is reported, not run as an implement" do
      opts = [
        parent: self(),
        workspace_path: "/tmp/ws",
        review_runner_resolver: resolver(%{"impl" => OkRunner}),
        resume_token: %{who_knows: true},
        resume_value: :approved
      ]

      assert {:error, {:unroutable_resume_token, %{who_knows: true}}} =
               ReviewRunner.run(issue(), config(%{}), opts)
    end
  end
end
