defmodule Raxol.Symphony.RunnerKindConventionTest do
  @moduledoc """
  Mechanical enforcement of the runner-kind vocabulary (ADR-0034 Gap 4).

  `Raxol.Symphony.Runner.resolve/2` and `Raxol.Symphony.Config.Schema`'s
  supported set are two lists of the same thing, and they drifted: the resolver
  handled `raxol_agent_session` and `noop` while the schema named neither, so a
  workflow declaring a real runner resolved and then failed its own preflight.

  Nothing else compares them. This test does, the same way
  `Raxol.Symphony.PauseReasonConventionTest` compares runner-declared pause
  reasons against `Raxol.Symphony.PauseReason` -- by deriving both sides from
  the code rather than restating them here. The resolver's domain is
  `Runner.kinds/0`, which the `resolve_from_config/1` clauses are generated
  from, so a kind cannot become resolvable without appearing in it.
  """

  use ExUnit.Case, async: true

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Config.Schema
  alias Raxol.Symphony.Runner

  defp config_for(kind) do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory"},
        runner: %{kind: kind},
        # Non-blank so the codex kind clears its own extra preflight check;
        # ignored by every other kind.
        codex: %{command: "codex app-server"}
      },
      prompt_template: ""
    })
  end

  defp review_config_for(implementer, reviewer) do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory"},
        runner: %{kind: "review"},
        codex: %{command: "codex app-server"},
        review: %{enabled: true, implementer_kind: implementer, reviewer_kind: reviewer}
      },
      prompt_template: ""
    })
  end

  describe "resolver domain vs schema" do
    test "every kind the resolver handles resolves to a loaded runner module" do
      for kind <- Runner.kinds() do
        assert {:ok, module} = Runner.resolve(config_for(kind)),
               "Runner.kinds/0 declares #{inspect(kind)} but resolve/2 rejects it"

        assert Code.ensure_loaded?(module),
               "#{inspect(kind)} resolves to #{inspect(module)}, which does not exist"

        assert function_exported?(module, :run, 3),
               "#{inspect(module)} does not implement the Runner behaviour"
      end
    end

    test "a kind outside the declared set does not resolve" do
      refute "magic" in Runner.kinds()

      assert {:error, {:unsupported_runner_kind, "magic"}} =
               Runner.resolve(config_for("magic"))
    end

    test "the schema's supported set is exactly the operator-configurable kinds" do
      assert Enum.sort(Schema.supported_runner_kinds()) ==
               Enum.sort(Runner.configurable_kinds()),
             "Config.Schema.supported_runner_kinds/0 and " <>
               "Runner.configurable_kinds/0 disagree; a workflow naming the " <>
               "difference either resolves and fails preflight, or passes " <>
               "preflight and fails to resolve"
    end

    test "every operator-configurable kind passes preflight and resolves" do
      for kind <- Runner.configurable_kinds() do
        config = config_for(kind)

        assert :ok = Schema.validate(config),
               "#{inspect(kind)} is declared operator-configurable but fails preflight"

        assert {:ok, _module} = Runner.resolve(config)
      end
    end

    test "resolver-only kinds resolve but are rejected by preflight" do
      resolver_only = Runner.kinds() -- Runner.configurable_kinds()

      # Not an accident to be widened away: `noop` reads its directives from a
      # test-started Director process, so accepting it from a WORKFLOW.md would
      # promise an inert run and deliver a crash at dispatch.
      assert resolver_only == ["noop"]

      for kind <- resolver_only do
        assert {:ok, _module} = Runner.resolve(config_for(kind))

        assert {:error, {:unsupported_runner_kind, ^kind}} =
                 Schema.validate(config_for(kind))
      end
    end

    test "every reviewable kind is operator-configurable and has a vendor" do
      for kind <- Schema.reviewable_kinds() do
        assert kind in Runner.configurable_kinds(),
               "#{inspect(kind)} is offered as a review participant but is not valid config"

        refute is_nil(Runner.vendor(kind)),
               "#{inspect(kind)} is offered as a review participant but declares no vendor"
      end
    end

    test "preflight accepts a review pair exactly when dispatch can pair it" do
      # `Runners.Review` hands `[implementer, reviewer]` to `select_reviewer/3`
      # with both available; a pair that validates here and fails there parks
      # every issue as :awaiting_human after the implementer has already run.
      kinds = Schema.reviewable_kinds()

      for implementer <- kinds, reviewer <- kinds do
        preflight = Schema.validate(review_config_for(implementer, reviewer))

        dispatch =
          Raxol.Symphony.Review.select_reviewer(implementer, [implementer, reviewer], fn _ ->
            true
          end)

        case dispatch do
          {:ok, ^reviewer} ->
            assert :ok = preflight,
                   "#{implementer} -> #{reviewer} is a valid pair at dispatch but fails preflight"

          {:error, {:insufficient_vendors, _}} ->
            assert {:error, {:reviewer_vendor_must_differ, _}} = preflight,
                   "#{implementer} -> #{reviewer} passes preflight but cannot be paired at dispatch"
        end
      end
    end
  end

  describe "vendor identity" do
    test "the raxol kinds share one vendor and codex is its own" do
      assert Runner.vendor("raxol_agent") == :raxol
      assert Runner.vendor("raxol_agent_session") == :raxol
      assert Runner.vendor("codex") == :codex
    end

    test "the decorator and the inert runner are not vendors" do
      assert Runner.vendor("review") == nil
      assert Runner.vendor("noop") == nil
    end

    test "an undeclared kind is its own vendor" do
      # Distinctness is unknowable for a kind the table does not declare, so it
      # counts as distinct from everything rather than silently equal.
      assert Runner.vendor("someone_elses_agent") == {:unknown, "someone_elses_agent"}
      refute Runner.vendor("someone_elses_agent") == Runner.vendor("another_agent")
    end
  end

  describe "the previously-drifting kind, end to end" do
    @tag :tmp_dir
    test "a WORKFLOW.md naming raxol_agent_session loads, validates and resolves",
         %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "WORKFLOW.md")

      File.write!(path, """
      ---
      tracker:
        kind: memory
      runner:
        kind: raxol_agent_session
      ---
      do the thing
      """)

      assert {:ok, config} = Config.load_and_validate(path)
      assert config.runner.kind == "raxol_agent_session"
      assert {:ok, Raxol.Symphony.Runners.RaxolAgentSession} = Runner.resolve(config)
    end
  end
end
