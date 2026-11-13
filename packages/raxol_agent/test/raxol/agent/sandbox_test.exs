defmodule Raxol.Agent.SandboxTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox.{Async, Chain, SendAgent, Shell}

  @ctx %{agent_id: :test, agent_module: nil}

  describe "Chain.authorize/4" do
    test "empty chain allows everything" do
      assert :ok = Chain.authorize([], :shell, %{command: "rm"}, @ctx)
    end

    test "single sandbox allowing" do
      assert :ok =
               Chain.authorize(
                 [Shell.allowlist(["ls"])],
                 :shell,
                 %{command: "ls"},
                 @ctx
               )
    end

    test "single sandbox denying short-circuits" do
      assert {:deny, {:shell_denied, _, _}} =
               Chain.authorize(
                 [Shell.deny_all()],
                 :shell,
                 %{command: "ls"},
                 @ctx
               )
    end

    test "first deny wins -- subsequent sandboxes don't run" do
      # If first sandbox denied, second's authorize/4 must not be consulted.
      # A predicate side-effect would tell us if it ran; counters are a
      # simpler check.
      counter = :counters.new(1, [])

      tattler =
        Shell.allowlist(fn _cmd ->
          :counters.add(counter, 1, 1)
          true
        end)

      chain = [Shell.deny_all(), tattler]

      assert {:deny, _} =
               Chain.authorize(chain, :shell, %{command: "ls"}, @ctx)

      assert :counters.get(counter, 1) == 0
    end

    test "abstaining sandboxes pass through to applicable ones" do
      chain = [
        Shell.deny_all(),
        SendAgent.allow_only([:worker]),
        Async.deny()
      ]

      # :send_agent action -- Shell abstains, SendAgent allows.
      assert :ok =
               Chain.authorize(
                 chain,
                 :send_agent,
                 %{target_id: :worker, message: :hi},
                 @ctx
               )

      # :async action -- Shell + SendAgent abstain, Async denies.
      assert {:deny, :async_denied} =
               Chain.authorize(
                 chain,
                 :async,
                 %{fun: fn _ -> :ok end},
                 @ctx
               )

      # :shell action -- Shell denies first.
      assert {:deny, {:shell_denied, _, _}} =
               Chain.authorize(chain, :shell, %{command: "ls"}, @ctx)
    end

    test "multi-dimensional composition: each dimension policed independently" do
      chain = [
        Shell.denylist(["rm", "dd"]),
        SendAgent.deny([:bad_actor]),
        Async.allow()
      ]

      # Allowed across all dimensions.
      assert :ok = Chain.authorize(chain, :shell, %{command: "ls"}, @ctx)

      assert :ok =
               Chain.authorize(
                 chain,
                 :send_agent,
                 %{target_id: :good, message: :hi},
                 @ctx
               )

      # Shell denylist hits.
      assert {:deny, {:shell_denied, _, _}} =
               Chain.authorize(chain, :shell, %{command: "rm -rf /"}, @ctx)

      # SendAgent deny hits.
      assert {:deny, {:send_agent_denied, _, :bad_actor}} =
               Chain.authorize(
                 chain,
                 :send_agent,
                 %{target_id: :bad_actor, message: :hi},
                 @ctx
               )
    end
  end
end
