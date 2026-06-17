defmodule Raxol.Symphony.ReviewConfigTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Config.Schema

  defp build(review) do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory"},
        runner: %{kind: "review"},
        review: review
      },
      prompt_template: ""
    })
  end

  describe "review config defaults" do
    test "review is disabled by default with a raxol_agent implementer" do
      config = build(%{})
      assert config.review.enabled == false
      assert config.review.implementer_kind == "raxol_agent"
      assert config.review.reviewer_kind == nil
    end
  end

  describe "schema validation" do
    test "accepts an enabled review with a distinct reviewer" do
      config = build(%{enabled: true, implementer_kind: "raxol_agent", reviewer_kind: "codex"})
      assert :ok = Schema.validate(config)
    end

    test "a disabled review never fails validation" do
      config =
        build(%{enabled: false, implementer_kind: "raxol_agent", reviewer_kind: "raxol_agent"})

      assert :ok = Schema.validate(config)
    end

    test "rejects a missing reviewer when enabled" do
      config = build(%{enabled: true, implementer_kind: "raxol_agent"})
      assert {:error, :missing_reviewer_kind} = Schema.validate(config)
    end

    test "rejects a reviewer equal to the implementer" do
      config = build(%{enabled: true, implementer_kind: "codex", reviewer_kind: "codex"})
      assert {:error, :reviewer_kind_must_differ} = Schema.validate(config)
    end

    test "rejects an unsupported reviewer kind" do
      config = build(%{enabled: true, implementer_kind: "raxol_agent", reviewer_kind: "bogus"})
      assert {:error, {:unsupported_runner_kind, "bogus"}} = Schema.validate(config)
    end

    test "the review runner kind resolves" do
      assert {:ok, Raxol.Symphony.Runners.Review} =
               Raxol.Symphony.Runner.resolve(build(%{}))
    end
  end
end
