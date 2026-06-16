defmodule Raxol.Agent.Sandbox.AsyncTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Sandbox
  alias Raxol.Agent.Sandbox.Async

  @ctx %{agent_id: :test, agent_module: nil}

  describe "constructors + allowed?" do
    test "allow lets async through" do
      assert Async.allowed?(Async.allow())
    end

    test "deny blocks async" do
      refute Async.allowed?(Async.deny())
    end
  end

  describe "authorize/4 (protocol)" do
    test "abstains for non-async actions" do
      assert :ok =
               Sandbox.authorize(Async.deny(), :shell, %{command: "ls"}, @ctx)

      assert :ok =
               Sandbox.authorize(
                 Async.deny(),
                 :send_agent,
                 %{target_id: :x, message: :hi},
                 @ctx
               )
    end

    test "allows async when mode is :allow" do
      assert :ok =
               Sandbox.authorize(
                 Async.allow(),
                 :async,
                 %{fun: fn _ -> :ok end},
                 @ctx
               )
    end

    test "denies async when mode is :deny" do
      assert {:deny, :async_denied} =
               Sandbox.authorize(
                 Async.deny(),
                 :async,
                 %{fun: fn _ -> :ok end},
                 @ctx
               )
    end
  end
end
