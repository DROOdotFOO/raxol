defmodule Raxol.Agent.Sandbox.SendAgentTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox
  alias Raxol.Agent.Sandbox.SendAgent

  @ctx %{agent_id: :test, agent_module: nil}

  describe "constructors" do
    test "none, deny_all, allow_only, deny build the expected struct" do
      assert %SendAgent{mode: :none} = SendAgent.none()
      assert %SendAgent{mode: :deny_all} = SendAgent.deny_all()

      assert %SendAgent{mode: {:allow_only, [:a, :b]}} =
               SendAgent.allow_only([:a, :b])

      assert %SendAgent{mode: {:deny, [:bad]}} = SendAgent.deny([:bad])
    end
  end

  describe "allowed?/2" do
    test "none -> always allow" do
      assert SendAgent.allowed?(SendAgent.none(), :anyone)
    end

    test "deny_all -> always reject" do
      refute SendAgent.allowed?(SendAgent.deny_all(), :anyone)
    end

    test "allow_only by list" do
      sandbox = SendAgent.allow_only([:worker_a, :worker_b])
      assert SendAgent.allowed?(sandbox, :worker_a)
      refute SendAgent.allowed?(sandbox, :random)
    end

    test "allow_only by predicate" do
      sandbox =
        SendAgent.allow_only(fn id -> is_atom(id) and id != :forbidden end)

      assert SendAgent.allowed?(sandbox, :ok)
      refute SendAgent.allowed?(sandbox, :forbidden)
      refute SendAgent.allowed?(sandbox, "not an atom")
    end

    test "deny by list" do
      sandbox = SendAgent.deny([:bad_actor])
      refute SendAgent.allowed?(sandbox, :bad_actor)
      assert SendAgent.allowed?(sandbox, :good_actor)
    end

    test "deny by predicate" do
      sandbox =
        SendAgent.deny(fn id -> String.starts_with?(to_string(id), "evil_") end)

      refute SendAgent.allowed?(sandbox, :evil_one)
      assert SendAgent.allowed?(sandbox, :good_one)
    end
  end

  describe "authorize/4 (protocol)" do
    test "abstains for non-send_agent actions" do
      assert :ok =
               Sandbox.authorize(
                 SendAgent.deny_all(),
                 :shell,
                 %{command: "ls"},
                 @ctx
               )
    end

    test "allows the matching target" do
      sandbox = SendAgent.allow_only([:worker])

      assert :ok =
               Sandbox.authorize(
                 sandbox,
                 :send_agent,
                 %{target_id: :worker, message: :hi},
                 @ctx
               )
    end

    test "denies non-matching target with reason carrying the mode" do
      sandbox = SendAgent.allow_only([:worker])

      assert {:deny, {:send_agent_denied, {:allow_only, [:worker]}, :random}} =
               Sandbox.authorize(
                 sandbox,
                 :send_agent,
                 %{target_id: :random, message: :hi},
                 @ctx
               )
    end

    test "denies on malformed payload" do
      assert {:deny, {:send_agent_malformed_payload, _}} =
               Sandbox.authorize(
                 SendAgent.none(),
                 :send_agent,
                 %{garbage: :x},
                 @ctx
               )
    end
  end
end
